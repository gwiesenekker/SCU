unit ScuGuiReader;
{$mode objfpc}{$H+}
interface
uses Classes, FPJSON, ScuLibrary;
type
  TGuiLibraryState = record
    CurrentVersion, NextVersion: string;
    Locked, PrefixEditable: Boolean;
  end;
  TGuiDeck = record
    Bytes: RawByteString;
    Deleted: Boolean;
    DeckVersion, SourceName: string;
  end;
function ReadGuiLibraryState(const LibraryPath: string): TGuiLibraryState;
// The caller owns the returned configuration snapshot.
function ReadGuiConfiguration(const LibraryPath: string): TJSONObject;
function ReadGuiDecks(const LibraryPath: string): TDeckListEntries;
function ReadGuiDeckVersion(const LibraryPath, Deck, Selector: string): TGuiDeck;
function ReadGuiDeck(const LibraryPath, Deck: string): TGuiDeck;
procedure ReadGuiVersions(const LibraryPath, Deck: string; Versions: TStrings);
implementation
uses ScuSQLite, ScuErrors;
function ReadGuiLibraryState(const LibraryPath: string): TGuiLibraryState;
var Database: TSQLiteLibrary; LibraryFile: TDeckLibrary;
begin
  Database := TSQLiteLibrary.OpenRead(LibraryPath);
  try
    LibraryFile := TDeckLibrary.Load(LibraryPath, Database);
    try
      Result.CurrentVersion := LibraryFile.CurrentVersion;
      Result.NextVersion := LibraryFile.SuggestedNextVersion;
      Result.Locked := LibraryFile.VersionHistory[LibraryFile.VersionCount-1].Locked;
      Result.PrefixEditable := not Result.Locked and
        (LibraryFile.Revision = LibraryFile.VersionHistory[LibraryFile.VersionCount-1].BaseRevision);
    finally LibraryFile.Free; end;
  finally Database.Free; end;
end;
function ReadGuiConfiguration(const LibraryPath: string): TJSONObject;
var Database: TSQLiteLibrary; LibraryFile: TDeckLibrary;
begin
  Database := TSQLiteLibrary.OpenRead(LibraryPath);
  try
    LibraryFile := TDeckLibrary.Load(LibraryPath, Database);
    try Result := LibraryFile.CreateHeaderConfiguration; finally LibraryFile.Free; end;
  finally Database.Free; end;
end;
function ReadGuiDecks(const LibraryPath: string): TDeckListEntries;
var Database: TSQLiteLibrary; LibraryFile: TDeckLibrary;
begin
  Database := TSQLiteLibrary.OpenRead(LibraryPath);
  try
    LibraryFile := TDeckLibrary.Load(LibraryPath, Database);
    try Result := LibraryFile.DeckList(LibraryFile.Revision);
    finally LibraryFile.Free; end;
  finally Database.Free; end;
end;
function ReadGuiDeckVersion(const LibraryPath, Deck, Selector: string): TGuiDeck;
var Database: TSQLiteLibrary; LibraryFile: TDeckLibrary; Source: TDeckSource; Snapshot: TLibrarySnapshot;
begin
  Database := TSQLiteLibrary.OpenRead(LibraryPath);
  try
    LibraryFile := TDeckLibrary.Load(LibraryPath, Database);
    try
      Snapshot := LibraryFile.ParseDeckSnapshot(Deck, Selector);
      Source := LibraryFile.Extract(Database, Deck, Snapshot.LibraryRevision, '', [deoAllowDeleted]);
      Result.Bytes := Source.Bytes; Result.Deleted := Source.Deleted;
      Result.DeckVersion := Source.DeckVersion;
      Result.SourceName := Source.SourcePath;
    finally LibraryFile.Free; end;
  finally Database.Free; end;
end;
function ReadGuiDeck(const LibraryPath, Deck: string): TGuiDeck;
begin
  Result := ReadGuiDeckVersion(LibraryPath, Deck, CurrentDeckVersionSelector);
  if Result.Deleted then raise EScuError.Create('Deck "' + Deck + '" is deleted in the current snapshot.');
end;
procedure ReadGuiVersions(const LibraryPath, Deck: string; Versions: TStrings);
var Database: TSQLiteLibrary; LibraryFile: TDeckLibrary; All: TStringList; I: Integer;
begin
  Database := TSQLiteLibrary.OpenRead(LibraryPath);
  try
    LibraryFile := TDeckLibrary.Load(LibraryPath, Database);
    try
      All := TStringList.Create;
      try
        LibraryFile.ListDeckRevisions(Deck, All, [drDeckVersion]);
        Versions.Clear;
        for I := All.Count - 1 downto 0 do Versions.Add(All[I]);
      finally All.Free; end;
    finally LibraryFile.Free; end;
  finally Database.Free; end;
end;
end.
