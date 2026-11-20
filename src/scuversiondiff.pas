unit ScuVersionDiff;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function DisplayVersionDiff(var Context: TCommandContext): string;

implementation

uses
  ScuArchiveCompatibility, Classes, ScuDiff, ScuLibrary, ScuSignals;

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

procedure WriteChangedDeck(const Context: TCommandContext; const Deck: string; IgnoreSpaceChanges, IgnoreHeaders: Boolean; Format: TDiffFormat);
var
  FromDeck, ToDeck: TLibrarySnapshot;
  FromSource, ToSource: TDeckSource;
  FromLabel, ToLabel, FromMarker, ToMarker: string;
  InFrom, InTo: Boolean;
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
    WriteDeckDiff(FromSource.Bytes, ToSource.Bytes, FromLabel, ToLabel, Context.Output,
      IgnoreSpaceChanges, Format, True, FromMarker, ToMarker);
  end;
end;

function DisplayVersionDiff(var Context: TCommandContext): string;
var
  Decks: TStringList;
  Deck: string;
  IgnoreSpaceChanges, IgnoreHeaders: Boolean;
  Format: TDiffFormat;
begin
  IgnoreSpaceChanges := BooleanArgument(Context.Command, 'ignore_space_changes');
  IgnoreHeaders := BooleanArgument(Context.Command, 'ignore_legacy_scu_header');
  Format := ParseDiffFormat(Context.Command.Argument('output_format', 'normal'));
  Context.Snapshots.FromVersion := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['from_version']);
  Context.Snapshots.ToVersion := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['to_version']);
  if Format = dfUnified then
  begin
    RequireArchiveSourceNames(Context.LibraryFile, Context.Database);
  end;
  Context.Output.Report('From version ' + Context.Snapshots.FromVersion.Version + '.');
  Context.Output.Report('To version ' + Context.Snapshots.ToVersion.Version + '.');
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
      WriteChangedDeck(Context, Deck, IgnoreSpaceChanges, IgnoreHeaders, Format);
    end;
  finally
    Decks.Free;
  end;
  Result := '';
end;

end.
