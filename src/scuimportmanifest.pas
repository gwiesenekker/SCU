unit ScuImportManifest;

{$mode objfpc}{$H+}

interface

uses FPJSON, ScuSQLiteDB;

function StoreImportManifest(Database: TSQLiteConnection; const Version: string;
  Manifest: TJSONObject): string;
// Materialize manifests only for a full header display or recovery document.
procedure ReadImportManifests(Database: TSQLiteConnection; Header: TJSONObject;
  IncludePayload: Boolean);
procedure RestoreImportManifests(Database: TSQLiteConnection; Header: TJSONObject);

implementation

uses SysUtils, ScuCodec, ScuErrors, ScuJSON, ScuSignals;

const
  DigestField = 'import_manifest_sha256';
  PayloadField = 'import_manifest';

function StoreImportManifest(Database: TSQLiteConnection; const Version: string;
  Manifest: TJSONObject): string;
var
  Payload: RawByteString;
  Statement: TSQLiteStatement;
begin
  if (IntegerField(Manifest, 'format') <> 1) or
    (Field(Manifest, 'version', jtString).AsString <> Version) then
    raise EScuError.Create('Expected a format 1 import manifest for version ' + Version + '.');
  Field(Manifest, 'source_archive', jtString);
  Field(Manifest, 'files', jtArray);
  Field(Manifest, 'history', jtArray);
  Payload := Manifest.AsJSON;
  Result := AuditSHA256(Payload);
  Statement := Database.Prepare('INSERT INTO version_import_manifests(version, payload) VALUES (?, ?)');
  try
    Statement.Bind(1, Version);
    Statement.Bind(2, Payload);
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

procedure ReadImportManifests(Database: TSQLiteConnection; Header: TJSONObject;
  IncludePayload: Boolean);
var
  Versions: TJSONArray;
  Item: TJSONObject;
  Index, Count: Integer;
  Version: string;
  Statement: TSQLiteStatement;
  Payload: RawByteString;
begin
  Versions := TJSONArray(Field(Header, 'versions', jtArray));
  Count := 0;
  for Index := 0 to Versions.Count - 1 do
  begin
    Item := Versions.Objects[Index];
    if not Assigned(Item.Find(DigestField)) then Continue;
    CheckSessionInterrupt;
    Inc(Count);
    Version := Item.Strings['name'];
    Statement := Database.Prepare('SELECT payload FROM version_import_manifests WHERE version = ?');
    try
      Statement.Bind(1, Version);
      if not Statement.Step then
        raise EScuError.Create('Missing import manifest for version ' + Version + '.');
      Payload := Statement.Text[0];
    finally
      Statement.Free;
    end;
    if AuditSHA256(Payload) <> Field(Item, DigestField, jtString).AsString then
      raise EScuError.Create('Import manifest checksum mismatch for version ' + Version + '.');
    if IncludePayload then Item.Add(PayloadField, ParseObject(Payload, 'Import manifest for ' + Version));
  end;
  // Read-only access to libraries created before schema 8 also passes here.
  if Database.Scalar('SELECT name FROM sqlite_master WHERE name=''version_import_manifests''') <> '' then
    if Database.Scalar('SELECT count(*) FROM version_import_manifests') <> IntToStr(Count) then
      raise EScuError.Create('Unexpected import manifest outside version history.');
end;

procedure RestoreImportManifests(Database: TSQLiteConnection; Header: TJSONObject);
var
  Versions: TJSONArray;
  Index: Integer;
  Item: TJSONObject;
  Digest: string;
begin
  Versions := TJSONArray(Field(Header, 'versions', jtArray));
  for Index := 0 to Versions.Count - 1 do
  begin
    Item := Versions.Objects[Index];
    if not Assigned(Item.Find(DigestField)) then Continue;
    CheckSessionInterrupt;
    Digest := StoreImportManifest(Database, Item.Strings['name'],
      TJSONObject(Field(Item, PayloadField, jtObject)));
    if Digest <> Field(Item, DigestField, jtString).AsString then
      raise EScuError.Create('Recovered import manifest checksum mismatch for version ' + Item.Strings['name'] + '.');
    Item.Delete(PayloadField);
  end;
end;

end.
