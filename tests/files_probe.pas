program FilesProbe;

{$mode objfpc}{$H+}

uses Classes, SysUtils, ScuFiles, ScuPlatformPaths, ScuErrors
  {$IFDEF WINDOWS}, Windows, ScuPlatformPathsWindows,
  ScuPlatformFileSecurityWindows{$ENDIF};

{$IFDEF WINDOWS}
type
  TWideArguments = array[0..65535] of PWideChar;
  PWideArguments = ^TWideArguments;
function WideArguments(CommandLine: PWideChar; out Count: Integer): PWideArguments;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
{$ENDIF}

function Argument(Index: Integer): string;
{$IFDEF WINDOWS}
var Arguments: PWideArguments; Count: Integer;
begin
  Arguments := WideArguments(GetCommandLineW, Count);
  if Arguments = nil then RaiseSystemError('Could not parse probe arguments', GetLastError);
  try
    if Index < Count then Result := UTF8Encode(UnicodeString(Arguments^[Index])) else Result := '';
  finally
    LocalFree(HLOCAL(Arguments));
  end;
end;
{$ELSE}
begin
  Result := ParamStr(Index);
end;
{$ENDIF}

type
  TFailingStream = class(TMemoryStream)
    function Read(var Buffer; Count: LongInt): LongInt; override;
  end;
  TCancellingStream = class(TMemoryStream)
    function Read(var Buffer; Count: LongInt): LongInt; override;
  end;
  TPausingStream = class(TMemoryStream)
    function Read(var Buffer; Count: LongInt): LongInt; override;
  end;

function TFailingStream.Read(var Buffer; Count: LongInt): LongInt;
begin
  Result := 0;
  raise EReadError.Create('Injected source read failure');
end;

function TCancellingStream.Read(var Buffer; Count: LongInt): LongInt;
begin
  Result := 0;
  raise ECommandCancelled.Create('Injected cancellation');
end;

function TPausingStream.Read(var Buffer; Count: LongInt): LongInt;
var Reply: string;
begin
  WriteLn('ready'); Flush(Output);
  ReadLn(Reply);
  Result := inherited Read(Buffer, Count);
end;

function Options: TAtomicWriteOptions;
begin
  Result := [];
  if Pos('n', Argument(4)) <> 0 then Include(Result, awNoReplace);
  if Pos('s', Argument(4)) <> 0 then Include(Result, awSourceOutput);
end;

procedure StreamWrite(const Mode, Source, Destination: string);
var Stream: TMemoryStream; Data: RawByteString;
begin
  if Mode = 'fail' then Stream := TFailingStream.Create
  else if Mode = 'cancel' then Stream := TCancellingStream.Create
  else if Mode = 'pause' then Stream := TPausingStream.Create
  else Stream := TMemoryStream.Create;
  try
    Data := ReadBytes(Source, High(Int64));
    if Data <> '' then Stream.WriteBuffer(Data[1], Length(Data));
    Stream.Position := 0;
    if Mode = 'stream' then Stream.Position := StrToInt(Argument(5));
    AtomicWrite(Destination, Stream, Options);
  finally
    Stream.Free;
  end;
end;

{$IFDEF WINDOWS}
function MakeSymbolicLink(Link, Target: PWideChar; Flags: DWORD): Byte; stdcall;
  external 'kernel32.dll' name 'CreateSymbolicLinkW';

procedure WindowsLink(const Link, Target: string);
begin
  if (MakeSymbolicLink(PWideChar(NativeFilePath(Link)), PWideChar(NativeFilePath(Target)), 2) = 0) and
    (MakeSymbolicLink(PWideChar(NativeFilePath(Link)), PWideChar(NativeFilePath(Target)), 0) = 0) then
  begin
    WriteLn(StdErr, 'Symbolic links unavailable: ', SysErrorMessage(GetLastError));
    Halt(77);
  end;
  if (GetFileAttributesW(PWideChar(NativeFilePath(Link))) = INVALID_FILE_ATTRIBUTES) or
    ((GetFileAttributesW(PWideChar(NativeFilePath(Link))) and FILE_ATTRIBUTE_REPARSE_POINT) = 0) then
  begin
    WriteLn(StdErr, 'This runtime/filesystem did not create an observable reparse point.');
    Halt(77);
  end;
end;

