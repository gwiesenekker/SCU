unit ScuAudit;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, ScuLibrary, ScuSQLite;

type
  TAuditSnapshots = record
    Selected: TLibrarySnapshot;
    ResolvedDeck, FromDeckVersion, ToDeckVersion: string;
  end;

  TAuditLog = class
  private
    FPath: string;
    FHandle: THandle;
    FDatabase: TSQLiteLibrary;
    FCheckpoint: string;
    FFoundCheckpoint: Boolean;
    FHead, FPending, FPendingCommand: string;
    FRecords, FInterrupted: Int64;
    FInitialized: Boolean;
    function GetInterrupted: Int64;
    procedure Accept(const Line: RawByteString);
    procedure Scan(const Checkpoint: string);
    procedure Append(Event: TJSONObject);
  public
    constructor Create(const Path: string; AllowCreate, ReadOnly: Boolean;
      const Checkpoint: string = ''); overload;
    constructor Create(Database: TSQLiteLibrary; const Checkpoint: string = ''); overload;
    destructor Destroy; override;
    procedure ImportFile(const Path: string);
    procedure BeginCommand(const Command: string; ArgumentNames: TJSONArray;
      Arguments, Options: TStrings);
    procedure EndCommand(Success: Boolean; const Detail: string; const Snapshots: TAuditSnapshots;
      PendingSave: Boolean = False);
    procedure RecordBuild(const Expansion, Command, OutputPath: string; Success: Boolean; const Detail: string);
    property Head: string read FHead;
    property Records: Int64 read FRecords;
    property Interrupted: Int64 read GetInterrupted;
    property Initialized: Boolean read FInitialized;
  end;

implementation

uses
  SysUtils, BaseUnix, Linux, ScuCodec, ScuIO, ScuJSON;

const
  HashLength = 64;
  MaxRecordSize = 16 * 1024 * 1024;
  AuditDomain = 'SCU audit v1 ';

constructor TAuditLog.Create(const Path: string; AllowCreate, ReadOnly: Boolean;
  const Checkpoint: string);
var
  Flags: cint;
  Info: Stat;
  Created: Boolean;
begin
  inherited Create;
  FHandle := -1;
  FPath := Path;
  FHead := StringOfChar('0', HashLength);
  if (Checkpoint <> '') and not IsHexDigest(Checkpoint, HashLength) then
    raise EScuError.Create('Expected a lowercase SHA-256 audit head.');
  Created := AllowCreate and not RegularFileExists(Path);
  Flags := O_NOFOLLOW or O_NONBLOCK or O_CLOEXEC;
  if ReadOnly then
    Flags := Flags or O_RDONLY
  else
    Flags := Flags or O_RDWR or O_APPEND;
  if Created then
    Flags := Flags or O_CREAT or O_EXCL;
  FHandle := fpOpen(Path, Flags, &600);
  if FHandle < 0 then
    raise EScuError.CreateFmt('Could not open audit log %s: %s',
      [Path, SysErrorMessage(fpGetErrNo)]);
  if (fpFStat(FHandle, Info) <> 0) or not FPS_ISREG(Info.st_mode) then
    raise EScuError.Create('Expected a regular audit log file.');
  if Created then
    SyncParent(Path);
  Scan(Checkpoint);
end;

constructor TAuditLog.Create(Database: TSQLiteLibrary; const Checkpoint: string);
begin
  inherited Create;
  FHandle := -1;
  FDatabase := Database;
  FHead := StringOfChar('0', HashLength);
  FCheckpoint := Checkpoint;
  FFoundCheckpoint := Checkpoint = '';
  Database.ReadAudit(@Accept);
  if not FFoundCheckpoint then
    raise EScuError.Create('Saved audit head is absent from the verified chain.');
end;

procedure TAuditLog.ImportFile(const Path: string);
var
  Info: Stat;
begin
  if not Assigned(FDatabase) or (FRecords <> 0) then
    raise EScuError.Create('Audit import requires an empty SQLite library.');
  FHandle := fpOpen(Path, O_RDONLY or O_NOFOLLOW or O_NONBLOCK or O_CLOEXEC);
  if FHandle < 0 then
    RaiseLastOSError(fpGetErrNo);
  try
    if (fpFStat(FHandle, Info) <> 0) or not FPS_ISREG(Info.st_mode) then
      raise EScuError.Create('Expected a regular audit log file.');
    Scan('');
  finally
    fpClose(FHandle);
    FHandle := -1;
  end;
