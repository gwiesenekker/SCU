unit ScuSQLite;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, SQLite3, CTypes;

type
  TAuditLineVisitor = procedure(const Line: RawByteString) of object;
  TRevisionIndexVisitor = procedure(const Deck, DeckRevision: string) of object;
  TAuditState = record
    RecordCount, Interrupted: Int64;
    Head, Pending, PendingCommand: string;
    Initialized: Boolean;
  end;

  TSQLiteLibrary = class
  private type
    TOpenMode = (omRead, omWrite, omInitialize);
  private
    FHandle: psqlite3;
    FPath: string;
    FReadOnly: Boolean;
    FSchemaVersion: Integer;
    class function OpenTransaction(const Path: string; Mode: TOpenMode): TSQLiteLibrary; static;
    procedure OpenConnection(const Path: string; Mode: TOpenMode);
    procedure Check(Status: cint; const Operation: string);
    procedure EnsureSchema(AllowCreate: Boolean);
    function Scalar(const SQL: RawByteString): RawByteString;
    function GetCurrentVersion: string;
    procedure CreateExpansionCheckpoints;
    procedure CreateAuditState;
    procedure CreateCopyMetadata;
  public
    // Each factory returns a connection with an active transaction.
    class function OpenRead(const Path: string): TSQLiteLibrary; static;
    class function OpenWrite(const Path: string): TSQLiteLibrary; static;
    class function OpenForInitialization(const Path: string): TSQLiteLibrary; static;
    destructor Destroy; override;
    procedure Execute(const SQL: RawByteString);
    procedure BeginTransaction;
    procedure Commit;
    function StateKey: string;
    function RevisionCount: Integer;
    function ReadMetadata: TJSONObject;
    procedure ReadRevisionIndex(Visit: TRevisionIndexVisitor);
    function ReadRevision(Sequence: Integer): TJSONObject;
    function ReadCopyMetadata(Revision: Integer): TJSONObject;
    function ReadRevisionCopyMetadata(Sequence: Integer): RawByteString;
    procedure CacheCopyMetadata(Sequence: Integer; const Metadata: RawByteString);
    procedure SaveMetadata(const Payload: RawByteString);
    procedure AppendRevision(Sequence: Integer;
      const Deck, Version, DeckRevision, Payload, CopyMetadata: RawByteString);
    function AuditStateUsable: Boolean;
    function ReadAuditState(out State: TAuditState): Boolean;
    procedure SaveAuditState(const State: TAuditState);
    procedure ClearAuditState;
    function ReadAuditTail(out Sequence: Int64; out Line, PreviousDigest: RawByteString): Boolean;
    function HasAuditDigest(const Digest: string): Boolean;
    procedure ReadAudit(Visit: TAuditLineVisitor);
    procedure ReadCommandHistory(Limit: Int64; Visit: TAuditLineVisitor);
    procedure AppendAudit(Sequence: Int64; const Line: RawByteString);
    procedure ListExpansionCheckpoints(Dest: TStrings);
    function ReadExpansionCheckpoint(const Version, Directory: string; out Revision: Integer;
      out Refresh, BuildPending: Boolean): Boolean;
    function ResetExpansionCheckpoint(const Version, Directory: string): Boolean;
    function InvalidateExpansionOutput(const Version, Directory, Prefix: string): Boolean;
    procedure SaveExpansionCheckpoint(const Version, Directory, Prefix: string; Revision: Integer;
      BuildPending: Boolean);
    property Path: string read FPath;
    property CurrentVersion: string read GetCurrentVersion;
  end;

implementation

uses
  SysUtils, BaseUnix, Linux, ScuIO, ScuJSON;

const
  ApplicationID = '1396921650';

type
  TSQLiteStatement = class
  private
    FDatabase: TSQLiteLibrary;
    FHandle: psqlite3_stmt;
    function GetText(Index: Integer): RawByteString;
    function GetInteger(Index: Integer): Integer;
    function GetInt64(Index: Integer): Int64;
  public
    constructor Create(Database: TSQLiteLibrary; const SQL: RawByteString);
    destructor Destroy; override;
    procedure Bind(Index: Integer; const Value: RawByteString); overload;
    procedure Bind(Index: Integer; Value: Int64); overload;
    procedure BindNull(Index: Integer);
    function Step: Boolean;
    function IsNull(Index: Integer): Boolean;
    property Text[Index: Integer]: RawByteString read GetText;
    property Integers[Index: Integer]: Integer read GetInteger;
    property Int64s[Index: Integer]: Int64 read GetInt64;
  end;

