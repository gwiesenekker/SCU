unit ScuPlatformOutputLockWindows;

{$mode objfpc}{$H+}

interface

uses ScuLockTypes;

type
  TPlatformOutputDirectoryLock = class
  private
    FHandle: THandle;
    FOwnsLock: Boolean;
    procedure Acquire(const Directory: string; AllowBuildReuse: Boolean;
      StopWaiting: TStopLockWait; CheckInterrupt: TCheckLockInterrupt);
    function GetBuildHandle: THandle;
  public
    constructor Create(const Directory: string; StopWaiting: TStopLockWait = nil;
      CheckInterrupt: TCheckLockInterrupt = nil);
    constructor CreateWithBuildLockReuse(const Directory: string; StopWaiting: TStopLockWait = nil;
      CheckInterrupt: TCheckLockInterrupt = nil);
    destructor Destroy; override;
    property BuildHandle: THandle read GetBuildHandle;
  end;

implementation

uses Windows, SysUtils, ScuErrors, ScuPlatformPaths,
  ScuPlatformLockHandlesWindows, ScuPlatformLockInterruptWindows;

constructor TPlatformOutputDirectoryLock.Create(const Directory: string;
  StopWaiting: TStopLockWait; CheckInterrupt: TCheckLockInterrupt);
begin
  inherited Create;
  FHandle := INVALID_HANDLE_VALUE;
  Acquire(Directory, False, StopWaiting, CheckInterrupt);
end;

constructor TPlatformOutputDirectoryLock.CreateWithBuildLockReuse(const Directory: string;
  StopWaiting: TStopLockWait; CheckInterrupt: TCheckLockInterrupt);
begin
  inherited Create;
  FHandle := INVALID_HANDLE_VALUE;
  Acquire(Directory, True, StopWaiting, CheckInterrupt);
end;

procedure TPlatformOutputDirectoryLock.Acquire(const Directory: string; AllowBuildReuse: Boolean;
  StopWaiting: TStopLockWait; CheckInterrupt: TCheckLockInterrupt);
var Path: string; Interrupt: TLockInterruptScope;

  procedure Check;
  begin
    Interrupt.Check;
    if Assigned(CheckInterrupt) then CheckInterrupt();
  end;

begin
  Interrupt := TLockInterruptScope.Create;
  try
    Check;
    Path := IncludeTrailingPathDelimiter(PlatformCanonicalDirectory(Directory)) + WindowsOutputLockName;
    FHandle := OpenLockHandle(Path);
    Check;
    FOwnsLock := TryLockHandle(FHandle, Path);
    if not FOwnsLock then
    begin
      // POSIX descriptor numbers are not Windows lock-ownership capabilities.
      // Reject nested waits rather than trusting an arbitrary/stale handle or
      // deadlocking the parent. Windows build handoff needs the process port.
      if GetEnvironmentVariable(BuildOutputLockVariable) <> '' then
        raise EScuError.CreateFmt('An expansion is already using output directory %s. Windows build-lock reuse is not available.', [Directory]);
      repeat
        if Assigned(StopWaiting) and StopWaiting() then
          raise EScuError.CreateFmt('Output directory %s is busy during shutdown.', [Directory]);
        Sleep(20);
        Check;
        FOwnsLock := TryLockHandle(FHandle, Path);
      until FOwnsLock;
    end;
    Check;
  finally
    Interrupt.Free;
  end;
end;

function TPlatformOutputDirectoryLock.GetBuildHandle: THandle;
begin
  Result := FHandle;
end;

destructor TPlatformOutputDirectoryLock.Destroy;
begin
  if FHandle <> INVALID_HANDLE_VALUE then
    if FOwnsLock then ReleaseLockHandle(FHandle) else CloseHandle(FHandle);
  inherited Destroy;
end;

end.
