unit ScuDeckCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function CreateDeck(var Context: TCommandContext): string;
function StoreDeck(var Context: TCommandContext): string;
function EditDeckCommand(var Context: TCommandContext): string;
function DisplayDeck(var Context: TCommandContext): string;
function DisplayDeckList(var Context: TCommandContext): string;
function DiffDeck(var Context: TCommandContext): string;

implementation

uses
  Classes, SysUtils, ScuCodec, ScuDiff, ScuEdit, ScuIO, ScuLibrary, ScuVersions;

function DeckWriteReport(LibraryFile: TDeckLibrary; const Deck: string; StoredRevision: Integer): string;
begin
  if StoredRevision = 0 then
    Exit('No changes to ' + Deck);
  Result := Format('%s version %s revision %s, deck version %s',
    [Deck, LibraryFile.VersionAt(StoredRevision), LibraryFile.DeckRevision[StoredRevision],
      LibraryFile.DeckVersion[StoredRevision]]);
end;

function WriteDeck(var Context: TCommandContext; const FileArgument: string; CreateOnly: Boolean): string;
var
  Deck, Path: string;
  Bytes: RawByteString;
  Revision: Integer;
begin
  Deck := ResolveDeck(Context);
  Context.LibraryFile.RequireOpenVersion;
  Deck := DeckName(Deck);
  Path := Context.Command[FileArgument];
  Bytes := '';
  if not CreateOnly or (Path <> '') then
    Bytes := ReadBytes(Path, MaxDeckSize);
  Revision := Context.LibraryFile.Store(Context.Database, Deck, Bytes, CreateOnly, PrefixOption(Context.Command));
  Result := DeckWriteReport(Context.LibraryFile, Deck, Revision);
end;

function CreateDeck(var Context: TCommandContext): string;
begin
  Result := WriteDeck(Context, 'from_file', True);
end;

function StoreDeck(var Context: TCommandContext): string;
begin
  Result := WriteDeck(Context, 'source_file', False);
end;

function EditDeckCommand(var Context: TCommandContext): string;
var
  Deck: string;
begin
  Deck := DeckName(ResolveDeck(Context));
  Result := DeckWriteReport(Context.LibraryFile, Deck, EditDeck(Context.LibraryFile, Context.Database, Deck));
end;

function DisplayDeck(var Context: TCommandContext): string;
var
  Rows: TStringList;
  Row: string;
begin
  Rows := TStringList.Create;
  try
    Context.LibraryFile.ListDeckHistory(Context.Database, ResolveDeck(Context), Rows);
    for Row in Rows do
      Context.Output.WriteLine(Row);
  finally
    Rows.Free;
  end;
  Result := '';
end;

function DisplayDeckList(var Context: TCommandContext): string;
var
  Rows: TStringList;
  Row: string;
begin
  Rows := TStringList.Create;
  try
    Context.Snapshots.Selected := ResolveSnapshot(Context);
    Context.LibraryFile.List(Context.Snapshots.Selected.LibraryRevision, Rows);
    Rows.Sort;
    for Row in Rows do
      Context.Output.WriteLine(Row);
    ReportSnapshot(Context);
  finally
    Rows.Free;
  end;
  Result := '';
end;

function DiffDeck(var Context: TCommandContext): string;
var
  Deck, FromSelector: string;
  LibraryFile: TDeckLibrary;
  FromSnapshot, ToSnapshot: TLibrarySnapshot;
  Source, OtherSource: TDeckSource;
  UsePriorDeckRevision: Boolean;
begin
  LibraryFile := Context.LibraryFile;
  Deck := DeckName(ResolveDeck(Context));
  FromSelector := Context.Command['from_snapshot'];
  UsePriorDeckRevision := not Context.Command.Provided['from_snapshot'] and
    SameText(FromSelector, PreviousDeckVersionSelector);
  if not UsePriorDeckRevision then
  begin
    FromSnapshot := LibraryFile.ParseDeckSnapshot(Deck, FromSelector);
    Context.Snapshots.FromDeckVersion := LibraryFile.DeckVersion[FromSnapshot.LibraryRevision];
  end;
  ToSnapshot := LibraryFile.ParseDeckSnapshot(Deck, Context.Command['to_snapshot']);
  Context.Snapshots.ToDeckVersion := LibraryFile.DeckVersion[ToSnapshot.LibraryRevision];
  if UsePriorDeckRevision then
  begin
    FromSnapshot := LibraryFile.PreviousDeckSnapshot(Deck, ToSnapshot.LibraryRevision);
    Context.Snapshots.FromDeckVersion := LibraryFile.DeckVersion[FromSnapshot.LibraryRevision];
  end;
  Source := LibraryFile.Extract(Context.Database, Deck, FromSnapshot.LibraryRevision);
  OtherSource := LibraryFile.Extract(Context.Database, Deck, ToSnapshot.LibraryRevision);
  WriteDeckDiff(Source.Bytes, OtherSource.Bytes, Deck + '@' + Context.Snapshots.FromDeckVersion,
    Deck + '@' + Context.Snapshots.ToDeckVersion, Context.Output);
  Context.Output.Report('From deck version ' + Context.Snapshots.FromDeckVersion + '.');
  Context.Output.Report('To deck version ' + Context.Snapshots.ToDeckVersion + '.');
  Result := '';
end;

end.