procedure TSQLiteLibrary.Check(Status: cint; const Operation: string);
begin
  if Status <> SQLITE_OK then
    raise EScuError.CreateFmt('SQLite library error while %s in "%s": %s',
      [Operation, FPath, StrPas(sqlite3_errmsg(FHandle))]);
end;

constructor TSQLiteStatement.Create(Database: TSQLiteLibrary; const SQL: RawByteString);
begin
  inherited Create;
  FDatabase := Database;
  FDatabase.Check(sqlite3_prepare_v2(FDatabase.FHandle, PAnsiChar(SQL), Length(SQL), @FHandle, nil),
    'preparing a statement');
end;

destructor TSQLiteStatement.Destroy;
begin
  if Assigned(FHandle) then
    sqlite3_finalize(FHandle);
  inherited Destroy;
end;

procedure TSQLiteStatement.Bind(Index: Integer; const Value: RawByteString);
begin
  FDatabase.Check(sqlite3_bind_text(FHandle, Index, PAnsiChar(Value), Length(Value),
    sqlite3_destructor_type(SQLITE_TRANSIENT)), 'binding a statement parameter');
end;

procedure TSQLiteStatement.Bind(Index: Integer; Value: Int64);
begin
  FDatabase.Check(sqlite3_bind_int64(FHandle, Index, Value), 'binding a statement parameter');
end;

procedure TSQLiteStatement.BindNull(Index: Integer);
begin
  FDatabase.Check(sqlite3_bind_null(FHandle, Index), 'binding a statement parameter');
end;

function TSQLiteStatement.Step: Boolean;
var
  Status: cint;
begin
  Status := sqlite3_step(FHandle);
  case Status of
    SQLITE_ROW: Exit(True);
    SQLITE_DONE: Exit(False);
  end;
  FDatabase.Check(Status, 'running a statement');
  Result := False;
end;

function TSQLiteStatement.GetText(Index: Integer): RawByteString;
var
  Data: PAnsiChar;
begin
  Data := sqlite3_column_text(FHandle, Index);
  SetString(Result, Data, sqlite3_column_bytes(FHandle, Index));
end;

function TSQLiteStatement.GetInteger(Index: Integer): Integer;
begin
  Result := sqlite3_column_int(FHandle, Index);
end;

function TSQLiteStatement.GetInt64(Index: Integer): Int64;
begin
  Result := sqlite3_column_int64(FHandle, Index);
end;

function TSQLiteStatement.IsNull(Index: Integer): Boolean;
begin
  Result := sqlite3_column_type(FHandle, Index) = SQLITE_NULL;
end;

class function TSQLiteLibrary.OpenRead(const Path: string): TSQLiteLibrary;
begin
  Result := OpenTransaction(Path, omRead);
end;

class function TSQLiteLibrary.OpenWrite(const Path: string): TSQLiteLibrary;
begin
  Result := OpenTransaction(Path, omWrite);
end;

class function TSQLiteLibrary.OpenForInitialization(const Path: string): TSQLiteLibrary;
begin
  Result := OpenTransaction(Path, omInitialize);
end;

class function TSQLiteLibrary.OpenTransaction(const Path: string; Mode: TOpenMode): TSQLiteLibrary;
begin
  Result := TSQLiteLibrary.Create;
  try
    Result.OpenConnection(Path, Mode);
    Result.BeginTransaction;
    Result.EnsureSchema(Mode = omInitialize);
  except
    Result.Free;
    raise;
  end;
end;

procedure TSQLiteLibrary.OpenConnection(const Path: string; Mode: TOpenMode);
var
  Flags, Handle, OpenStatus: cint;