procedure WindowsSharing(const Source, Destination: string; AllowDelete: Boolean);
var Handle: THandle; Sharing: DWORD; Original, Data: RawByteString; Count: DWORD;
begin
  Original := ReadBytes(Destination, High(Int64));
  Sharing := FILE_SHARE_READ or FILE_SHARE_WRITE;
  if AllowDelete then Sharing := Sharing or FILE_SHARE_DELETE;
  Handle := CreateFileW(PWideChar(NativeFilePath(Destination)), GENERIC_READ,
    Sharing, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseSystemError('Could not hold output open', GetLastError);
  try
    AtomicWrite(Destination, ReadBytes(Source, High(Int64)), Options);
    SetLength(Data, Length(Original));
    if not Windows.ReadFile(Handle, Data[1], Length(Data), Count, nil) then
      RaiseSystemError('Could not read held output', GetLastError);
    if (Count <> DWORD(Length(Original))) or (Data <> Original) then
      raise EScuError.Create('Replacement modified the old open file.');
  finally
    CloseHandle(Handle);
  end;
end;

procedure WindowsHoldOwner(const Path: string);
var Handle: THandle; Lock: TOverlapped; Reply: string;
begin
  Handle := CreateFileW(PWideChar(NativeFilePath(Path)), GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, OpenReparsePoint, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseSystemError('Could not hold stage owner', GetLastError);
  try
    FillChar(Lock, SizeOf(Lock), 0);
    if not LockFileEx(Handle, LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, Lock) then
      RaiseSystemError('Could not lock stage owner', GetLastError);
    WriteLn('ready'); Flush(Output); ReadLn(Reply);
  finally
    CloseHandle(Handle);
  end;
end;

procedure WindowsAccess(const Path: string);
var Handle: THandle; Info: array[0..4095] of Byte; Needed: DWORD; Index: Integer;
begin
  Handle := CreateFileW(PWideChar(NativeFilePath(Path)), FileReadControl,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseSystemError('Could not inspect test access', GetLastError);
  try
    if not GetKernelObjectSecurity(Handle, DACL_SECURITY_INFORMATION, PSecurityDescriptor(@Info),
      SizeOf(Info), @Needed) then RaiseSystemError('Could not inspect test access', GetLastError);
    // Emit the complete binary descriptor as hex for before/after comparisons.
    for Index := 0 to Integer(Needed) - 1 do Write(IntToHex(Info[Index], 2));
    WriteLn;
  finally
    CloseHandle(Handle);
  end;
end;
{$ENDIF}

var Mode, Source, Destination: string; Data: RawByteString; Index: Integer;
begin
  {$IFDEF WINDOWS}SetMultiByteConversionCodePage(CP_UTF8);{$ENDIF}
  InitializePlatformPaths;
  try
    Mode := Argument(1); Source := Argument(2); Destination := Argument(3);
    if Mode = 'write' then AtomicWrite(Destination, ReadBytes(Source, High(Int64)), Options)
    else if (Mode = 'stream') or (Mode = 'fail') or (Mode = 'cancel') or (Mode = 'pause') then
      StreamWrite(Mode, Source, Destination)
    else if Mode = 'read' then
    begin
      if Argument(4) = 'nofollow' then Data := ReadBytes(Source, StrToInt64(Destination), [rbNoFollow])
      else Data := ReadBytes(Source, StrToInt64(Destination));
      if Data <> '' then FileWrite(TTextRec(Output).Handle, Data[1], Length(Data));
    end
    else if Mode = 'sync_invalid' then SyncFile(THandle(-1), Source)
    else if Mode = 'sync_parent' then SyncParent(Source)
    else if Mode = 'regular' then WriteLn(Ord(RegularFileExists(Source)))
    else if Mode = 'sqlite' then WriteLn(Ord(IsSQLiteFile(Source)))
    else if Mode = 'companion' then WriteLn(Ord(IsSQLiteCompanion(Source)))
    else if Mode = 'cleanup' then CleanupStaleAtomicFiles(Source)
    else if Mode = 'stage' then WriteLn(MakeStagingDirectory(Source))
    else if Mode = 'temp' then WriteLn(MakeTempDirectory(Source))
    else if Mode = 'repeat' then
    begin
      Data := ReadBytes(Source, High(Int64));
      for Index := 1 to StrToInt(Argument(4)) do AtomicWrite(Destination, Data);
    end
    {$IFDEF WINDOWS}
    else if Mode = 'link' then WindowsLink(Source, Destination)
    else if Mode = 'shared' then WindowsSharing(Source, Destination, True)
    else if Mode = 'blocked' then WindowsSharing(Source, Destination, False)
    else if Mode = 'hold_owner' then WindowsHoldOwner(Source)
    else if Mode = 'access' then WindowsAccess(Source)
    {$ENDIF}
    else raise EScuError.Create('Unknown files probe mode: ' + Mode);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(1);
    end;
  end;
end.
