unit ScuVersionDiff;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function DisplayVersionDiff(var Context: TCommandContext): string;

implementation

uses
  ScuArchiveCompatibility, Classes, SysUtils, ScuTable, ScuDiff, ScuLibrary, ScuSignals;

function PatchLabel(const Path, Version: string): string;
const Octal = '01234567';
var
  Character: Char;
  NeedsQuote: Boolean;
  Number: Byte;
begin
  NeedsQuote := False;
  for Character in Path do
    if Character in [#0..#32, #127..#255, '"', '\'] then NeedsQuote := True;
  Result := Path;
  if NeedsQuote then
  begin
    Result := '"';
    for Character in Path do
    begin
      Number := Byte(Character);
      if Character in ['"', '\'] then Result := Result + '\' + Character
      else if (Number < 32) or (Number > 126) then
        Result := Result + '\' + Octal[(Number shr 6) + 1] + Octal[((Number shr 3) and 7) + 1] + Octal[(Number and 7) + 1]
      else Result := Result + Character;
    end;
    Result := Result + '"';
  end;
  Result := Result + #9 + Version;
end;

function HeaderMarker(const Source: TDeckSource; const DefaultPrefix: string): string;
begin
  Result := Source.CommentPrefix;
  if Result = '' then Result := DefaultPrefix;
  if Result <> '' then Result := Result + ' SCU REVISION ';
end;

procedure WriteChangedDeck(const Context: TCommandContext; const Deck: string; IgnoreSpaceChanges, IgnoreHeaders: Boolean; Format: TDiffFormat; Summary: TScuTable; var Total: TDiffStats; var DeckCount: Integer);
var
  FromDeck, ToDeck: TLibrarySnapshot;
  FromSource, ToSource: TDeckSource;
  FromLabel, ToLabel, FromMarker, ToMarker: string;
  InFrom, InTo: Boolean;
  Stats: TDiffStats;
  Status: string;
begin
  InFrom := Context.LibraryFile.TryDeckSnapshot(Deck, Context.Snapshots.FromVersion.LibraryRevision, FromDeck);
  InTo := Context.LibraryFile.TryDeckSnapshot(Deck, Context.Snapshots.ToVersion.LibraryRevision, ToDeck);
  if FromDeck.LibraryRevision = ToDeck.LibraryRevision then
    Exit;
  FromSource := Default(TDeckSource);
  ToSource := Default(TDeckSource);
  FromLabel := '/dev/null';
  ToLabel := '/dev/null';
  if InFrom then
  begin
    FromSource := Context.LibraryFile.Extract(Context.Database, Deck, FromDeck.LibraryRevision);
    if Format = dfUnified then FromLabel := PatchLabel('a/' + FromSource.SourcePath, FromSource.DeckVersion)
    else FromLabel := Deck + '@' + FromSource.DeckVersion;
  end;
  if InTo then
  begin
    ToSource := Context.LibraryFile.Extract(Context.Database, Deck, ToDeck.LibraryRevision);
    if Format = dfUnified then ToLabel := PatchLabel('b/' + ToSource.SourcePath, ToSource.DeckVersion)
    else ToLabel := Deck + '@' + ToSource.DeckVersion;
  end;
  Stats := Default(TDiffStats);
  if (FromSource.Bytes = '') and (ToSource.Bytes = '') and (InFrom <> InTo) then
  begin
    if InTo then
      Context.Output.WriteLine('Only in version ' + Context.Snapshots.ToVersion.Version + ': ' + Deck + ' (empty deck)')
    else
      Context.Output.WriteLine('Only in version ' + Context.Snapshots.FromVersion.Version + ': ' + Deck + ' (empty deck)');
  end
  else
  begin
    FromMarker := '';
    ToMarker := '';
    if IgnoreHeaders then
    begin
      if InFrom then FromMarker := HeaderMarker(FromSource, Context.LibraryFile.DefaultCommentPrefix(Context.Snapshots.FromVersion.Version));
      if InTo then ToMarker := HeaderMarker(ToSource, Context.LibraryFile.DefaultCommentPrefix(Context.Snapshots.ToVersion.Version));
    end;
    Stats := WriteDeckDiff(FromSource.Bytes, ToSource.Bytes, FromLabel, ToLabel, Context.Output,
      IgnoreSpaceChanges, Format, True, FromMarker, ToMarker);
    if not Stats.Binary and (Stats.Added + Stats.Changed + Stats.Deleted = 0) then Exit;
  end;
  if not Assigned(Summary) then Exit;
  if not InFrom then Status := 'Added'
  else if not InTo then Status := 'Deleted'
  else Status := 'Modified';
  Inc(DeckCount);
  if Stats.Binary then
    Summary.AddRow([Deck, Status + ' (binary)', '-', '-', '-'])
  else
    Summary.AddRow([Deck, Status, IntToStr(Stats.Added), IntToStr(Stats.Changed), IntToStr(Stats.Deleted)]);
  Inc(Total.Added, Stats.Added);
  Inc(Total.Changed, Stats.Changed);
  Inc(Total.Deleted, Stats.Deleted);
end;

function DisplayVersionDiff(var Context: TCommandContext): string;
var
  Decks: TStringList;
  Summary: TScuTable;
  Total: TDiffStats;
  DeckCount: Integer;
  Deck: string;
  IgnoreSpaceChanges, IgnoreHeaders: Boolean;
  Format: TDiffFormat;
begin
  IgnoreSpaceChanges := BooleanArgument(Context.Command, 'ignore_space_changes');
  IgnoreHeaders := BooleanArgument(Context.Command, 'ignore_legacy_scu_header');
  Format := ParseDiffFormat(Context.Command.Argument('output_format', 'normal'));
  Context.Snapshots.FromVersion := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['from_version']);
  Context.Snapshots.ToVersion := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['to_version']);
  Summary := nil;
  if Format = dfUnified then
    RequireArchiveSourceNames(Context.LibraryFile, Context.Database)
  else
  begin
    Context.Output.WriteLine('From version ' + Context.Snapshots.FromVersion.Version + '.');
    Context.Output.WriteLine('To version ' + Context.Snapshots.ToVersion.Version + '.');
    Summary := TScuTable.Create(['Deck name', 'Status', 'Added', 'Changed', 'Deleted'], 0);
  end;
  DeckCount := 0;
  Total := Default(TDiffStats);
  Decks := TStringList.Create;
  try
    Decks.CaseSensitive := True;
    Decks.Sorted := True;
    Decks.Duplicates := dupIgnore;
    Context.LibraryFile.ChangedDecks(0, Context.Snapshots.FromVersion.LibraryRevision, Decks);
    Context.LibraryFile.ChangedDecks(0, Context.Snapshots.ToVersion.LibraryRevision, Decks);
    for Deck in Decks do
    begin
      CheckSessionInterrupt;
      WriteChangedDeck(Context, Deck, IgnoreSpaceChanges, IgnoreHeaders, Format, Summary, Total, DeckCount);
    end;
    if not Assigned(Summary) then Exit('');
    if DeckCount = 0 then Context.Output.WriteLine('No decks differ.')
    else
    begin
      Summary.AddRow(['Total', '', IntToStr(Total.Added), IntToStr(Total.Changed), IntToStr(Total.Deleted)]);
      Context.Output.WriteLine('Diff summary (' + IntToStr(DeckCount) + ' changed)');
      Summary.WriteTo(Context.Output);
    end;
  finally
    Decks.Free;
    Summary.Free;
  end;
  Result := '';
end;

end.
