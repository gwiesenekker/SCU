unit ScuSQLite;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, SQLite3, CTypes;

type
  TAuditLineVisitor = procedure(const Line: RawByteString) of object;

  TSQLiteLibrary = class
  private
    FHandle: psqlite3;
    FReadOnly: Boolean;
    procedure Check(Status: cint);
    function Prepare(const SQL: RawByteString): psqlite3_stmt;
    function Next(Statement: psqlite3_stmt): Boolean;
    procedure BindText(Statement: psqlite3_stmt; Index: Integer; const Value: RawByteString);
    function Scalar(const SQL: RawByteString): RawByteString;
    function ReadMetadata: TJSONObject;
    function GetCurrentVersion: string;
    procedure CreateExpansionCheckpoints;
  public
    constructor Create(const Path: string; AllowCreate, ReadOnly: Boolean);
    destructor Destroy; override;
    procedure Execute(const SQL: RawByteString);
    procedure BeginTransaction(ReadOnly: Boolean);
    procedure Commit;
    procedure EnsureSchema(AllowCreate: Boolean);
    function StateKey: string;
    function RevisionCount: Integer;
    function ReadDocument: TJSONObject;
    procedure SaveMetadata(const Payload: RawByteString);
    procedure AppendRevision(Sequence: Integer; const Deck, Version, DeckRevision, Payload: RawByteString);
    procedure ReadAudit(Visit: TAuditLineVisitor);
    procedure AppendAudit(const Line: RawByteString);
    procedure ExportAudit(Dest: TStream; Limit: Int64);
    procedure ListExpansionCheckpoints(Dest: TStrings);
    function ReadExpansionCheckpoint(const Version, Directory: string; out Revision: Integer;
      out Refresh, BuildPending: Boolean): Boolean;
    function ResetExpansionCheckpoint(const Version, Directory: string): Boolean;
    function InvalidateExpansionOutput(const Version, Directory, Prefix: string): Boolean;
    procedure SaveExpansionCheckpoint(const Version, Directory, Prefix: string; Revision: Integer;
      BuildPending: Boolean);
    property CurrentVersion: string read GetCurrentVersion;
  end;

function IsSQLiteLibrary(const Path: string): Boolean;

implementation

uses
  SysUtils, BaseUnix, Linux, ScuIO, ScuJSON;

const
  ApplicationID = '1396921650';
  SQLiteSignature = 'SQLite format 3'#0;

function IsSQLiteLibrary(const Path: string): Boolean;
var
  Input: TFileStream;
  Signature: RawByteString;
begin
  if RegularFileExists(Path) then
  begin
    Input := TFileStream.Create(Path, fmOpenRead);
    try
      if Input.Size > 0 then
      begin
        SetLength(Signature, Length(SQLiteSignature));
        Exit((Input.Read(Signature[1], Length(Signature)) = Length(Signature)) and
          (Signature = SQLiteSignature));
      end;
    finally
      Input.Free;
    end;
  end;
  Result := SameText(ExtractFileExt(Path), '.sqlite') or SameText(ExtractFileExt(Path), '.sqlite3') or
    SameText(ExtractFileExt(Path), '.db');
end;

function ColumnText(Statement: psqlite3_stmt; Index: Integer): RawByteString;
var
  Data: PAnsiChar;
begin
  Data := sqlite3_column_text(Statement, Index);
  SetString(Result, Data, sqlite3_column_bytes(Statement, Index));
end;

constructor TSQLiteLibrary.Create(const Path: string; AllowCreate, ReadOnly: Boolean);
var
  Flags, Handle: cint;
begin
  inherited Create;
  FReadOnly := ReadOnly;
  if ReadOnly then
    Flags := SQLITE_OPEN_READONLY
  else
    Flags := SQLITE_OPEN_READWRITE;
  if AllowCreate then
  begin
    if not RegularFileExists(Path) then
    begin
      Handle := fpOpen(Path, O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC, &600);
      if Handle < 0 then
        RaiseLastOSError(fpGetErrNo);
      fpClose(Handle);
      SyncParent(Path);
    end;
    Flags := Flags or SQLITE_OPEN_CREATE;
  end;
  Check(sqlite3_open_v2(PAnsiChar(Path), @FHandle, Flags, nil));
  Check(sqlite3_busy_timeout(FHandle, 5000));
  if not ReadOnly then
    Execute('PRAGMA synchronous = FULL');