end;

destructor TAuditLog.Destroy;
begin
  if FHandle >= 0 then
    fpClose(FHandle);
  inherited Destroy;
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

  Event := ParseObject(Payload);
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
      if Field(Event, 'success', jtBoolean).AsBoolean and
        ((FPendingCommand = 'initialize_library') or (FPendingCommand = 'init') or
         (FPendingCommand = 'import_library')) then
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

procedure TAuditLog.Scan(const Checkpoint: string);
var
  Buffer: array[0..8191] of Char;
  Line, Part: RawByteString;
  Count: ssize_t;
  Index, Start: SizeInt;
  Found: Boolean;

  procedure AddPart(Offset, Size: SizeInt);
  begin
    if Length(Line) + Size > MaxRecordSize then
      raise EScuError.Create('Audit record exceeds the size limit.');
    SetString(Part, PChar(@Buffer[Offset]), Size);
    Line := Line + Part;
  end;

begin
  Found := Checkpoint = '';
  Line := '';
  repeat
    repeat
      Count := fpRead(FHandle, Buffer, SizeOf(Buffer));
    until (Count >= 0) or (fpGetErrNo <> ESysEINTR);
    if Count < 0 then
      RaiseLastOSError(fpGetErrNo);
    Start := 0;
    for Index := 0 to Count - 1 do
      if Buffer[Index] = #10 then
      begin
        AddPart(Start, Index - Start);
        Accept(Line);
          if Assigned(FDatabase) then
            FDatabase.AppendAudit(Line);
        Found := Found or (FHead = Checkpoint);
        Line := '';
        Start := Index + 1;
      end;
    if Start < Count then
      AddPart(Start, Count - Start);
  until Count = 0;
  if Line <> '' then
    raise EScuError.Create('Audit log ends with a partial record.');
  if not Found then
    raise EScuError.Create('Saved audit head is absent from the verified chain.');
end;

procedure TAuditLog.Append(Event: TJSONObject);
var
  Payload, Line: RawByteString;
  Stream: THandleStream;
begin
  Event.Add('utc', UtcTimestamp(UtcNow));
  Payload := Event.AsJSON;
  Line := AuditSHA256(AuditDomain + FHead + ' ' + Payload) + ' ' + Payload;
  if Length(Line) > MaxRecordSize then
    raise EScuError.Create('Audit record exceeds the size limit.');
  Accept(Line);
  if Assigned(FDatabase) then
  begin
    FDatabase.AppendAudit(Line);
    Exit;
  end;
  Line := Line + #10;
  Stream := THandleStream.Create(FHandle);
  try
    Stream.WriteBuffer(Line[1], Length(Line));
    SyncFile(FHandle, FPath);
  finally
    Stream.Free;
  end;
end;

procedure TAuditLog.BeginCommand(const Command: string; ArgumentNames: TJSONArray;
      Arguments, Options: TStrings);
var
  Event, Parameters, Named: TJSONObject;
  Args: TJSONArray;
  Index: Integer;
begin
  Event := TJSONObject.Create;
  try
    Event.Add('phase', 'begin');
    Event.Add('command', Command);
    Event.Add('uid', Int64(fpGetEUID));
    Args := TJSONArray.Create;
    Event.Add('arguments', Args);
    if Arguments.Count > 0 then
    begin
      Parameters := TJSONObject.Create;
      Event.Add('parameters', Parameters);
      for Index := 0 to Arguments.Count - 1 do
      begin
        Args.Add(Arguments[Index]);
        Parameters.Add(ArgumentNames.Strings[Index], Arguments[Index]);
      end;
    end;
    Named := TJSONObject.Create;
    Event.Add('options', Named);
    for Index := 0 to Options.Count - 1 do
      Named.Add(Options.Names[Index], Options.ValueFromIndex[Index]);
    Append(Event);
  finally
    Event.Free;
  end;
end;

procedure TAuditLog.EndCommand(Success: Boolean; const Detail: string; const Snapshots: TAuditSnapshots;
  PendingSave: Boolean);
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
    if PendingSave then
      Event.Add('pending_save', True);
    if Detail <> '' then
      Event.Add('detail', Detail);
    if Snapshots.ResolvedDeck <> '' then
      Event.Add('resolved_deck', Snapshots.ResolvedDeck);
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
