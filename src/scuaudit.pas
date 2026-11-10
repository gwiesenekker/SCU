unit ScuAudit;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, FPJSON, FGL, ScuLibrary, ScuSQLite;

type
  TAuditSnapshots = record
    Selected: TLibrarySnapshot;
    ResolvedDeck, FromDeckVersion, ToDeckVersion: string;
  end;

  TAuditRevisionDigests = specialize TFPGMap<Integer, string>;

  TAuditFileStamp = record
    Device, Inode, Size, Modified, ModifiedNanos, Changed, ChangedNanos: QWord;
  end;

  TAuditSessionCache = record
  private
    Path, Head, Pending, PendingCommand: string;
    Records, Interrupted: Int64;
    Initialized: Boolean;
    Files: array[0..2] of TAuditFileStamp;
  end;
  PAuditSessionCache = ^TAuditSessionCache;

  TAuditLog = class
  private
    FHandle: THandle;
    FDatabase: TSQLiteLibrary;
    FCheckpoint: string;
    FFoundCheckpoint: Boolean;
    FHead, FPending, FPendingCommand: string;
    FRecords, FInterrupted, FRepairedBytes: Int64;
    FInitialized: Boolean;
    FContents: TAuditRevisionDigests;
    FHeaderDigest: string;
    FRevisionCount: Integer;
    FCache: PAuditSessionCache;
    FStoragePath, FCacheVersion: string;
    FLastFileStamp: TAuditFileStamp;
    FCacheable: Boolean;
    function GetInterrupted: Int64;
    function Resume(const Checkpoint: string): Boolean;
    procedure Accept(const Line: RawByteString);
    procedure AcceptContents(Event: TJSONObject);
    procedure Scan(const Checkpoint: string; RepairTail: Boolean = False);
    procedure Append(Event: TJSONObject);
  public
    constructor Create(const Path: string; AllowCreate, ReadOnly: Boolean;
      const Checkpoint: string = ''; RepairTail: Boolean = False;
      Cache: PAuditSessionCache = nil); overload;
    constructor Create(Database: TSQLiteLibrary; const Checkpoint: string = '';
      VerifyData: Boolean = False; Cache: PAuditSessionCache = nil); overload;
    destructor Destroy; override;
    procedure Remember;
    procedure ImportFile(const Path: string);
    procedure BeginCommand(const Command: string; ArgumentNames: TJSONArray;
      Arguments, Options: TStrings);
    procedure EndCommand(Success: Boolean; const Detail: string; const Snapshots: TAuditSnapshots;
      PendingSave: Boolean = False; Contents: TJSONObject = nil);
    procedure VerifyContents(LibraryFile: TDeckLibrary);
    procedure RecordBuild(const Expansion, Command, OutputPath: string; Success: Boolean; const Detail: string);
    property Head: string read FHead;
    property Records: Int64 read FRecords;
    property Interrupted: Int64 read GetInterrupted;
    property Initialized: Boolean read FInitialized;
    property RepairedBytes: Int64 read FRepairedBytes;
    property SavedHeaderDigest: string read FHeaderDigest;
  end;

implementation

uses
  SysUtils, BaseUnix, Linux, ScuCodec, ScuIO, ScuJSON;

const
  HashLength = 64;
  MaxRecordSize = 16 * 1024 * 1024;
  AuditDomain = 'SCU audit v1 ';

function FileStamp(const Info: Stat): TAuditFileStamp;
begin
  Result.Device := Info.st_dev;
  Result.Inode := Info.st_ino;
  Result.Size := Info.st_size;
  Result.Modified := Info.st_mtime;
  Result.ModifiedNanos := Info.st_mtime_nsec;
  Result.Changed := Info.st_ctime;
  Result.ChangedNanos := Info.st_ctime_nsec;
end;

function ReadFileStamp(const Path: string; out Stamp: TAuditFileStamp; Optional: Boolean): Boolean;
var
  Info: Stat;
begin
  Stamp := Default(TAuditFileStamp);
  if fpLStat(Path, Info) <> 0 then
    Exit(Optional and (fpGetErrNo = ESysENOENT));
  Result := FPS_ISREG(Info.st_mode);
  if Result then
    Stamp := FileStamp(Info);
end;

function ReadStorageStamp(const Path: string; SQLite: Boolean; var State: TAuditSessionCache): Boolean;
begin
  State.Files[1] := Default(TAuditFileStamp);
  State.Files[2] := Default(TAuditFileStamp);
  Result := ReadFileStamp(Path, State.Files[0], False) and
    (not SQLite or (ReadFileStamp(Path + '-wal', State.Files[1], True) and
    ReadFileStamp(Path + '-journal', State.Files[2], True)));
end;

function TAuditLog.Resume(const Checkpoint: string): Boolean;
var
  Current: TAuditSessionCache;
begin
  Result := FCacheable and (FCache^.Path = FStoragePath) and
    ((Checkpoint = '') or (Checkpoint = FCache^.Head)) and
    ReadStorageStamp(FStoragePath, Assigned(FDatabase), Current) and
    CompareMem(@Current.Files, @FCache^.Files, SizeOf(Current.Files)) and
    (Assigned(FDatabase) or CompareMem(@Current.Files[0], @FLastFileStamp, SizeOf(FLastFileStamp)));
  if not Result then
    Exit;
  FHead := FCache^.Head;
  FPending := FCache^.Pending;
  FPendingCommand := FCache^.PendingCommand;
  FRecords := FCache^.Records;
  FInterrupted := FCache^.Interrupted;
  FInitialized := FCache^.Initialized;
