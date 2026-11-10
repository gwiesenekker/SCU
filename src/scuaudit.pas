unit ScuAudit;

{$mode objfpc}{$H+}

interface

uses
  FPJSON, FGL, ScuCommand, ScuLibrary, ScuSQLite, ScuSQLiteAudit;

type
  TAuditSnapshots = record
    Selected: TLibrarySnapshot;
    ResolvedDeck, FromDeckVersion, ToDeckVersion: string;
    OutputPath, OutputDirectory: string;
  end;

  TAuditRevisionDigests = specialize TFPGMap<Integer, string>;

  TAuditLog = class
  private
    FDatabase: TSQLiteLibrary;
    FCheckpoint: string;
    FFoundCheckpoint: Boolean;
    FHead, FPending, FPendingCommand: string;
    FRecords, FInterrupted: Int64;
    FInitialized: Boolean;
    FContents: TAuditRevisionDigests;
    FHeaderDigest: string;
    FRevisionCount: Integer;
    FUseState: Boolean;
    function GetInterrupted: Int64;
    function CurrentState: TAuditState;
    function Resume(const State: TAuditState; const Checkpoint: string): Boolean;
    procedure Accept(const Line: RawByteString);
    procedure AcceptContents(Event: TJSONObject);
    procedure Append(Event: TJSONObject);
    procedure Load(Database: TSQLiteLibrary; const Checkpoint: string; VerifyData: Boolean);
  public
    constructor Open(Database: TSQLiteLibrary; const Checkpoint: string = '');
    constructor Verify(Database: TSQLiteLibrary; const Checkpoint: string = '');
    destructor Destroy; override;
    procedure BeginCommand(Command: TScuCommand);
    procedure EndCommand(Success: Boolean; const Detail: string; const Snapshots: TAuditSnapshots;
      PendingSave: Boolean = False; Contents: TJSONObject = nil; Cancelled: Boolean = False);
    procedure VerifyContents(LibraryFile: TDeckLibrary);
    procedure RecordBuild(const Expansion, Command, OutputPath: string; Success: Boolean; const Detail: string);
    property Head: string read FHead;
    property Records: Int64 read FRecords;
    property Interrupted: Int64 read GetInterrupted;
    property Initialized: Boolean read FInitialized;
    property SavedHeaderDigest: string read FHeaderDigest;
  end;

function FormatAuditCommand(const Payload: RawByteString): string;

implementation

uses
  SysUtils, BaseUnix, ScuCodec, ScuClock, ScuErrors, ScuJSON;

const
  HashLength = 64;
  MaxRecordSize = 16 * 1024 * 1024;
  AuditDomain = 'SCU audit v1 ';

function FormatAuditCommand(const Payload: RawByteString): string;
var
  Event: TJSONObject;

  function ArgumentValue(const Value: string): string;
  var
    Character: Char;
  begin
    if Value = '' then
      Exit('""');
    for Character in Value do
      if not (Character in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '/']) then
        Exit('"' + StringToJSONString(Value) + '"');
    Result := Value;
  end;

  procedure AddParameters(const Name: string);
  var
    Fields: TJSONObject;
    Index: Integer;
  begin
    if not Assigned(Event.Find(Name)) then
      Exit;
    Fields := TJSONObject(Field(Event, Name, jtObject));
    for Index := 0 to Fields.Count - 1 do
      Result := Result + ' ' + Fields.Names[Index] + '=' + ArgumentValue(Fields.Items[Index].AsString);
  end;

begin
  Event := ParseObject(Payload, 'Audit history entry');
  try
    Result := Field(Event, 'command', jtString).AsString;
    AddParameters('parameters');
    AddParameters('options');
  finally
    Event.Free;
  end;
end;

function TAuditLog.CurrentState: TAuditState;
begin
  Result.RecordCount := FRecords;
  Result.Head := FHead;
  Result.Pending := FPending;
  Result.PendingCommand := FPendingCommand;
  Result.Interrupted := FInterrupted;
  Result.Initialized := FInitialized;
