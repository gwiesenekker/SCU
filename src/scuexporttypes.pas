unit ScuExportTypes;

{$mode objfpc}{$H+}

interface

type
  TExportMode = (emExtract, emExpand);
  TExportStatus = (esCreated, esReplaced, esUnchanged);
  TExportResult = record
    Deck, DeckVersion: string;
    Status: TExportStatus;
  end;
  TExportResults = array of TExportResult;
  TExportRecord = record
    FileName, LibraryPath: RawByteString;
    Deck, LibraryVersion, DeckVersion, ExpansionUTC, CommentPrefix, SHA256: string;
    Mode: TExportMode;
    Interrupted: Boolean;
  end;
function ExportModeName(Mode: TExportMode): string;
implementation

function ExportModeName(Mode: TExportMode): string;
begin
  if Mode = emExpand then Result := 'expand' else Result := 'extract';
end;
end.
