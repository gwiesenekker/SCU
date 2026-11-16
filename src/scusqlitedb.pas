unit ScuSQLiteDB;

{$mode objfpc}{$H+}{$macro on}

interface

uses
  SQLite3, CTypes;

type
  TSQLiteStatement = class;

  TSQLiteConnection = class
  private
    FHandle: psqlite3;
    FPath: string;
    FReadOnly: Boolean;
    procedure Check(Status: cint; const Operation: string);
  protected
    procedure OpenConnection(const Path: string; OpenReadOnly, AllowCreate: Boolean;
      RecoverableRead: Boolean = False);
  public
    destructor Destroy; override;
    procedure Execute(const SQL: RawByteString);
    procedure BeginTransaction;
    procedure Commit;
    function Scalar(const SQL: RawByteString): RawByteString;
    function Prepare(const SQL: RawByteString): TSQLiteStatement;
    function Changes: Integer;
    property Path: string read FPath;
    property ReadOnly: Boolean read FReadOnly;
  end;

  TSQLiteStatement = class
  private
    FDatabase: TSQLiteConnection;
    FHandle: psqlite3_stmt;
    function GetText(Index: Integer): RawByteString;
    function GetInteger(Index: Integer): Integer;
    function GetInt64(Index: Integer): Int64;
  public
    constructor Create(Database: TSQLiteConnection; const SQL: RawByteString);
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

implementation

uses
  SysUtils, ScuErrors,
  {$IFDEF WINDOWS}
  ScuPlatformSQLiteWindows;
  {$DEFINE SQLiteBackend := ScuPlatformSQLiteWindows}
  {$ELSE}{$IFDEF LINUX}
  ScuPlatformSQLiteLinux;
  {$DEFINE SQLiteBackend := ScuPlatformSQLiteLinux}
  {$ELSE}{$FATAL No SCU SQLite backend for this platform}{$ENDIF}{$ENDIF}

procedure TSQLiteConnection.OpenConnection(const Path: string; OpenReadOnly, AllowCreate: Boolean;
  RecoverableRead: Boolean);
var
  Flags, OpenStatus: cint;
  Filename: RawByteString;
begin
  FPath := Path;
  FReadOnly := OpenReadOnly;
  if FReadOnly and (not RecoverableRead or (not SQLiteBackend.CanRecoverSQLite(Path))) then
    Flags := SQLITE_OPEN_READONLY
  else
    Flags := SQLITE_OPEN_READWRITE;
  if AllowCreate then
  begin
    SQLiteBackend.CreateSQLiteFile(Path);
    Flags := Flags or SQLITE_OPEN_CREATE;
  end;
  Filename := SQLiteBackend.SQLiteFilename(Path);
  OpenStatus := sqlite3_open_v2(PAnsiChar(Filename), @FHandle, Flags, nil);
  Check(OpenStatus, 'opening the database');
  Check(sqlite3_busy_timeout(FHandle, 5000), 'setting the busy timeout');
  if not FReadOnly then
    Execute('PRAGMA synchronous = FULL');
end;

destructor TSQLiteConnection.Destroy;
begin
  if Assigned(FHandle) then
    sqlite3_close(FHandle); // Rolls back any open transaction.
  inherited Destroy;
end;

procedure TSQLiteConnection.Execute(const SQL: RawByteString);
begin
  Check(sqlite3_exec(FHandle, PAnsiChar(SQL), nil, nil, nil), 'executing SQL');
end;

procedure TSQLiteConnection.BeginTransaction;
begin
  if FReadOnly then
    Execute('BEGIN')
  else
    Execute('BEGIN IMMEDIATE');
end;

procedure TSQLiteConnection.Commit;
begin
  Execute('COMMIT');
end;

function TSQLiteConnection.Scalar(const SQL: RawByteString): RawByteString;
var
  Statement: TSQLiteStatement;
begin
  Result := '';
  Statement := Prepare(SQL);
  try
    if Statement.Step then
      Result := Statement.Text[0];
  finally
    Statement.Free;
  end;
end;

function TSQLiteConnection.Prepare(const SQL: RawByteString): TSQLiteStatement;
begin
  Result := TSQLiteStatement.Create(Self, SQL);
end;

function TSQLiteConnection.Changes: Integer;
begin
  Result := sqlite3_changes(FHandle);
end;

procedure TSQLiteConnection.Check(Status: cint; const Operation: string);
begin
  if Status <> SQLITE_OK then
    raise EScuError.CreateFmt('SQLite library error while %s in "%s": %s',
      [Operation, FPath, StrPas(sqlite3_errmsg(FHandle))]);
end;

constructor TSQLiteStatement.Create(Database: TSQLiteConnection; const SQL: RawByteString);
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

end.
