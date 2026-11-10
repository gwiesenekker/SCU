unit ScuIO;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  EScuError = class(Exception);
  TStopLockWait = function: Boolean;
  TCheckLockInterrupt = procedure;

  TLibraryLock = class
  private
    FHandle: THandle;
  public
    constructor Create(const Path: string; StopWaiting: TStopLockWait = nil;
      CheckInterrupt: TCheckLockInterrupt = nil);
    destructor Destroy; override;
  end;

function CanonicalFile(const Path: string): string;
function CanonicalDirectory(const Path: string): string;
function RegularFileExists(const Path: string): Boolean;
function ReadBytes(const Path: string; Limit: Int64): RawByteString;
procedure AtomicWrite(const Path: string; const Data: RawByteString; ReplaceExisting: Boolean = True;
  SourceOutput: Boolean = False); overload;
procedure AtomicWrite(const Path: string; Data: TStream; ReplaceExisting: Boolean = True;
  SourceOutput: Boolean = False); overload;
function MakeTempDirectory(const Prefix: string): string;
procedure SyncFile(Handle: THandle; const Path: string);
procedure SyncParent(const Path: string);
procedure RaiseSystemError(const Action: string; ErrorCode: Integer);
function UtcNow: TDateTime;
function UtcTimestamp(Value: TDateTime): string;
procedure WriteDiagnostic(const Message: string);

implementation

uses
  BaseUnix, Unix, DateUtils, InitC, Linux;

type
  EScuSystemError = class(EScuError);

procedure RaiseSystemError(const Action: string; ErrorCode: Integer);
begin
  raise EScuSystemError.CreateFmt('%s: %s', [Action, SysErrorMessage(ErrorCode)]);
end;

procedure WriteDiagnostic(const Message: string);
begin
  {$push}{$I-}
  WriteLn(StdErr, Message);
  if IOResult = 0 then
  begin
    Flush(StdErr);
    IOResult;
  end;
  {$pop}
end;

function realpath(Path, Resolved: PChar): PChar; cdecl; external 'c';
function mkstemp(Template: PChar): LongInt; cdecl; external 'c';
function mkdtemp(Template: PChar): PChar; cdecl; external 'c';
function fchmod(Handle: cint; Mode: mode_t): cint; cdecl; external 'c';

function MakeTempDirectory(const Prefix: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ExpandFileName(GetTempDir(False))) + Prefix + '-XXXXXX';
  UniqueString(Result);
  if mkdtemp(PChar(Result)) = nil then
    RaiseSystemError('Could not create temporary directory "' + Result + '"', cerrno);
end;

function CanonicalFile(const Path: string): string;
var
  FullPath, Parent: string;
begin
  if (Path = '') or (Path[Length(Path)] = DirectorySeparator) then
    raise EScuError.Create('Expected a file path.');
  FullPath := ExpandFileName(Path);
  Parent := ExtractFileDir(FullPath);
  Result := IncludeTrailingPathDelimiter(CanonicalDirectory(Parent)) + ExtractFileName(FullPath);
end;

function CanonicalDirectory(const Path: string): string;
var
  Resolved: array[0..4095] of Char;
begin
  if realpath(PChar(Path), @Resolved[0]) = nil then
    raise EScuError.CreateFmt('Could not resolve directory %s: %s', [Path, SysErrorMessage(cerrno)]);
  Result := StrPas(@Resolved[0]);
end;

constructor TLibraryLock.Create(const Path: string; StopWaiting: TStopLockWait;
  CheckInterrupt: TCheckLockInterrupt);
var
  Flags, Error: cint;
  Info: Stat;
begin
  inherited Create;
  FHandle := fpOpen(Path, O_RDWR or O_CREAT or O_NOFOLLOW or O_CLOEXEC, &600);
  if FHandle < 0 then
    RaiseSystemError('Could not open lock file "' + Path + '"', fpGetErrNo);
  if fpFStat(FHandle, Info) <> 0 then
    RaiseSystemError('Could not inspect lock file "' + Path + '"', fpGetErrNo);
  if not FPS_ISREG(Info.st_mode) then
    raise EScuError.CreateFmt('Expected a regular lock file at "%s".', [Path]);
  Flags := LOCK_EX;
  if Assigned(StopWaiting) or Assigned(CheckInterrupt) then
    Flags := Flags or LOCK_NB;
  repeat
    if Assigned(CheckInterrupt) then
      CheckInterrupt();
    if fpFlock(FHandle, Flags) = 0 then
      Break;
    Error := fpGetErrNo;
    if Error = ESysEINTR then
      Continue;
    if (Flags = LOCK_EX) or (Error <> ESysEWOULDBLOCK) then
      RaiseSystemError('Could not acquire lock "' + Path + '"', Error);
    if Assigned(StopWaiting) and StopWaiting() then
      raise EScuError.CreateFmt('Library lock %s is busy during shutdown.', [Path]);
    Sleep(20);
  until False;
  if Assigned(CheckInterrupt) then
    CheckInterrupt();
end;

destructor TLibraryLock.Destroy;
begin
  if FHandle >= 0 then
    fpClose(FHandle);
  inherited Destroy;
end;

function RegularFileExists(const Path: string): Boolean;
var
  Info: Stat;
  Error: cint;
