unit ScuPlatformBuildLeaseWindows;
{$mode objfpc}{$H+}
interface
uses Windows, ScuLockTypes, ScuPlatformLockInterruptWindows;
const WindowsBuildLeaseVariable = 'SCU_BUILD_OUTPUT_LEASE';
type
  TLeaseRequest = packed record Magic, Volume, HighIndex, LowIndex: DWORD; end;
  TBuildLeaseServer = class
  private
    FPipe, FJob: THandle;
    FEndpoint: string;
    FExpected, FRequest: TLeaseRequest;
    FReply: DWORD;
    FIO: TOverlapped;
    FState: Integer;
    FPending: Boolean;
    FDeadline: QWord;
    procedure Disconnect;
    function Complete: Boolean;
    procedure BeginConnect;
  public
    constructor Create(OutputLock, Job: THandle);
    destructor Destroy; override;
    procedure Poll;
    property Endpoint: string read FEndpoint;
  end;
function RequestBuildLease(OutputLock: THandle; Interrupt: TLockInterruptScope; CheckInterrupt: TCheckLockInterrupt): Boolean;
implementation
uses SysUtils, ScuErrors, ScuPlatformProcessJobWindows, ScuPlatformProcessStringsWindows,
  ScuPlatformFileSecurityWindows;
const PipePrefix = '\\.\pipe\SCU.BuildLease.'; LeaseMagic = $53435531;
function ClientProcess(Pipe: THandle; out ID: DWORD): BOOL; stdcall; external 'kernel32.dll' name 'GetNamedPipeClientProcessId';
function CancelIO(Handle: THandle; Overlapped: POverlapped): BOOL; stdcall; external 'kernel32.dll' name 'CancelIoEx';
function Identity(Handle: THandle): TLeaseRequest;
var Info: TByHandleFileInformation;
begin
  if not GetFileInformationByHandle(Handle, Info) then RaiseSystemError('Could not identify build output lock', GetLastError);
  Result.Magic := LeaseMagic; Result.Volume := Info.dwVolumeSerialNumber;
  Result.HighIndex := Info.nFileIndexHigh; Result.LowIndex := Info.nFileIndexLow;
end;
constructor TBuildLeaseServer.Create(OutputLock, Job: THandle);
var GUID: TGUID; Attributes: TSecurityAttributes; Descriptor: PSecurityDescriptor;
begin
  inherited Create; FPipe := INVALID_HANDLE_VALUE; FJob := Job;
  FExpected := Identity(OutputLock);
  if CreateGUID(GUID) <> 0 then raise EScuError.Create('Could not generate build lease endpoint.');
  FEndpoint := PipePrefix + StringReplace(Copy(GUIDToString(GUID), 2, 36), '-', '', [rfReplaceAll]);
  PrivateSecurity(Attributes, Descriptor);
  try
    FPipe := CreateNamedPipeW(PWideChar(UTF8Decode(FEndpoint)), PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED or $80000,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or $8 {PIPE_REJECT_REMOTE_CLIENTS}, 1, 64, 64, 0, @Attributes);
    if FPipe = INVALID_HANDLE_VALUE then RaiseSystemError('Could not create build lease broker', GetLastError);
  finally LocalFree(HLOCAL(Descriptor)); end;
  FIO.hEvent := CreateEvent(nil, True, False, nil);
  if FIO.hEvent = 0 then RaiseSystemError('Could not create build lease event', GetLastError);
  BeginConnect;
end;
procedure TBuildLeaseServer.BeginConnect;
var Error: DWORD;
begin
  ResetEvent(FIO.hEvent); FState := 0; FPending := False;
  if not ConnectNamedPipe(FPipe, @FIO) then
  begin
    Error := GetLastError;
    if Error = ERROR_IO_PENDING then FPending := True
    else if Error <> ERROR_PIPE_CONNECTED then RaiseSystemError('Could not listen for build lease requests', Error);
  end;
  FDeadline := GetTickCount64 + 2000;
end;
procedure TBuildLeaseServer.Disconnect;
var Count: DWORD;
begin
  if FPending then
  begin CancelIO(FPipe, @FIO); GetOverlappedResult(FPipe, FIO, Count, True); end;
  FPending := False; DisconnectNamedPipe(FPipe); BeginConnect;
end;
function TBuildLeaseServer.Complete: Boolean;
var Count: DWORD; Error: DWORD;
begin
  Result := True;
  if not FPending then Exit;
  if GetOverlappedResult(FPipe, FIO, Count, False) then
  begin
    FPending := False;
    if ((FState = 1) and (Count <> SizeOf(FRequest))) or ((FState in [2, 3]) and (Count <> SizeOf(FReply))) then
    begin Disconnect; Exit(False); end;
  end
  else
  begin
    Error := GetLastError;
    if (Error = ERROR_IO_INCOMPLETE) and ((FState = 0) or (GetTickCount64 < FDeadline)) then Exit(False);
    Disconnect; Result := False;
  end;
