unit ScuSQLiteSchema;

{$mode objfpc}{$H+}

interface

uses
  ScuSQLiteDB;

function EnsureLibrarySchema(Database: TSQLiteConnection; AllowCreate: Boolean): Integer;

implementation

uses
  SysUtils, ScuErrors;

const
  ApplicationID = '1396921650';

procedure CreateAuditState(Database: TSQLiteConnection);
begin
  Database.Execute('CREATE TABLE IF NOT EXISTS audit_state (' +
    'id INTEGER PRIMARY KEY CHECK (id = 1), record_count INTEGER NOT NULL CHECK (record_count > 0), ' +
    'head TEXT NOT NULL, pending TEXT NOT NULL, pending_command TEXT NOT NULL, ' +
    'interrupted INTEGER NOT NULL CHECK (interrupted >= 0 AND interrupted < record_count), ' +
    'initialized INTEGER NOT NULL CHECK (initialized IN (0, 1)));' +
    'CREATE INDEX IF NOT EXISTS audit_digest ON audit_records (substr(line, 1, 64));' +
    'CREATE TRIGGER IF NOT EXISTS audit_state_insert AFTER INSERT ON audit_records ' +
      'BEGIN DELETE FROM audit_state WHERE id = 1; END;' +
    'CREATE TRIGGER IF NOT EXISTS audit_state_update AFTER UPDATE ON audit_records ' +
      'BEGIN DELETE FROM audit_state WHERE id = 1; END;' +
    'CREATE TRIGGER IF NOT EXISTS audit_state_delete AFTER DELETE ON audit_records ' +
      'BEGIN DELETE FROM audit_state WHERE id = 1; END;' +
    'PRAGMA user_version = 4');
end;

procedure CreateCopyMetadata(Database: TSQLiteConnection);
begin
  if Database.Scalar('SELECT 1 FROM pragma_table_info(''deck_revisions'') WHERE name = ''copy_metadata''') = '' then
    Database.Execute('ALTER TABLE deck_revisions ADD COLUMN copy_metadata TEXT');
  Database.Execute('PRAGMA user_version = 5');
end;

procedure CreateDeletionIndex(Database: TSQLiteConnection);
begin
  if Database.Scalar('SELECT 1 FROM pragma_table_info(''deck_revisions'') WHERE name = ''deleted''') = '' then
    Database.Execute('ALTER TABLE deck_revisions ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))');
  Database.Execute('PRAGMA user_version = 6');
end;

procedure CreateWorkingExports(Database: TSQLiteConnection);
begin
  Database.Execute('CREATE TABLE IF NOT EXISTS pending_working_exports (' +
    'file_key TEXT PRIMARY KEY, file_name BLOB NOT NULL, deck_name TEXT NOT NULL, ' +
    'library_version TEXT NOT NULL, deck_version TEXT NOT NULL, sha256 TEXT NOT NULL, ' +
    'removed INTEGER NOT NULL CHECK (removed IN (0, 1))); ' +
    'DROP TABLE IF EXISTS expansion_checkpoints; PRAGMA user_version = 7');
end;

function EnsureLibrarySchema(Database: TSQLiteConnection; AllowCreate: Boolean): Integer;
var
  ID: RawByteString;
begin
  ID := Database.Scalar('PRAGMA application_id');
  if ID = ApplicationID then
  begin
    Result := StrToIntDef(Database.Scalar('PRAGMA user_version'), 0);
    if not (Result in [1..7]) then
      raise EScuError.Create('Unsupported SQLite library schema in "' + Database.Path + '".');
    if not Database.ReadOnly then
    begin
      if Result = 1 then
      begin
        Result := 3;
      end;
      if Result = 2 then
      begin
        Result := 3;
      end;
      if Result = 3 then
      begin
        CreateAuditState(Database);
        Result := 4;
      end;
      if Result = 4 then
      begin
        CreateCopyMetadata(Database);
        Result := 5;
      end;
      if Result = 5 then
      begin
        CreateDeletionIndex(Database);
        Result := 6;
      end;
      if Result = 6 then
      begin
        CreateWorkingExports(Database);
        Result := 7;
      end;
    end;
    Exit;
  end;
  if not AllowCreate or (ID <> '0') or (Database.Scalar('SELECT count(*) FROM sqlite_master') <> '0') then
    raise EScuError.Create('The SQLite database is not an SCU library.');
  Database.Execute('CREATE TABLE library (id INTEGER PRIMARY KEY CHECK (id = 1), ' +
    'identity TEXT NOT NULL, generation INTEGER NOT NULL CHECK (generation > 0), payload TEXT NOT NULL);' +
    'CREATE TABLE deck_revisions (sequence INTEGER PRIMARY KEY CHECK (sequence > 0), ' +
    'deck_name TEXT NOT NULL, library_version TEXT NOT NULL, deck_revision TEXT NOT NULL, payload TEXT NOT NULL, ' +
    'UNIQUE (deck_name, library_version, deck_revision));' +
    'CREATE INDEX deck_revision_history ON deck_revisions (deck_name, sequence);' +
    'CREATE TABLE audit_records (sequence INTEGER PRIMARY KEY, line TEXT NOT NULL);' +
    'PRAGMA application_id = ' + ApplicationID);
  CreateAuditState(Database);
  CreateCopyMetadata(Database);
  CreateDeletionIndex(Database);
  CreateWorkingExports(Database);
  Result := 7;
end;

end.
