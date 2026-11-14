unit ScuSQLite;

{$mode objfpc}{$H+}

interface

uses
  ScuSQLiteDB, ScuSQLiteRevision, ScuSQLiteAudit, ScuSQLiteCheckpoint;

type
  TSQLiteLibrary = class(TSQLiteConnection)
  private type
    TOpenMode = (omRead, omWrite, omInitialize);
  private
    FRevisions: TSQLiteRevisionStore;
    FAudit: TSQLiteAuditStore;
    FCheckpoints: TSQLiteCheckpointStore;
    class function OpenTransaction(const LibraryPath: string; Mode: TOpenMode): TSQLiteLibrary; static;
  public
    // Each factory returns a connection with an active transaction.
    class function OpenRead(const LibraryPath: string): TSQLiteLibrary; static;
    class function OpenWrite(const LibraryPath: string): TSQLiteLibrary; static;
    class function OpenForInitialization(const LibraryPath: string): TSQLiteLibrary; static;
    destructor Destroy; override;
    property Revisions: TSQLiteRevisionStore read FRevisions;
    property Audit: TSQLiteAuditStore read FAudit;
    property Checkpoints: TSQLiteCheckpointStore read FCheckpoints;
  end;

implementation

uses
  SysUtils, ScuFiles, ScuSQLiteSchema;

class function TSQLiteLibrary.OpenRead(const LibraryPath: string): TSQLiteLibrary;
begin
  Result := OpenTransaction(LibraryPath, omRead);
end;

class function TSQLiteLibrary.OpenWrite(const LibraryPath: string): TSQLiteLibrary;
begin
  Result := OpenTransaction(LibraryPath, omWrite);
end;

class function TSQLiteLibrary.OpenForInitialization(const LibraryPath: string): TSQLiteLibrary;
begin
  Result := OpenTransaction(LibraryPath, omInitialize);
end;

class function TSQLiteLibrary.OpenTransaction(const LibraryPath: string; Mode: TOpenMode): TSQLiteLibrary;
var
  SchemaVersion: Integer;
begin
  Result := TSQLiteLibrary.Create;
  try
    // A physically writable, logically read-only connection lets SQLite
    // recover a hot journal without taking a second writer transaction. It
    // also remains compatible with a live writer's ordinary rollback journal.
    Result.OpenConnection(LibraryPath, Mode = omRead, Mode = omInitialize, Mode = omRead);
    if Mode = omRead then Result.Execute('PRAGMA query_only = ON');
    Result.BeginTransaction;
    SchemaVersion := EnsureLibrarySchema(Result, Mode = omInitialize);
    Result.FRevisions := TSQLiteRevisionStore.Create(Result, SchemaVersion);
    Result.FAudit := TSQLiteAuditStore.Create(Result, SchemaVersion);
    Result.FCheckpoints := TSQLiteCheckpointStore.Create(Result);
  except
    Result.Free;
    raise;
  end;
end;

destructor TSQLiteLibrary.Destroy;
begin
  FCheckpoints.Free;
  FAudit.Free;
  FRevisions.Free;
  inherited Destroy;
end;

end.
