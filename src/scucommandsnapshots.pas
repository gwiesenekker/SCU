unit ScuCommandSnapshots;

{$mode objfpc}{$H+}

interface


uses
  ScuLibraryTypes;


type
  TAuditSnapshots = record
    Selected, FromVersion, ToVersion: TLibrarySnapshot;
    ResolvedDeck, DeckVersion, FromDeckVersion, ToDeckVersion: string;
    OutputPath, OutputDirectory: string;
  end;

implementation


end.