end;

destructor TSQLiteLibrary.Destroy;
begin
  if Assigned(FHandle) then
    sqlite3_close(FHandle); // Rolls back any open transaction.
  inherited Destroy;
end;

procedure TSQLiteLibrary.Check(Status: cint);
begin
  if Status <> SQLITE_OK then
    raise EScuError.CreateFmt('SQLite library error: %s', [StrPas(sqlite3_errmsg(FHandle))]);
end;

procedure TSQLiteLibrary.Execute(const SQL: RawByteString);
begin
  Check(sqlite3_exec(FHandle, PAnsiChar(SQL), nil, nil, nil));
end;

procedure TSQLiteLibrary.BeginTransaction(ReadOnly: Boolean);
begin
  if ReadOnly then
    Execute('BEGIN')
  else
    Execute('BEGIN IMMEDIATE');
end;

procedure TSQLiteLibrary.Commit;
begin
  Execute('COMMIT');
end;

function TSQLiteLibrary.Prepare(const SQL: RawByteString): psqlite3_stmt;
begin
  Result := nil;
  Check(sqlite3_prepare_v2(FHandle, PAnsiChar(SQL), Length(SQL), @Result, nil));
end;

function TSQLiteLibrary.Next(Statement: psqlite3_stmt): Boolean;
var
  Status: cint;
begin
  Status := sqlite3_step(Statement);
  case Status of
    SQLITE_ROW: Exit(True);
    SQLITE_DONE: Exit(False);
  end;
  Check(Status);
  Result := False;
end;

procedure TSQLiteLibrary.BindText(Statement: psqlite3_stmt; Index: Integer; const Value: RawByteString);
begin
  Check(sqlite3_bind_text(Statement, Index, PAnsiChar(Value), Length(Value),
    sqlite3_destructor_type(SQLITE_TRANSIENT)));
end;

function TSQLiteLibrary.Scalar(const SQL: RawByteString): RawByteString;
var
  Statement: psqlite3_stmt;
begin
  Result := '';
  Statement := Prepare(SQL);
  try
    if Next(Statement) then
      Result := ColumnText(Statement, 0);
  finally
    sqlite3_finalize(Statement);
  end;
end;

procedure TSQLiteLibrary.EnsureSchema(AllowCreate: Boolean);
var
  ID, SchemaVersion: RawByteString;
begin
  ID := Scalar('PRAGMA application_id');
  if ID = ApplicationID then
  begin
    SchemaVersion := Scalar('PRAGMA user_version');
    if SchemaVersion = '1' then
    begin
      if not FReadOnly then
        CreateExpansionCheckpoints;
    end
    else if SchemaVersion = '2' then
    begin
      if not FReadOnly then
        Execute('ALTER TABLE expansion_checkpoints ADD COLUMN build_pending INTEGER NOT NULL DEFAULT 0 ' +
          'CHECK (build_pending IN (0, 1)); PRAGMA user_version = 3');
    end
    else if SchemaVersion <> '3' then
      raise EScuError.Create('Unsupported SQLite library schema.');
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
end;

procedure TSQLiteLibrary.CreateExpansionCheckpoints;
begin
  Execute('CREATE TABLE expansion_checkpoints (' +
    'version TEXT NOT NULL, output_directory TEXT NOT NULL, ' +
    'revision INTEGER NOT NULL CHECK (revision >= 0), comment_prefix TEXT, ' +
    'build_pending INTEGER NOT NULL DEFAULT 0 CHECK (build_pending IN (0, 1)), ' +
    'PRIMARY KEY (version, output_directory)); PRAGMA user_version = 3');
end;

procedure TSQLiteLibrary.ListExpansionCheckpoints(Dest: TStrings);
var
  Statement: psqlite3_stmt;
  Status: string;
