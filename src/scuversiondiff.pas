unit ScuVersionDiff;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function DisplayVersionDiff(var Context: TCommandContext): string;

implementation

uses
  Classes, ScuDiff, ScuLibrary, ScuSignals;

procedure WriteChangedDeck(const Context: TCommandContext; const Deck: string);
var
  FromDeck, ToDeck: TLibrarySnapshot;
  FromSource, ToSource: TDeckSource;
  FromLabel, ToLabel: string;
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
    FromLabel := Deck + '@' + FromSource.DeckVersion;
  end;
  if InTo then
  begin
    ToSource := Context.LibraryFile.Extract(Context.Database, Deck, ToDeck.LibraryRevision);
    ToLabel := Deck + '@' + ToSource.DeckVersion;
  end;
  if (FromSource.Bytes = '') and (ToSource.Bytes = '') and (InFrom <> InTo) then
  begin
    if InTo then
      Context.Output.WriteLine('Only in version ' + Context.Snapshots.ToVersion.Version + ': ' + Deck + ' (empty deck)')
    else
      Context.Output.WriteLine('Only in version ' + Context.Snapshots.FromVersion.Version + ': ' + Deck + ' (empty deck)');
  end
  else
    WriteDeckDiff(FromSource.Bytes, ToSource.Bytes, FromLabel, ToLabel, Context.Output);
end;

function DisplayVersionDiff(var Context: TCommandContext): string;
var
  Decks: TStringList;
  Deck: string;
begin
  Context.Snapshots.FromVersion := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['from_version']);
  Context.Snapshots.ToVersion := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['to_version']);
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
      WriteChangedDeck(Context, Deck);
    end;
  finally
    Decks.Free;
  end;
  Result := '';
end;

end.