begin
  FPath := Path;
  FReadOnly := Mode = omRead;
  if FReadOnly then
    Flags := SQLITE_OPEN_READONLY
  else
    Flags := SQLITE_OPEN_READWRITE;
  if Mode = omInitialize then
  begin
    if not RegularFileExists(Path) then
    begin
      Handle := fpOpen(Path, O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC, &600);
      if Handle < 0 then
        RaiseSystemError('Could not create SQLite library "' + Path + '"', fpGetErrNo);
      fpClose(Handle);
      SyncParent(Path);
    end;
    Flags := Flags or SQLITE_OPEN_CREATE;
  end;
  OpenStatus := sqlite3_open_v2(PAnsiChar(Path), @FHandle, Flags, nil);
  Check(OpenStatus, 'opening the database');
  Check(sqlite3_busy_timeout(FHandle, 5000), 'setting the busy timeout');
  if not FReadOnly then
    Execute('PRAGMA synchronous = FULL');
end;

destructor TSQLiteLibrary.Destroy;
begin
  if Assigned(FHandle) then
    sqlite3_close(FHandle); // Rolls back any open transaction.
  inherited Destroy;
end;

procedure TSQLiteLibrary.Execute(const SQL: RawByteString);
begin
  Check(sqlite3_exec(FHandle, PAnsiChar(SQL), nil, nil, nil), 'executing SQL');
end;

procedure TSQLiteLibrary.BeginTransaction;
begin
  if FReadOnly then
    Execute('BEGIN')
  else
    Execute('BEGIN IMMEDIATE');
end;

procedure TSQLiteLibrary.Commit;
begin
  Execute('COMMIT');
end;

function TSQLiteLibrary.Scalar(const SQL: RawByteString): RawByteString;
var
  Statement: TSQLiteStatement;
begin
  Result := '';
  Statement := TSQLiteStatement.Create(Self, SQL);
  try
    if Statement.Step then
      Result := Statement.Text[0];
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.EnsureSchema(AllowCreate: Boolean);
var
  ID: RawByteString;
begin
  ID := Scalar('PRAGMA application_id');
  if ID = ApplicationID then
  begin
    FSchemaVersion := StrToIntDef(Scalar('PRAGMA user_version'), 0);
    if not (FSchemaVersion in [1..5]) then
      raise EScuError.Create('Unsupported SQLite library schema.');
    if not FReadOnly then
    begin
      if FSchemaVersion = 1 then
        CreateExpansionCheckpoints;
      if FSchemaVersion = 2 then
      begin
        Execute('ALTER TABLE expansion_checkpoints ADD COLUMN build_pending INTEGER NOT NULL DEFAULT 0 ' +
          'CHECK (build_pending IN (0, 1)); PRAGMA user_version = 3');
        FSchemaVersion := 3;
      end;
      if FSchemaVersion = 3 then
        CreateAuditState;
      if FSchemaVersion = 4 then
        CreateCopyMetadata;
    end;
    Exit;
  end;
  if not AllowCreate or (ID <> '0') or (Scalar('SELECT count(*) FROM sqlite_master') <> '0') then
    raise EScuError.Create('The SQLite database is not an SCU library.');
  Execute('CREATE TABLE library (id INTEGER PRIMARY KEY CHECK (id = 1), ' +
    'identity TEXT NOT NULL, generation INTEGER NOT NULL CHECK (generation > 0), payload TEXT NOT NULL);' +
    'CREATE TABLE deck_revisions (sequence INTEGER PRIMARY KEY CHECK (sequence > 0), ' +
    'deck_name TEXT NOT NULL, library_version TEXT NOT NULL, deck_revision TEXT NOT NULL, payload TEXT NOT NULL, ' +
    'UNIQUE (deck_name, library_version, deck_revision));' +
    'CREATE INDEX deck_revision_history ON deck_revisions (deck_name, sequence);' +
    'CREATE TABLE audit_records (sequence INTEGER PRIMARY KEY, line TEXT NOT NULL);' +
    'PRAGMA application_id = ' + ApplicationID);
  CreateExpansionCheckpoints;
  CreateAuditState;
  CreateCopyMetadata;
end;