begin
  // Follow each build's expansion outcome back to the command that produced it.
  Statement := Prepare(
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
    while Next(Statement) do
    begin
      if sqlite3_column_int(Statement, 3) <> 0 then
        Status := 'Full rebuild pending'
      else
        Status := 'Incremental';
      Dest.Add(ColumnText(Statement, 0) + #9 + StringToJSONString(ColumnText(Statement, 1)) +
        #9 + ColumnText(Statement, 5) + #9 + Status + #9 + ColumnText(Statement, 4) +
        #9 + IntToStr(sqlite3_column_int64(Statement, 2)));
    end;
  finally
    sqlite3_finalize(Statement);
  end;
end;

function TSQLiteLibrary.ReadExpansionCheckpoint(const Version, Directory: string;
  out Revision: Integer; out Refresh, BuildPending: Boolean): Boolean;
var
  Statement: psqlite3_stmt;
begin
  Statement := Prepare('SELECT revision, comment_prefix, build_pending FROM expansion_checkpoints ' +
    'WHERE version = ? AND output_directory = ?');
  try
    BindText(Statement, 1, Version);
    BindText(Statement, 2, Directory);
    Result := Next(Statement);
    Revision := 0;
    Refresh := False;
    BuildPending := False;
    if Result then
    begin
      Revision := sqlite3_column_int(Statement, 0);
      Refresh := sqlite3_column_type(Statement, 1) = SQLITE_NULL;
      BuildPending := sqlite3_column_int(Statement, 2) <> 0;
    end;
  finally
    sqlite3_finalize(Statement);
  end;
end;

function TSQLiteLibrary.ResetExpansionCheckpoint(const Version, Directory: string): Boolean;
var
  Statement: psqlite3_stmt;
begin
  Statement := Prepare('UPDATE expansion_checkpoints SET comment_prefix = NULL ' +
    'WHERE version = ? AND output_directory = ?');
  try
    BindText(Statement, 1, Version);
    BindText(Statement, 2, Directory);
    Next(Statement);
    Result := sqlite3_changes(FHandle) <> 0;
  finally
    sqlite3_finalize(Statement);
  end;
end;

function TSQLiteLibrary.InvalidateExpansionOutput(const Version, Directory, Prefix: string): Boolean;
var
  Statement: psqlite3_stmt;
begin
  // NULL preserves the last successful revision while requiring a full refresh.
  // A batch with work can also replace files from a different version.
  Statement := Prepare('UPDATE expansion_checkpoints SET comment_prefix = NULL ' +
    'WHERE output_directory = ?2 AND comment_prefix IS NOT NULL AND (' +
    '(version = ?1 AND comment_prefix <> ?3) OR (version <> ?1 AND EXISTS (' +
    'SELECT 1 FROM deck_revisions WHERE library_version = ?1 AND sequence > COALESCE((' +
    'SELECT revision FROM expansion_checkpoints WHERE version = ?1 AND output_directory = ?2 ' +
    'AND comment_prefix = ?3), 0))))');
  try
    BindText(Statement, 1, Version);
    BindText(Statement, 2, Directory);
    BindText(Statement, 3, Prefix);
    Next(Statement);
    Result := sqlite3_changes(FHandle) <> 0;
  finally
    sqlite3_finalize(Statement);
  end;
end;

procedure TSQLiteLibrary.SaveExpansionCheckpoint(const Version, Directory, Prefix: string;
  Revision: Integer; BuildPending: Boolean);
var
  Statement: psqlite3_stmt;
begin
  Statement := Prepare('INSERT INTO expansion_checkpoints ' +
    '(version, output_directory, revision, comment_prefix, build_pending) VALUES (?, ?, ?, ?, ?) ' +
    'ON CONFLICT(version, output_directory) DO UPDATE SET ' +
    'revision = excluded.revision, comment_prefix = excluded.comment_prefix, build_pending = excluded.build_pending');
  try
    BindText(Statement, 1, Version);
    BindText(Statement, 2, Directory);
    Check(sqlite3_bind_int(Statement, 3, Revision));
    BindText(Statement, 4, Prefix);
    Check(sqlite3_bind_int(Statement, 5, Ord(BuildPending)));
    Next(Statement);
  finally
    sqlite3_finalize(Statement);
  end;
end;

function TSQLiteLibrary.StateKey: string;
begin
  Result := Scalar('SELECT identity || '':'' || generation FROM library WHERE id = 1');
end;

function TSQLiteLibrary.RevisionCount: Integer;
begin
  Result := StrToInt(Scalar('SELECT count(*) FROM deck_revisions'));
end;

function TSQLiteLibrary.ReadMetadata: TJSONObject;
var
  Metadata: RawByteString;
begin
  Metadata := Scalar('SELECT payload FROM library WHERE id = 1');
  if Metadata = '' then
    raise EScuError.Create('The SQLite library has not been initialized.');
  Result := ParseObject(Metadata);
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

function TSQLiteLibrary.ReadDocument: TJSONObject;
var
  Revisions: TJSONArray;
  Statement: psqlite3_stmt;
  Entry: TJSONObject;
begin
  Result := ReadMetadata;
  try
    Revisions := TJSONArray.Create;
    Result.Add('revisions', Revisions);
    Statement := Prepare('SELECT sequence, deck_name, payload FROM deck_revisions ORDER BY sequence');
    try
      while Next(Statement) do
      begin
        if sqlite3_column_int64(Statement, 0) <> Int64(Revisions.Count) + 1 then
          raise EScuError.Create('Invalid SQLite deck revision sequence.');
        Entry := ParseObject(ColumnText(Statement, 2));
        Revisions.Add(Entry);
        if Field(Entry, 'deck', jtString).AsString <> ColumnText(Statement, 1) then
          raise EScuError.Create('The SQLite deck name does not match its payload.');
      end;
    finally
      sqlite3_finalize(Statement);
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TSQLiteLibrary.SaveMetadata(const Payload: RawByteString);
var
  Statement: psqlite3_stmt;
begin
  Statement := Prepare('INSERT INTO library VALUES (1, lower(hex(randomblob(16))), 1, ?) ' +
    'ON CONFLICT(id) DO UPDATE SET generation = generation + 1, payload = excluded.payload');
  try
    BindText(Statement, 1, Payload);
    Next(Statement);
  finally
    sqlite3_finalize(Statement);
  end;
end;

procedure TSQLiteLibrary.AppendRevision(Sequence: Integer;
  const Deck, Version, DeckRevision, Payload: RawByteString);
var
  Statement: psqlite3_stmt;
begin
  Statement := Prepare('INSERT INTO deck_revisions VALUES (?, ?, ?, ?, ?)');
  try
    Check(sqlite3_bind_int(Statement, 1, Sequence));
    BindText(Statement, 2, Deck);
    BindText(Statement, 3, Version);
    BindText(Statement, 4, DeckRevision);
    BindText(Statement, 5, Payload);
    Next(Statement);
  finally
    sqlite3_finalize(Statement);
  end;
end;

procedure TSQLiteLibrary.ReadAudit(Visit: TAuditLineVisitor);
var
  Statement: psqlite3_stmt;
  Sequence: Int64;
begin
  Sequence := 0;
  Statement := Prepare('SELECT sequence, line FROM audit_records ORDER BY sequence');
  try
    while Next(Statement) do
    begin
      Inc(Sequence);
      if sqlite3_column_int64(Statement, 0) <> Sequence then
        raise EScuError.Create('Invalid SQLite audit record sequence.');
      Visit(ColumnText(Statement, 1));
    end;
  finally
    sqlite3_finalize(Statement);
  end;
end;

procedure TSQLiteLibrary.AppendAudit(const Line: RawByteString);
var
  Statement: psqlite3_stmt;
begin
  Statement := Prepare('INSERT INTO audit_records (line) VALUES (?)');
  try
    BindText(Statement, 1, Line);
    Next(Statement);
  finally
    sqlite3_finalize(Statement);
  end;
end;

procedure TSQLiteLibrary.ExportAudit(Dest: TStream; Limit: Int64);
var
  Statement: psqlite3_stmt;
  Line: RawByteString;
begin
  Statement := Prepare('SELECT line FROM audit_records WHERE sequence <= ? ORDER BY sequence');
  try
    Check(sqlite3_bind_int64(Statement, 1, Limit));
    while Next(Statement) do
    begin
      Line := ColumnText(Statement, 0) + #10;
      Dest.WriteBuffer(Line[1], Length(Line));
    end;
  finally
    sqlite3_finalize(Statement);
  end;
end;

end.