end;

function TAuditLog.Resume(const State: TAuditState; const Checkpoint: string): Boolean;
var
  Sequence: Int64;
  Tail, PreviousDigest: RawByteString;
begin
  Result := False;
  if not FDatabase.Audit.ReadAuditTail(Sequence, Tail, PreviousDigest) or
    (Sequence <> State.RecordCount) or (Length(Tail) <= HashLength + 1) or
    (Tail[HashLength + 1] <> ' ') or (Copy(Tail, 1, HashLength) <> State.Head) then
    Exit;
  if Sequence = 1 then
    PreviousDigest := FHead;
  if not IsHexDigest(PreviousDigest, HashLength) or
    (State.Head <> AuditSHA256(AuditDomain + PreviousDigest + ' ' + Copy(Tail, HashLength + 2, MaxInt))) then
    Exit;
  if (Checkpoint <> '') and (Checkpoint <> State.Head) and not FDatabase.Audit.HasAuditDigest(Checkpoint) then
    raise EScuError.Create('Saved audit head is absent from the verified chain.');
  FHead := State.Head;
  FPending := State.Pending;
  FPendingCommand := State.PendingCommand;
  FRecords := State.RecordCount;
  FInterrupted := State.Interrupted;
  FInitialized := State.Initialized;
  Result := True;
end;

constructor TAuditLog.Open(Database: TSQLiteLibrary; const Checkpoint: string);
begin
  inherited Create;
  Load(Database, Checkpoint, False);
end;

constructor TAuditLog.Verify(Database: TSQLiteLibrary; const Checkpoint: string);
begin
  inherited Create;
  Load(Database, Checkpoint, True);
end;

procedure TAuditLog.Load(Database: TSQLiteLibrary; const Checkpoint: string; VerifyData: Boolean);
var
  State: TAuditState;
  HasState: Boolean;
begin
  FDatabase := Database;
  FHead := StringOfChar('0', HashLength);
  if VerifyData then
  begin
    FContents := TAuditRevisionDigests.Create;
    FContents.Sorted := True;
  end;
  FUseState := not VerifyData and Database.Audit.AuditStateUsable;
  HasState := Database.Audit.ReadAuditState(State);
  if FUseState and HasState and Resume(State, Checkpoint) then
    Exit;
  FCheckpoint := Checkpoint;
  FFoundCheckpoint := Checkpoint = '';
  Database.Audit.ReadAudit(@Accept);
  if not FFoundCheckpoint then
    raise EScuError.Create('Saved audit head is absent from the verified chain.');
  if HasState and ((State.RecordCount <> FRecords) or (State.Head <> FHead) or
    (State.Pending <> FPending) or (State.PendingCommand <> FPendingCommand) or
    (State.Interrupted <> FInterrupted) or (State.Initialized <> FInitialized)) then
    raise EScuError.Create('Stored audit state does not match the audit log.');
end;

destructor TAuditLog.Destroy;
begin
  FContents.Free;
  inherited Destroy;
end;

procedure TAuditLog.AcceptContents(Event: TJSONObject);
var
  Contents: TJSONObject;
  Digests: TJSONArray;
  First, Count: Int64;
  Index, Slot: Integer;
  Digest: string;
begin
  if not Assigned(FContents) or not Assigned(Event.Find('saved_contents')) then
    Exit;
  Contents := TJSONObject(Field(Event, 'saved_contents', jtObject));
  FHeaderDigest := Field(Contents, 'header_sha256', jtString).AsString;
  First := IntegerField(Contents, 'first_revision');
  Count := IntegerField(Contents, 'revision_count');
  Digests := TJSONArray(Field(Contents, 'revision_sha256', jtArray));
  if not IsHexDigest(FHeaderDigest, HashLength) or (Count < FRevisionCount) or
    (Count > High(Integer)) or (First < 1) or (First > Count + 1) or
    (Digests.Count <> Count - First + 1) then
    raise EScuError.Create('Invalid saved contents in audit log.');
  FRevisionCount := Count;
  for Index := 0 to Digests.Count - 1 do
  begin
    Digest := Digests.Strings[Index];
    if not IsHexDigest(Digest, HashLength) then
      raise EScuError.Create('Invalid saved revision digest in audit log.');
    if FContents.Find(First + Index, Slot) then
      FContents.Data[Slot] := Digest
    else
      FContents.Add(First + Index, Digest);
  end;