procedure TSQLiteLibrary.CreateExpansionCheckpoints;
begin
  Execute('CREATE TABLE expansion_checkpoints (' +
    'version TEXT NOT NULL, output_directory TEXT NOT NULL, ' +
    'revision INTEGER NOT NULL CHECK (revision >= 0), comment_prefix TEXT, ' +
    'build_pending INTEGER NOT NULL DEFAULT 0 CHECK (build_pending IN (0, 1)), ' +
    'PRIMARY KEY (version, output_directory)); PRAGMA user_version = 3');
  FSchemaVersion := 3;
end;

procedure TSQLiteLibrary.CreateAuditState;
begin
  Execute('CREATE TABLE IF NOT EXISTS audit_state (' +
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
  FSchemaVersion := 4;
end;

procedure TSQLiteLibrary.CreateCopyMetadata;
begin
  if Scalar('SELECT 1 FROM pragma_table_info(''deck_revisions'') WHERE name = ''copy_metadata''') = '' then
    Execute('ALTER TABLE deck_revisions ADD COLUMN copy_metadata TEXT');
  Execute('PRAGMA user_version = 5');
  FSchemaVersion := 5;
end;

procedure TSQLiteLibrary.ListExpansionCheckpoints(Dest: TStrings);
var
  Statement: TSQLiteStatement;
  Status: string;
begin
  // Follow each build's expansion outcome back to the command that produced it.
  Statement := TSQLiteStatement.Create(Self,
    'WITH events AS MATERIALIZED (' +
      'SELECT sequence, substr(line, 1, 64) AS digest, substr(line, 66) AS payload FROM audit_records' +
    '), successful_builds AS MATERIALIZED (' +
      'SELECT build.sequence, json_extract(build.payload, ''$.utc'') AS built_utc, ' +
        'json_extract(build.payload, ''$.output_path'') AS output_directory, ' +
        'json_extract(outcome.payload, ''$.snapshot.version'') AS version, ' +
        'json_extract(outcome.payload, ''$.snapshot.library_revision'') AS revision ' +
      'FROM events AS build ' +
      'JOIN events AS outcome ON outcome.digest = json_extract(build.payload, ''$.expansion'') ' +
      'JOIN events AS attempt ON attempt.digest = json_extract(outcome.payload, ''$.begin'') ' +
      'WHERE json_extract(build.payload, ''$.phase'') = ''build'' ' +
        'AND json_extract(build.payload, ''$.success'') = 1 ' +
        'AND json_extract(attempt.payload, ''$.command'') = ''expand_modified_decks''' +
    ') ' +
    'SELECT checkpoint.version, checkpoint.output_directory, checkpoint.revision, ' +
      'checkpoint.comment_prefix IS NULL, COALESCE(last_build.built_utc, ''None''), ' +
      'COALESCE(last_build.revision, ''None'') ' +
    'FROM expansion_checkpoints AS checkpoint ' +
    'LEFT JOIN successful_builds AS last_build ON last_build.sequence = (' +
        'SELECT build.sequence FROM successful_builds AS build ' +
        'WHERE build.version = checkpoint.version AND build.output_directory = checkpoint.output_directory ' +
          'AND build.revision <= checkpoint.revision ORDER BY build.sequence DESC LIMIT 1' +
    ') ORDER BY checkpoint.version, checkpoint.output_directory');
  try
    while Statement.Step do
    begin
      if Statement.Integers[3] <> 0 then
        Status := 'Full rebuild pending'
      else
        Status := 'Incremental';
      Dest.Add(Statement.Text[0] + #9 + StringToJSONString(Statement.Text[1]) +
        #9 + Statement.Text[5] + #9 + Status + #9 + Statement.Text[4] +
        #9 + IntToStr(Statement.Int64s[2]));
    end;
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.ReadExpansionCheckpoint(const Version, Directory: string;
  out Revision: Integer; out Refresh, BuildPending: Boolean): Boolean;
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'SELECT revision, comment_prefix, build_pending FROM expansion_checkpoints ' +
    'WHERE version = ? AND output_directory = ?');
  try
    Statement.Bind(1, Version);
    Statement.Bind(2, Directory);
    Result := Statement.Step;
    Revision := 0;
    Refresh := False;
    BuildPending := False;
    if Result then
    begin
      Revision := Statement.Integers[0];
      Refresh := Statement.IsNull(1);
      BuildPending := Statement.Integers[2] <> 0;
    end;
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.ResetExpansionCheckpoint(const Version, Directory: string): Boolean;
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'UPDATE expansion_checkpoints SET comment_prefix = NULL ' +
    'WHERE version = ? AND output_directory = ?');
  try
    Statement.Bind(1, Version);
    Statement.Bind(2, Directory);
    Statement.Step;
    Result := sqlite3_changes(FHandle) <> 0;
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.InvalidateExpansionOutput(const Version, Directory, Prefix: string): Boolean;
var
  Statement: TSQLiteStatement;