end;

procedure TAuditLog.Remember;
var
  Current: TAuditSessionCache;
begin
  // The caller holds the library lock and has committed the audit outcome.
  if not FCacheable or not ReadStorageStamp(FStoragePath, Assigned(FDatabase), Current) then
    Exit;
  if Assigned(FDatabase) then
  begin
    if (Current.Files[0].Device <> FLastFileStamp.Device) or
      (Current.Files[0].Inode <> FLastFileStamp.Inode) or
      (FDatabase.AuditCacheVersion <> FCacheVersion) then
      Exit;
  end
  else if not CompareMem(@Current.Files[0], @FLastFileStamp, SizeOf(FLastFileStamp)) then
    Exit;
  Current.Path := FStoragePath;
  Current.Head := FHead;
  Current.Pending := FPending;
  Current.PendingCommand := FPendingCommand;
  Current.Records := FRecords;
  Current.Interrupted := FInterrupted;
  Current.Initialized := FInitialized;
  FCache^ := Current;
end;

constructor TAuditLog.Create(const Path: string; AllowCreate, ReadOnly: Boolean;
  const Checkpoint: string; RepairTail: Boolean; Cache: PAuditSessionCache);
var
  Flags: cint;
  Info: Stat;
  Created: Boolean;
begin
  inherited Create;
  FHandle := -1;
  FStoragePath := Path;
  FHead := StringOfChar('0', HashLength);
  if ReadOnly then
  begin
    FContents := TAuditRevisionDigests.Create;
    FContents.Sorted := True;
  end;
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
  if not ReadOnly and not RepairTail then
    FCache := Cache;
  FCacheable := Assigned(FCache);
  FLastFileStamp := FileStamp(Info);
  if not Resume(Checkpoint) then
    Scan(Checkpoint, RepairTail);
end;

constructor TAuditLog.Create(Database: TSQLiteLibrary; const Checkpoint: string;
  VerifyData: Boolean; Cache: PAuditSessionCache);
begin
  inherited Create;
  FHandle := -1;
  FDatabase := Database;
  FStoragePath := Database.Path;
  FHead := StringOfChar('0', HashLength);
  if VerifyData then
  begin
    FContents := TAuditRevisionDigests.Create;
    FContents.Sorted := True;
  end
  else
    FCache := Cache;
  if Assigned(FCache) then
  begin
    FCacheVersion := Database.AuditCacheVersion;
    FCacheable := (FCacheVersion <> '') and ReadFileStamp(FStoragePath, FLastFileStamp, False);
  end;
  if Resume(Checkpoint) then
    Exit;
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
  FContents.Free;
  if FHandle >= 0 then
    fpClose(FHandle);
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
    if LibraryFile.RevisionDigest(Sequence) <> FContents.Data[Index] then
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
      if Field(Event, 'success', jtBoolean).AsBoolean then
        AcceptContents(Event);
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

procedure TAuditLog.Scan(const Checkpoint: string; RepairTail: Boolean);
var
  Buffer: array[0..8191] of Char;
  Line, Part: RawByteString;
  Count: ssize_t;
  Index, Start: SizeInt;
  Offset: Int64;
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
  Offset := 0;
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
    Inc(Offset, Count);
  until Count = 0;
  if not Found then
    raise EScuError.Create('Saved audit head is absent from the verified chain.');
  if Line <> '' then
  begin
    Dec(Offset, Length(Line));
    if not RepairTail then
      raise EScuError.CreateFmt('Audit log ends with a partial record at byte offset %d. Run repair_audit.',
        [Offset]);
    if fpFTruncate(FHandle, Offset) <> 0 then
      RaiseLastOSError(fpGetErrNo);
    SyncFile(FHandle, FStoragePath);
    FRepairedBytes := Length(Line);
  end;
end;

procedure TAuditLog.Append(Event: TJSONObject);
var
  Payload, Line: RawByteString;
  Stream: THandleStream;
  Info: Stat;
  Current: TAuditFileStamp;
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
  if FCacheable then
  begin
    FCacheable := fpFStat(FHandle, Info) = 0;
    if FCacheable then
    begin
      Current := FileStamp(Info);
      FCacheable := CompareMem(@Current, @FLastFileStamp, SizeOf(Current));
    end;
  end;
  Line := Line + #10;
  Stream := THandleStream.Create(FHandle);
  try
    Stream.WriteBuffer(Line[1], Length(Line));
    SyncFile(FHandle, FStoragePath);
    if FCacheable then
    begin
      FCacheable := (fpFStat(FHandle, Info) = 0) and
        (QWord(Info.st_size) = FLastFileStamp.Size + QWord(Length(Line)));
      if FCacheable then
        FLastFileStamp := FileStamp(Info);
    end;
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
  PendingSave: Boolean; Contents: TJSONObject);
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
    if Assigned(Contents) then
      Event.Add('saved_contents', Contents.Clone);
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
