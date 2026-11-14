unit ScuLibraryModel;

{$mode objfpc}{$H+}

// Compatibility facade; ownership and implementations live in the focused units.
interface

uses FPJSON, ScuLibraryNames, ScuLibraryHeader, ScuLibraryRevision;

const MaxDeckRevision = ScuLibraryNames.MaxDeckRevision;

type
  TLibrarySettingsChange = ScuLibraryHeader.TLibrarySettingsChange;
  TLibraryHeader = ScuLibraryHeader.TLibraryHeader;
  TLibraryRevision = ScuLibraryRevision.TLibraryRevision;

function NewLibraryMetadata(const Version: string): TJSONObject;
function NewRevisionPayload(const Name, Prefix, SHA1: string; Number: Integer;
  const Source: RawByteString): TJSONObject;
function NewDeletionPayload(const Name, Prefix: string; Number: Integer): TJSONObject;
function DeckName(const Name: string): string;
procedure ValidateFilePattern(const Pattern: string);

implementation

function NewLibraryMetadata(const Version: string): TJSONObject;
begin
  Result := ScuLibraryHeader.NewLibraryMetadata(Version);
end;

function NewRevisionPayload(const Name, Prefix, SHA1: string; Number: Integer;
  const Source: RawByteString): TJSONObject;
begin
  Result := ScuLibraryRevision.NewRevisionPayload(Name, Prefix, SHA1, Number, Source);
end;

function NewDeletionPayload(const Name, Prefix: string; Number: Integer): TJSONObject;
begin
  Result := ScuLibraryRevision.NewDeletionPayload(Name, Prefix, Number);
end;

function DeckName(const Name: string): string;
begin
  Result := ScuLibraryNames.DeckName(Name);
end;

procedure ValidateFilePattern(const Pattern: string);
begin
  ScuLibraryNames.ValidateFilePattern(Pattern);
end;

end.