begin
  // NULL preserves the last successful revision while requiring a full refresh.
  // A batch with work can also replace files from a different version.
  Statement := TSQLiteStatement.Create(Self, 'UPDATE expansion_checkpoints SET comment_prefix = NULL ' +
    'WHERE output_directory = ?2 AND comment_prefix IS NOT NULL AND (' +
    '(version = ?1 AND comment_prefix <> ?3) OR (version <> ?1 AND EXISTS (' +
    'SELECT 1 FROM deck_revisions WHERE library_version = ?1 AND sequence > COALESCE((' +
    'SELECT revision FROM expansion_checkpoints WHERE version = ?1 AND output_directory = ?2 ' +
    'AND comment_prefix = ?3), 0))))');
  try
    Statement.Bind(1, Version);
    Statement.Bind(2, Directory);
    Statement.Bind(3, Prefix);
    Statement.Step;
    Result := sqlite3_changes(FHandle) <> 0;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.SaveExpansionCheckpoint(const Version, Directory, Prefix: string;
  Revision: Integer; BuildPending: Boolean);
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'INSERT INTO expansion_checkpoints ' +
    '(version, output_directory, revision, comment_prefix, build_pending) VALUES (?, ?, ?, ?, ?) ' +
    'ON CONFLICT(version, output_directory) DO UPDATE SET ' +
    'revision = excluded.revision, comment_prefix = excluded.comment_prefix, build_pending = excluded.build_pending');
  try
    Statement.Bind(1, Version);
    Statement.Bind(2, Directory);
    Statement.Bind(3, Revision);
    Statement.Bind(4, Prefix);
    Statement.Bind(5, Ord(BuildPending));
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.StateKey: string;
begin
  Result := Scalar('SELECT identity || '':'' || generation FROM library WHERE id = 1');
end;

function TSQLiteLibrary.RevisionCount: Integer;
var
  Statement: TSQLiteStatement;
  Count: Int64;
begin
  Statement := TSQLiteStatement.Create(Self, 'SELECT count(*) FROM deck_revisions');
  try
    if not Statement.Step then
      raise EScuError.CreateFmt('Missing SQLite revision count in "%s".', [FPath]);
    Count := Statement.Int64s[0];
    if (Count < 0) or (Count > High(Integer)) then
      raise EScuError.CreateFmt('SQLite revision count %d in "%s" is out of range.', [Count, FPath]);
    Result := Count;
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.ReadMetadata: TJSONObject;
var
  Metadata: RawByteString;
begin
  Metadata := Scalar('SELECT payload FROM library WHERE id = 1');
  if Metadata = '' then
    raise EScuError.Create('The SQLite library has not been initialized.');
  Result := ParseObject(Metadata, 'SQLite library metadata in "' + FPath + '"');
end;

function TSQLiteLibrary.GetCurrentVersion: string;
var
  Metadata: TJSONObject;
begin
  Metadata := ReadMetadata;
  try
    Result := Field(TJSONObject(Field(Metadata, 'header', jtObject)), 'current_version', jtString).AsString;
  finally
    Metadata.Free;
  end;
end;

procedure TSQLiteLibrary.ReadRevisionIndex(Visit: TRevisionIndexVisitor);
var
  Statement: TSQLiteStatement;
  Sequence: Int64;