end;

procedure TAuditLog.VerifyContents(LibraryFile: TDeckLibrary);
var
  Index, Sequence: Integer;
begin
  if FHeaderDigest = '' then
    Exit;
  if (LibraryFile.Revision <> FRevisionCount) or (LibraryFile.HeaderDigest <> FHeaderDigest) then
    raise EScuError.Create('Saved library header or revision count does not match the audit log.');
  for Index := 0 to FContents.Count - 1 do
  begin
    Sequence := FContents.Keys[Index];
    if LibraryFile.RevisionDigest(Sequence, FDatabase) <> FContents.Data[Index] then
      raise EScuError.CreateFmt('Library revision %d does not match the audit log.', [Sequence]);
  end;
end;

function TAuditLog.GetInterrupted: Int64;
begin
  Result := FInterrupted + Ord(FPending <> '');
end;

procedure TAuditLog.Accept(const Line: RawByteString);
var
  Digest, Payload, Phase: RawByteString;
  Event: TJSONObject;
begin
  Inc(FRecords);
  if (Length(Line) <= HashLength + 1) or (Line[HashLength + 1] <> ' ') then
    raise EScuError.CreateFmt('Invalid audit record %d.', [FRecords]);
  Digest := Copy(Line, 1, HashLength);
  Payload := Copy(Line, HashLength + 2, MaxInt);
  if Digest <> AuditSHA256(AuditDomain + FHead + ' ' + Payload) then
    raise EScuError.CreateFmt('Audit digest mismatch at record %d.', [FRecords]);

  Event := ParseObject(Payload, Format('Audit record %d in "%s"', [FRecords, FDatabase.Path]));
  try
    Phase := Field(Event, 'phase', jtString).AsString;
    if Phase = 'begin' then
    begin
      if FPending <> '' then
        Inc(FInterrupted);
      FPending := Digest;
      FPendingCommand := Field(Event, 'command', jtString).AsString;
    end
    else if (Phase = 'end') and (FPending <> '') and
      (Field(Event, 'begin', jtString).AsString = FPending) then
    begin
      if Field(Event, 'success', jtBoolean).AsBoolean then
        AcceptContents(Event);
      if Field(Event, 'success', jtBoolean).AsBoolean and
        ((FPendingCommand = 'initialize_library') or (FPendingCommand = 'init') or
         (FPendingCommand = 'import_library') or (FPendingCommand = 'recover_library')) then
        FInitialized := True;
      FPending := '';
      FPendingCommand := '';
    end
    else if Phase = 'build' then
    begin
      if not IsHexDigest(Field(Event, 'expansion', jtString).AsString, HashLength) then
        raise EScuError.CreateFmt('Invalid build record %d.', [FRecords]);
      Field(Event, 'build_command', jtString);
      Field(Event, 'output_path', jtString);
      Field(Event, 'success', jtBoolean);
    end
    else
      raise EScuError.CreateFmt('Unexpected audit phase at record %d.', [FRecords]);
  finally
    Event.Free;
  end;
  FHead := Digest;
  FFoundCheckpoint := FFoundCheckpoint or (Digest = FCheckpoint);
end;

procedure TAuditLog.Append(Event: TJSONObject);
var
  Payload, Line: RawByteString;
begin
  Event.Add('utc', UtcTimestamp(UtcNow));
  Payload := Event.AsJSON;
  Line := AuditSHA256(AuditDomain + FHead + ' ' + Payload) + ' ' + Payload;
  if Length(Line) > MaxRecordSize then
    raise EScuError.Create('Audit record exceeds the size limit.');
  Accept(Line);
  FDatabase.Audit.AppendAudit(FRecords, Line);
  if FUseState then
    FDatabase.Audit.SaveAuditState(CurrentState)
  else
    FDatabase.Audit.ClearAuditState;