end;
procedure TBuildLeaseServer.Poll;
var Count, ID, Error: DWORD;
begin
  if not Complete then Exit;
  case FState of
    0: begin
      if not ClientProcess(FPipe, ID) or not ProcessBelongsToJob(ID, FJob) then begin Disconnect; Exit; end;
      ResetEvent(FIO.hEvent); FState := 1; FDeadline := GetTickCount64 + 2000;
      if not Windows.ReadFile(FPipe, FRequest, SizeOf(FRequest), Count, @FIO) then
      begin
        Error := GetLastError;
        if Error = ERROR_IO_PENDING then FPending := True else Disconnect;
      end
      else if Count <> SizeOf(FRequest) then Disconnect;
    end;
    1: begin
      FReply := Ord(CompareByte(FRequest, FExpected, SizeOf(FExpected)) = 0);
      ResetEvent(FIO.hEvent); FState := 2;
      if not Windows.WriteFile(FPipe, FReply, SizeOf(FReply), Count, @FIO) then
      begin
        Error := GetLastError;
        if Error = ERROR_IO_PENDING then FPending := True else Disconnect;
      end
      else if Count <> SizeOf(FReply) then Disconnect;
    end;
    2: begin
      ResetEvent(FIO.hEvent); FState := 3;
      if not Windows.ReadFile(FPipe, FReply, SizeOf(FReply), Count, @FIO) then
      begin
        Error := GetLastError;
        if Error = ERROR_IO_PENDING then FPending := True else Disconnect;
      end
      else if Count <> SizeOf(FReply) then Disconnect;
    end;
    3: Disconnect;
  end;
end;
destructor TBuildLeaseServer.Destroy;
var Count: DWORD;
begin
  if FPipe <> INVALID_HANDLE_VALUE then
  begin
    if FPending then begin CancelIO(FPipe, @FIO); GetOverlappedResult(FPipe, FIO, Count, True); end;
    CloseHandle(FPipe);
  end;
  if FIO.hEvent <> 0 then CloseHandle(FIO.hEvent);
  inherited Destroy;
end;
function ValidEndpoint(const Endpoint: string): Boolean;
var Index: Integer;
begin
  Result := False;
  if (Copy(Endpoint, 1, Length(PipePrefix)) <> PipePrefix) or (Length(Endpoint) <> Length(PipePrefix) + 32) then Exit;
  for Index := Length(PipePrefix) + 1 to Length(Endpoint) do
    if not (Endpoint[Index] in ['0'..'9', 'A'..'F', 'a'..'f']) then Exit;
  Result := True;
end;
function RequestBuildLease(OutputLock: THandle; Interrupt: TLockInterruptScope; CheckInterrupt: TCheckLockInterrupt): Boolean;
var Endpoint: string; Pipe: THandle; Request: TLeaseRequest; Reply, Count, Error: DWORD;
  IO: TOverlapped; Deadline: QWord;
  function Transfer(Buffer: Pointer; Size: DWORD; WriteRequest: Boolean): Boolean;
  var Started: BOOL;
  begin
    ResetEvent(IO.hEvent);
    if WriteRequest then Started := Windows.WriteFile(Pipe, Buffer^, Size, Count, @IO)
    else Started := Windows.ReadFile(Pipe, Buffer^, Size, Count, @IO);
    if not Started and (GetLastError <> ERROR_IO_PENDING) then Exit(False);
    while not GetOverlappedResult(Pipe, IO, Count, False) do
    begin
      if (GetLastError <> ERROR_IO_INCOMPLETE) or (GetTickCount64 >= Deadline) then Exit(False);
      Interrupt.Check;
      if Assigned(CheckInterrupt) then CheckInterrupt();
      WaitForSingleObject(IO.hEvent, 20);
    end;
    Result := Count = Size;
  end;
begin
  Result := False; Endpoint := WindowsEnvironmentValue(WindowsBuildLeaseVariable);
  if not ValidEndpoint(Endpoint) then Exit;
  Request := Identity(OutputLock); Deadline := GetTickCount64 + 2000;
  repeat
    Interrupt.Check;
    if Assigned(CheckInterrupt) then CheckInterrupt();
    Pipe := CreateFileW(PWideChar(UTF8Decode(Endpoint)), GENERIC_READ or GENERIC_WRITE, 0, nil,
      OPEN_EXISTING, FILE_FLAG_OVERLAPPED, 0);
    if Pipe <> INVALID_HANDLE_VALUE then Break;
    Error := GetLastError;
    if (Error <> ERROR_PIPE_BUSY) or (GetTickCount64 >= Deadline) then Exit;
    Sleep(20);
  until False;
  FillChar(IO, SizeOf(IO), 0); IO.hEvent := CreateEvent(nil, True, False, nil);
  try
    if IO.hEvent = 0 then RaiseSystemError('Could not create build lease client event', GetLastError);
    Result := Transfer(@Request, SizeOf(Request), True) and Transfer(@Reply, SizeOf(Reply), False);
    if Result then Result := Transfer(@Reply, SizeOf(Reply), True) and (Reply = 1);
  finally
    CancelIO(Pipe, @IO); GetOverlappedResult(Pipe, IO, Count, True);
    if IO.hEvent <> 0 then CloseHandle(IO.hEvent);
    CloseHandle(Pipe);
  end;
end;
end.