begin
  Sequence := 0;
  Statement := TSQLiteStatement.Create(Self,
    'SELECT sequence, deck_name, deck_revision FROM deck_revisions ORDER BY sequence');
  try
    while Statement.Step do
    begin
      Inc(Sequence);
      if Statement.Int64s[0] <> Sequence then
        raise EScuError.Create('Invalid SQLite deck revision sequence.');
      Visit(Statement.Text[1], Statement.Text[2]);
    end;
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.ReadRevision(Sequence: Integer): TJSONObject;
var
  Statement: TSQLiteStatement;
  Metadata: TJSONData;
  IndexMetadata: RawByteString;
begin
  if FSchemaVersion >= 5 then
    Statement := TSQLiteStatement.Create(Self, 'SELECT payload, copy_metadata FROM deck_revisions WHERE sequence = ?')
  else
    Statement := TSQLiteStatement.Create(Self, 'SELECT payload FROM deck_revisions WHERE sequence = ?');
  try
    Statement.Bind(1, Sequence);
    if not Statement.Step then
      raise EScuError.CreateFmt('SQLite library revision %d is missing.', [Sequence]);
    Result := ParseObject(Statement.Text[0], Format('SQLite revision %d payload in "%s"', [Sequence, FPath]));
    if FSchemaVersion >= 5 then
    begin
      Metadata := Result.Find('copy_metadata');
      IndexMetadata := Statement.Text[1];
      if Assigned(Metadata) and (Metadata.AsJSON <> IndexMetadata) then
      begin
        Result.Free;
        raise EScuError.CreateFmt('SQLite COPY metadata does not match revision %d.', [Sequence]);
      end;
    end;
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.ReadRevisionCopyMetadata(Sequence: Integer): RawByteString;
var
  Statement: TSQLiteStatement;
begin
  Result := '';
  if FSchemaVersion < 5 then
    Exit;
  Statement := TSQLiteStatement.Create(Self, 'SELECT copy_metadata FROM deck_revisions WHERE sequence = ?');
  try
    Statement.Bind(1, Sequence);
    if Statement.Step then
      Result := Statement.Text[0];
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.CacheCopyMetadata(Sequence: Integer; const Metadata: RawByteString);
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'UPDATE deck_revisions SET copy_metadata = ? WHERE sequence = ? AND copy_metadata IS NULL');
  try
    Statement.Bind(1, Metadata);
    Statement.Bind(2, Sequence);
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.ReadCopyMetadata(Revision: Integer): TJSONObject;
var
  Statement: TSQLiteStatement;
  Name: string;
begin
  Statement := TSQLiteStatement.Create(Self, 'SELECT stored.deck_name, stored.copy_metadata FROM (' +
    'SELECT max(sequence) AS sequence FROM deck_revisions WHERE sequence <= ? GROUP BY deck_name' +
    ') AS visible JOIN deck_revisions AS stored ON stored.sequence = visible.sequence');
  try
    Statement.Bind(1, Revision);
    Result := TJSONObject.Create;
    try
      while Statement.Step do
      begin
        Name := Statement.Text[0];
        if Statement.IsNull(1) then
          Result.Add(Name)
        else
          Result.Add(Name, ParseObject(Statement.Text[1],
            Format('SQLite COPY metadata for deck "%s" in "%s"', [Name, FPath])));
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.SaveMetadata(const Payload: RawByteString);
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'INSERT INTO library VALUES (1, lower(hex(randomblob(16))), 1, ?) ' +
    'ON CONFLICT(id) DO UPDATE SET generation = generation + 1, payload = excluded.payload');
  try
    Statement.Bind(1, Payload);
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.AppendRevision(Sequence: Integer;
  const Deck, Version, DeckRevision, Payload, CopyMetadata: RawByteString);
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'INSERT INTO deck_revisions ' +
    '(sequence, deck_name, library_version, deck_revision, payload, copy_metadata) VALUES (?, ?, ?, ?, ?, ?)');
  try
    Statement.Bind(1, Sequence);
    Statement.Bind(2, Deck);
    Statement.Bind(3, Version);
    Statement.Bind(4, DeckRevision);
    Statement.Bind(5, Payload);
    if CopyMetadata = '' then
      Statement.BindNull(6)
    else
      Statement.Bind(6, CopyMetadata);
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.AuditStateUsable: Boolean;
begin
  // A custom trigger may change audit records during our own transaction.
  Result := (FSchemaVersion >= 4) and (Scalar('SELECT count(*) = 3 AND ' +
    'sum(name IN (''audit_state_insert'', ''audit_state_update'', ''audit_state_delete'')) = 3 ' +
    'FROM sqlite_master WHERE type = ''trigger''') = '1');