end;

procedure TAuditLog.BeginCommand(Command: TScuCommand);
var
  Event, Parameters, Named: TJSONObject;
  Args, Provided: TJSONArray;
  Index: Integer;
  Argument: TScuArgument;
begin
  Event := TJSONObject.Create;
  try
    Event.Add('phase', 'begin');
    Event.Add('command', Command.Name);
    Event.Add('uid', Int64(fpGetEUID));
    Args := TJSONArray.Create;
    Event.Add('arguments', Args);
    if Command.ArgumentCount > 0 then
    begin
      Parameters := TJSONObject.Create;
      Event.Add('parameters', Parameters);
      Provided := TJSONArray.Create;
      Event.Add('provided_arguments', Provided);
      for Index := 0 to Command.ArgumentCount - 1 do
      begin
        Argument := Command.Arguments[Index];
        Args.Add(Argument.Value);
        Parameters.Add(Argument.Name, Argument.Value);
        if Argument.Provided then
          Provided.Add(Argument.Name);
      end;
    end;
    Named := TJSONObject.Create;
    Event.Add('options', Named);
    for Index := 0 to Command.OptionCount - 1 do
      Named.Add(Command.OptionNames[Index], Command.OptionValues[Index]);
    Append(Event);
  finally
    Event.Free;
  end;
end;

procedure TAuditLog.EndCommand(Success: Boolean; const Detail: string; const Snapshots: TAuditSnapshots;
  PendingSave: Boolean; Contents: TJSONObject; Cancelled: Boolean);
var
  Event: TJSONObject;

  procedure AddSnapshot(const Name: string; const Snapshot: TLibrarySnapshot);
  var
    Resolved: TJSONObject;
  begin
    if Snapshot.Version = '' then
      Exit;
    Resolved := TJSONObject.Create;
    Event.Add(Name, Resolved);
    Resolved.Add('version', Snapshot.Version);
    Resolved.Add('library_revision', Snapshot.LibraryRevision);
  end;

begin
  Event := TJSONObject.Create;
  try
    Event.Add('phase', 'end');
    Event.Add('begin', FPending);
    Event.Add('success', Success);
    if Cancelled then
      Event.Add('cancelled', True);
    if PendingSave then
      Event.Add('pending_save', True);
    if Assigned(Contents) then
      Event.Add('saved_contents', Contents.Clone);
    if Detail <> '' then
      Event.Add('detail', Detail);
    if Snapshots.ResolvedDeck <> '' then
      Event.Add('resolved_deck', Snapshots.ResolvedDeck);
    if Snapshots.OutputPath <> '' then
      Event.Add('output_path', Snapshots.OutputPath);
    if Snapshots.OutputDirectory <> '' then
      Event.Add('output_directory', Snapshots.OutputDirectory);
    AddSnapshot('snapshot', Snapshots.Selected);
    if Snapshots.FromDeckVersion <> '' then
      Event.Add('from_deck_version', Snapshots.FromDeckVersion);
    if Snapshots.ToDeckVersion <> '' then
      Event.Add('to_deck_version', Snapshots.ToDeckVersion);
    Append(Event);
  finally
    Event.Free;
  end;
end;

procedure TAuditLog.RecordBuild(const Expansion, Command, OutputPath: string; Success: Boolean; const Detail: string);
var
  Event: TJSONObject;
begin
  Event := TJSONObject.Create;
  try
    Event.Add('phase', 'build');
    Event.Add('expansion', Expansion);
    Event.Add('build_command', Command);
    Event.Add('output_path', OutputPath);
    Event.Add('uid', Int64(fpGetEUID));
    Event.Add('success', Success);
    if Detail <> '' then
      Event.Add('detail', Detail);
    Append(Event);
  finally
    Event.Free;
  end;
end;

end.
