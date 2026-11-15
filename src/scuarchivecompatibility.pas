unit ScuArchiveCompatibility;

{$mode objfpc}{$H+}

interface

uses ScuLibrary, ScuSQLite;

// Never guess a numeric filename or rewrite revisions covered by audit digests.
procedure RequireArchiveSourceNames(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary;
  LibraryRevision: Integer);

implementation

uses FPJSON, ScuJSON, ScuErrors;

procedure RequireArchiveSourceNames(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary;
  LibraryRevision: Integer);
const ManifestDeck = 'scu-import-manifest.json';
var
  Snapshot: TLibrarySnapshot;
  Source: TDeckSource;
  Document: TJSONObject;
begin
  if not LibraryFile.TryDeckSnapshot(ManifestDeck, LibraryRevision, Snapshot) then Exit;
  Source := LibraryFile.ReadDeckMetadata(Database, ManifestDeck, Snapshot.LibraryRevision);
  if Source.SourcePath <> 'manifest.json' then Exit;
  Source := LibraryFile.Extract(Database, ManifestDeck, Snapshot.LibraryRevision);
  try
    Document := ParseObject(Source.Bytes, ManifestDeck);
  except
    on E: EScuError do Exit; // An ordinary deck with the same name is not provenance.
  end;
  try
    if not Assigned(Document.Find('source_archive', jtString)) or
      not Assigned(Document.Find('files', jtArray)) or
      not Assigned(Document.Find('history', jtArray)) or
      not Assigned(Document.Find('format', jtNumber)) then Exit;
    if Document.Integers['format'] <> 1 then Exit;
    raise EScuError.Create('This archive library was created by the old importer with temporary source filenames. ' +
      'Rebuild from the original archive with tools/import_versions.py ARCHIVE NEW.sqlite, then verify and use the new library. ' +
      'The existing library and its audited revisions have not been rewritten.');
  finally
    Document.Free;
  end;
end;

end.