end;

function TSQLiteLibrary.ReadAuditState(out State: TAuditState): Boolean;
var
  Statement: TSQLiteStatement;
begin
  State := Default(TAuditState);
  if FSchemaVersion < 4 then
    Exit(False);
  Statement := TSQLiteStatement.Create(Self, 'SELECT record_count, head, pending, pending_command, interrupted, initialized ' +
    'FROM audit_state WHERE id = 1');
  try
    Result := Statement.Step;
    if not Result then
      Exit;
    State.RecordCount := Statement.Int64s[0];
    State.Head := Statement.Text[1];
    State.Pending := Statement.Text[2];
    State.PendingCommand := Statement.Text[3];
    State.Interrupted := Statement.Int64s[4];
    State.Initialized := Statement.Integers[5] <> 0;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.SaveAuditState(const State: TAuditState);
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'INSERT INTO audit_state VALUES (1, ?, ?, ?, ?, ?, ?)');
  try
    Statement.Bind(1, State.RecordCount);
    Statement.Bind(2, State.Head);
    Statement.Bind(3, State.Pending);
    Statement.Bind(4, State.PendingCommand);
    Statement.Bind(5, State.Interrupted);
    Statement.Bind(6, Ord(State.Initialized));
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.ClearAuditState;
begin
  Execute('DELETE FROM audit_state WHERE id = 1');
end;

function TSQLiteLibrary.ReadAuditTail(out Sequence: Int64; out Line, PreviousDigest: RawByteString): Boolean;
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'SELECT tail.sequence, tail.line, ' +
    '(SELECT substr(line, 1, 64) FROM audit_records WHERE sequence = tail.sequence - 1) ' +
    'FROM audit_records AS tail ORDER BY tail.sequence DESC LIMIT 1');
  try
    Result := Statement.Step;
    if not Result then
      Exit;
    Sequence := Statement.Int64s[0];
    Line := Statement.Text[1];
    PreviousDigest := Statement.Text[2];
  finally
    Statement.Free;
  end;
end;

function TSQLiteLibrary.HasAuditDigest(const Digest: string): Boolean;
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'SELECT 1 FROM audit_records WHERE substr(line, 1, 64) = ? LIMIT 1');
  try
    Statement.Bind(1, Digest);
    Result := Statement.Step;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.ReadAudit(Visit: TAuditLineVisitor);
var
  Statement: TSQLiteStatement;
  Sequence: Int64;
begin
  Sequence := 0;
  Statement := TSQLiteStatement.Create(Self, 'SELECT sequence, line FROM audit_records ORDER BY sequence');
  try
    while Statement.Step do
    begin
      Inc(Sequence);
      if Statement.Int64s[0] <> Sequence then
        raise EScuError.Create('Invalid SQLite audit record sequence.');
      Visit(Statement.Text[1]);
    end;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.ReadCommandHistory(Limit: Int64; Visit: TAuditLineVisitor);
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'SELECT payload FROM (' +
    'SELECT sequence, substr(line, 66) AS payload FROM audit_records ' +
    'WHERE json_extract(substr(line, 66), ''$.phase'') = ''begin'' ' +
    'ORDER BY sequence DESC LIMIT ?) ORDER BY sequence');
  try
    Statement.Bind(1, Limit);
    while Statement.Step do
      Visit(Statement.Text[0]);
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteLibrary.AppendAudit(Sequence: Int64; const Line: RawByteString);
var
  Statement: TSQLiteStatement;
begin
  Statement := TSQLiteStatement.Create(Self, 'INSERT INTO audit_records (sequence, line) VALUES (?, ?)');
  try
    Statement.Bind(1, Sequence);
    Statement.Bind(2, Line);
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

end.
