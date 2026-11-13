unit ScuDeckCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function CreateDeck(var Context: TCommandContext): string;
function DeleteDeck(var Context: TCommandContext): string;
function EditDeckCommand(var Context: TCommandContext): string;
function DisplayDeck(var Context: TCommandContext): string;
function DisplayDeckList(var Context: TCommandContext): string;
function DiffDeck(var Context: TCommandContext): string;

implementation

uses
  Classes, SysUtils, ScuCodec, ScuErrors, ScuDiff, ScuLibraryDisplay, ScuEdit, ScuFiles, ScuLibrary, ScuTerminal, ScuVersions;

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
  Path := Context.Command.Argument(FileArgument);
  Bytes := '';
  if not CreateOnly or (Path <> '') then
    Bytes := ReadBytes(Path, MaxDeckSize);
  Revision := Context.LibraryFile.Store(Context.Database, Deck, Bytes, CreateOnly, PrefixArgument(Context.Command));
  Result := DeckWriteReport(Context.LibraryFile, Deck, Revision);
end;

function CreateDeck(var Context: TCommandContext): string;
begin
  Result := WriteDeck(Context, 'from_file', True);
end;

function DeleteDeck(var Context: TCommandContext): string;
var
  Deck: string;
  Revision: Integer;
begin
  Deck := DeckName(ResolveDeck(Context));
  Revision := Context.LibraryFile.Delete(Context.Database, Deck);
  Result := 'Deleted ' + DeckWriteReport(Context.LibraryFile, Deck, Revision);
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
  Rows: TDeckHistoryEntries;
  Limit: Int64;
  Deck: string;
begin
  if not TryStrToInt64(Context.Command.Argument('limit', '10'), Limit) or (Limit < 0) then
    raise EScuError.Create('Expected a nonnegative integer for limit; use 0 for the complete deck history.');
  Deck := DeckName(ResolveDeck(Context));
  Rows := Context.LibraryFile.DeckHistory(Context.Database, Deck, Limit);
  Context.Output.WriteLine(FormatTerminalLines(Format('Deck "%s".', [Deck]),
    TerminalColumns(StdOutputHandle)));
  WriteDeckHistory(Rows, Context.Output);
  Result := '';
end;

function DisplayDeckList(var Context: TCommandContext): string;
begin
  Context.Snapshots.Selected := ResolveSnapshot(Context);
  WriteDeckList(Context.LibraryFile.DeckList(Context.Snapshots.Selected.LibraryRevision),
    Context.Output);
  ReportSnapshot(Context);
  Result := '';
end;

function DiffDeck(var Context: TCommandContext): string;
var
  Deck, FromSelector, FromLabel, ToLabel: string;
  LibraryFile: TDeckLibrary;
  FromSnapshot, ToSnapshot: TLibrarySnapshot;
  Source, OtherSource: TDeckSource;
  UsePriorDeckRevision, IgnoreSpaceChanges: Boolean;
  Format: TDiffFormat;
begin
  LibraryFile := Context.LibraryFile;
  IgnoreSpaceChanges := BooleanArgument(Context.Command, 'ignore_space_changes');
  Format := ParseDiffFormat(Context.Command.Argument('output_format', 'normal'));
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
  Source := LibraryFile.Extract(Context.Database, Deck, FromSnapshot.LibraryRevision, '', True);
  OtherSource := LibraryFile.Extract(Context.Database, Deck, ToSnapshot.LibraryRevision, '', True);
  FromLabel := Deck + '@' + Context.Snapshots.FromDeckVersion;
  ToLabel := Deck + '@' + Context.Snapshots.ToDeckVersion;
  if Source.Deleted then
    FromLabel := '/dev/null';
  if OtherSource.Deleted then
    ToLabel := '/dev/null';
  if (Source.Bytes = '') and (OtherSource.Bytes = '') and (Source.Deleted <> OtherSource.Deleted) then
  begin
    if OtherSource.Deleted then
      Context.Output.WriteLine('Deleted empty deck ' + Deck)
    else
      Context.Output.WriteLine('Recreated empty deck ' + Deck);
  end
  else
    WriteDeckDiff(Source.Bytes, OtherSource.Bytes, FromLabel, ToLabel, Context.Output,
      IgnoreSpaceChanges, Format);
  Context.Output.Report('From deck version ' + Context.Snapshots.FromDeckVersion + '.');
  Context.Output.Report('To deck version ' + Context.Snapshots.ToDeckVersion + '.');
  Result := '';
end;

end.