begin
  if fpLStat(Path, Info) = 0 then
  begin
    if not FPS_ISREG(Info.st_mode) then
      raise EScuError.CreateFmt('Expected a regular file: %s', [Path]);
    Exit(True);
  end;
  Error := fpGetErrNo;
  if Error <> ESysENOENT then
    RaiseSystemError('Could not inspect "' + Path + '"', Error);
  Result := False;
end;

function ReadBytes(const Path: string; Limit: Int64): RawByteString;
var
  Handle: THandle;
  Stream: THandleStream;
  Info: Stat;
begin
  Handle := fpOpen(Path, O_RDONLY or O_NONBLOCK);
  if Handle < 0 then
    raise EScuError.CreateFmt('Could not open %s: %s', [Path, SysErrorMessage(fpGetErrNo)]);
  try
    if fpFStat(Handle, Info) <> 0 then
      RaiseSystemError('Could not inspect opened file "' + Path + '"', fpGetErrNo);
    if not FPS_ISREG(Info.st_mode) then
      raise EScuError.CreateFmt('Expected a regular file: %s', [Path]);
    if (Info.st_size < 0) or (Info.st_size > Limit) then
      raise EScuError.CreateFmt('File exceeds the %d-byte limit: %s', [Limit, Path]);
    SetLength(Result, Info.st_size);
    if Result <> '' then
    begin
      Stream := THandleStream.Create(Handle);
      try
        try
          Stream.ReadBuffer(Result[1], Length(Result));
        except
          on E: EStreamError do
            raise EScuError.CreateFmt('Could not read "%s": %s', [Path, E.Message]);
        end;
      finally
        Stream.Free;
      end;
    end;
  finally
    fpClose(Handle);
  end;
end;

procedure SyncFile(Handle: THandle; const Path: string);
begin
  if fpFsync(Handle) <> 0 then
    RaiseSystemError('Could not sync "' + Path + '"', fpGetErrNo);
end;

procedure SyncParent(const Path: string);
var
  Handle: THandle;
  Parent: string;
begin
  Parent := ExtractFileDir(Path);
  Handle := fpOpen(Parent, O_RDONLY or O_DIRECTORY);
  if Handle < 0 then
    RaiseSystemError('Could not open parent directory "' + Parent + '" for "' + Path + '"', fpGetErrNo);
  try
    SyncFile(Handle, Parent);
  finally
    fpClose(Handle);
  end;
end;

procedure AtomicWrite(const Path: string; Data: TStream; ReplaceExisting, SourceOutput: Boolean);
var
  TempPath: string;
  Handle: THandle;
  Stream: THandleStream;
  Mode, Mask: mode_t;
  Info: Stat;
begin
  TempPath := IncludeTrailingPathDelimiter(ExtractFileDir(Path)) + '.scu-XXXXXX';
  UniqueString(TempPath);
  Handle := mkstemp(PChar(TempPath));
  if Handle < 0 then
    raise EScuError.CreateFmt('Could not create temporary file in %s: %s',
      [ExtractFileDir(Path), SysErrorMessage(cerrno)]);
  try
    try
      Stream := THandleStream.Create(Handle);
      try
        try
          if Data.Size > Data.Position then
            Stream.CopyFrom(Data, Data.Size - Data.Position);
        except
          on E: EStreamError do
            raise EScuError.CreateFmt('Could not write "%s": %s', [Path, E.Message]);
        end;
        if SourceOutput then
        begin
          if (fpLStat(Path, Info) = 0) and FPS_ISREG(Info.st_mode) then
            Mode := Info.st_mode and &777
          else
          begin
            Mask := fpUmask(0);
            fpUmask(Mask);
            Mode := &666 and not Mask;
          end;
          if fchmod(Handle, Mode) <> 0 then
            RaiseSystemError('Could not set permissions for "' + Path + '"', cerrno);
        end;
        SyncFile(Handle, TempPath);
      finally
        Stream.Free;
      end;
    finally
      fpClose(Handle);
    end;
    if ReplaceExisting then
    begin
      if fpRename(TempPath, Path) <> 0 then
        raise EScuError.CreateFmt('Could not replace %s: %s', [Path, SysErrorMessage(fpGetErrNo)]);
      TempPath := '';
    end
    else if fpLink(TempPath, Path) <> 0 then
      raise EScuError.CreateFmt('Could not create %s: %s', [Path, SysErrorMessage(fpGetErrNo)]);
    try
      SyncParent(Path);
    except
      on E: EScuSystemError do
        raise EScuError.CreateFmt('%s was replaced but its directory could not be synced: %s',
          [Path, E.Message]);
    end;
  finally
    if TempPath <> '' then
      fpUnlink(TempPath);
  end;
end;

procedure AtomicWrite(const Path: string; const Data: RawByteString; ReplaceExisting, SourceOutput: Boolean);
var
  Stream: TRawByteStringStream;
begin
  Stream := TRawByteStringStream.Create(Data);
  try
    AtomicWrite(Path, Stream, ReplaceExisting, SourceOutput);
  finally
    Stream.Free;
  end;
end;

function UtcNow: TDateTime;
var
  Time: TTimeVal;
begin
  if fpGetTimeOfDay(@Time, nil) <> 0 then
    RaiseSystemError('Could not read the system clock', fpGetErrNo);
  Result := UnixToDateTime(Time.tv_sec) + Time.tv_usec / 86400000000.0;
end;

function UtcTimestamp(Value: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz"Z"', Value);
end;

end.
