unit ScuDeckExport;

{$mode objfpc}{$H+}

interface

uses
  ScuLibrary, ScuSQLite, ScuExportTypes;

type
  TRenderedDeck = record
    Bytes: RawByteString;
    DeckVersion, ExpansionUTC, FileName: string;
    LegacyCopy: Boolean;
  end;
function RenderDeck(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary; const Deck: string;
  const Selection: TDeckSelection; Mode: TExportMode; const ExpansionUTC: string = ''): TRenderedDeck;
implementation

uses
  SysUtils, ScuClock, ScuReleaseMacros, ScuErrors, ScuLibraryNames;

function RenderDeck(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary; const Deck: string;
  const Selection: TDeckSelection; Mode: TExportMode; const ExpansionUTC: string): TRenderedDeck;
var
  Expander: TReleaseMacros;
  Source: TDeckSource;
  Root: Integer;
begin
  Result := Default(TRenderedDeck);
  Root := Selection.RootRevision;
  if Root = 0 then Root := Selection.Snapshot.LibraryRevision;
  Source := LibraryFile.Extract(Database, Deck, Root, Selection.Snapshot.Version);
  Result.FileName := Source.SourcePath;
  ValidateSourceFileName(Result.FileName);
  if Mode = emExpand then
  begin
    Expander := TReleaseMacros.Create(Selection.Snapshot.Version);
    try
      if Source.CommentPrefix = '' then Source.CommentPrefix := LibraryFile.DefaultCommentPrefix(Selection.Snapshot.Version);
      Result.Bytes := Expander.Expand(Source);
      Result.DeckVersion := Source.DeckVersion;
      Result.LegacyCopy := Expander.LegacyCopy;
      Result.ExpansionUTC := ExpansionUTC;
      if Result.ExpansionUTC = '' then Result.ExpansionUTC := UtcTimestamp(UtcNow);
    finally
      Expander.Free;
    end;
  end
  else
  begin
    Result.Bytes := Source.Bytes;
    Result.DeckVersion := Source.DeckVersion;
  end;
end;
end.
