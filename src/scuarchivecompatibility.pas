unit ScuArchiveCompatibility;

{$mode objfpc}{$H+}

interface

uses ScuLibrary, ScuSQLite;

// Never guess a numeric filename or rewrite revisions covered by audit digests.
procedure RequireArchiveSourceNames(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary);

implementation

uses Classes, SysUtils, FPJSON, ScuJSON, ScuErrors, ScuSignals;

function HasLegacyProvenance(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary;
  Revision: Integer): Boolean;
const ManifestDeck = 'scu-import-manifest.json';
var
  Source: TDeckSource;
  Document: TJSONObject;
begin
  Result := False;
  if LibraryFile.RevisionDeleted[Revision] then Exit;
  Source := LibraryFile.ReadDeckMetadata(Database, ManifestDeck, Revision);
  if Source.SourcePath <> 'manifest.json' then Exit;
  Source := LibraryFile.Extract(Database, ManifestDeck, Revision);
  try
    Document := ParseObject(Source.Bytes, ManifestDeck);
  except
    on E: EScuError do Exit; // An ordinary deck with the same name is not provenance.
  end;
  try
    Result := Assigned(Document.Find('source_archive', jtString)) and
      Assigned(Document.Find('files', jtArray)) and
      Assigned(Document.Find('history', jtArray)) and
      Assigned(Document.Find('format', jtNumber));
    if Result then Result := Document.Find('format').AsJSON = '1';
  finally
    Document.Free;
  end;
end;

procedure RequireArchiveSourceNames(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary);
var
  Revisions: TStringList;
  Item: string;
begin
  // Provenance is library-wide. Deleting or replacing its latest deck must not
  // hide an older importer revision, even when selecting a different snapshot.
  Revisions := TStringList.Create;
  try
    LibraryFile.ListDeckRevisions('scu-import-manifest.json', Revisions, [drLibraryRevision]);
    for Item in Revisions do
    begin
      CheckSessionInterrupt;
      if HasLegacyProvenance(LibraryFile, Database, StrToInt(Item)) then
        raise EScuError.Create('This archive library was created by the old importer with temporary source filenames. ' +
          'Rebuild from the original archive with tools/import_versions.py ARCHIVE NEW.sqlite, then verify and use the new library. ' +
          'The existing library and its audited revisions have not been rewritten.');
    end;
  finally
    Revisions.Free;
  end;
end;

end.
