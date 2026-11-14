unit ScuDeckExport;
{$mode objfpc}{$H+}
interface
uses ScuLibrary, ScuSQLite, ScuExportTypes;
type
  TRenderedDeck = record
    Bytes: RawByteString;
    DeckVersion, ExpansionUTC: string;
  end;
function RenderDeck(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary; const Deck: string;
  const Selection: TDeckSelection; Mode: TExportMode; const ExpansionUTC: string = ''): TRenderedDeck;
implementation
uses ScuExpand;
function RenderDeck(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary; const Deck: string;
  const Selection: TDeckSelection; Mode: TExportMode; const ExpansionUTC: string): TRenderedDeck;
var
  Expander: TDeckExpander;
  Source: TDeckSource;
  Root: Integer;
begin
  Result := Default(TRenderedDeck);
  if Mode = emExpand then
  begin
    Expander := TDeckExpander.Create(LibraryFile, Database, Selection.Snapshot.LibraryRevision,
      Selection.Snapshot.Version, ExpansionUTC);
    try
      Result.Bytes := Expander.Expand(Deck, Selection.RootRevision);
      Result.DeckVersion := Expander.RootDeckVersion;
      Result.ExpansionUTC := Expander.ExpansionUTC;
    finally
      Expander.Free;
    end;
  end
  else
  begin
    Root := Selection.RootRevision;
    if Root = 0 then Root := Selection.Snapshot.LibraryRevision;
    Source := LibraryFile.Extract(Database, Deck, Root, Selection.Snapshot.Version);
    Result.Bytes := Source.Bytes;
    Result.DeckVersion := Source.DeckVersion;
  end;
end;
end.
