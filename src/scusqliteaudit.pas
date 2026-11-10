unit ScuSQLiteAudit;

{$mode objfpc}{$H+}

interface

uses
  ScuSQLiteDB;

type
  TAuditLineVisitor = procedure(const Line: RawByteString) of object;
  TAuditState = record
    RecordCount, Interrupted: Int64;
    Head, Pending, PendingCommand: string;
    Initialized: Boolean;
  end;

  TSQLiteAuditStore = class
  private
    FDatabase: TSQLiteConnection;
    FSchemaVersion: Integer;
  public
    constructor Create(Database: TSQLiteConnection; SchemaVersion: Integer);
    function AuditStateUsable: Boolean;
    function ReadAuditState(out State: TAuditState): Boolean;
    procedure SaveAuditState(const State: TAuditState);
    procedure ClearAuditState;
    function ReadAuditTail(out Sequence: Int64; out Line, PreviousDigest: RawByteString): Boolean;
    function HasAuditDigest(const Digest: string): Boolean;
    procedure ReadAudit(Visit: TAuditLineVisitor);
    procedure ReadCommandHistory(Limit: Int64; Visit: TAuditLineVisitor);
    procedure AppendAudit(Sequence: Int64; const Line: RawByteString);
  end;

implementation

uses
  ScuErrors;

constructor TSQLiteAuditStore.Create(Database: TSQLiteConnection; SchemaVersion: Integer);
begin
  inherited Create;
  FDatabase := Database;
  FSchemaVersion := SchemaVersion;
end;

function TSQLiteAuditStore.AuditStateUsable: Boolean;
begin
  // A custom trigger may change audit records during our own transaction.
  Result := (FSchemaVersion >= 4) and (FDatabase.Scalar('SELECT count(*) = 3 AND ' +
    'sum(name IN (''audit_state_insert'', ''audit_state_update'', ''audit_state_delete'')) = 3 ' +
    'FROM sqlite_master WHERE type = ''trigger''') = '1');
end;

function TSQLiteAuditStore.ReadAuditState(out State: TAuditState): Boolean;
var
  Statement: TSQLiteStatement;
begin
  State := Default(TAuditState);
  if FSchemaVersion < 4 then
    Exit(False);
  Statement := FDatabase.Prepare('SELECT record_count, head, pending, pending_command, interrupted, initialized ' +
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

procedure TSQLiteAuditStore.SaveAuditState(const State: TAuditState);
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('INSERT INTO audit_state VALUES (1, ?, ?, ?, ?, ?, ?)');
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

procedure TSQLiteAuditStore.ClearAuditState;
begin
  FDatabase.Execute('DELETE FROM audit_state WHERE id = 1');
end;

function TSQLiteAuditStore.ReadAuditTail(out Sequence: Int64; out Line, PreviousDigest: RawByteString): Boolean;
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('SELECT tail.sequence, tail.line, ' +
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

function TSQLiteAuditStore.HasAuditDigest(const Digest: string): Boolean;
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('SELECT 1 FROM audit_records WHERE substr(line, 1, 64) = ? LIMIT 1');
  try
    Statement.Bind(1, Digest);
    Result := Statement.Step;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteAuditStore.ReadAudit(Visit: TAuditLineVisitor);
var
  Statement: TSQLiteStatement;
  Sequence: Int64;
begin
  Sequence := 0;
  Statement := FDatabase.Prepare('SELECT sequence, line FROM audit_records ORDER BY sequence');
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

procedure TSQLiteAuditStore.ReadCommandHistory(Limit: Int64; Visit: TAuditLineVisitor);
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('SELECT payload FROM (' +
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

procedure TSQLiteAuditStore.AppendAudit(Sequence: Int64; const Line: RawByteString);
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('INSERT INTO audit_records (sequence, line) VALUES (?, ?)');
  try
    Statement.Bind(1, Sequence);
    Statement.Bind(2, Line);
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

end.
