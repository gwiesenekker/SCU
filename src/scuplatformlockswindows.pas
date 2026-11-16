unit ScuPlatformLocksWindows;

{$mode objfpc}{$H+}

interface

uses SysUtils, ScuLockTypes;

type
  TPlatformFileLock = class
  private
    FHandle: THandle;
    FOwnsLock: Boolean;
  public
    constructor Create(const Path: string; StopWaiting: TStopLockWait = nil;
      CheckInterrupt: TCheckLockInterrupt = nil);
    destructor Destroy; override;
  end;

implementation

uses Windows, ScuErrors, ScuPlatformLockHandlesWindows, ScuPlatformLockInterruptWindows;

constructor TPlatformFileLock.Create(const Path: string; StopWaiting: TStopLockWait;
  CheckInterrupt: TCheckLockInterrupt);
var Interrupt: TLockInterruptScope;

  procedure Check;
  begin
    Interrupt.Check;
    if Assigned(CheckInterrupt) then CheckInterrupt();
  end;

begin
  inherited Create;
  FHandle := INVALID_HANDLE_VALUE;
  Interrupt := TLockInterruptScope.Create;
  try
    Check;
    FHandle := OpenLockHandle(Path);
    repeat
      Check;
      FOwnsLock := TryLockHandle(FHandle, Path);
      if FOwnsLock then Break;
      if Assigned(StopWaiting) and StopWaiting() then
        raise EScuError.CreateFmt('Library lock %s is busy during shutdown.', [Path]);
      Sleep(20);
    until False;
    // A cancellation that arrives as the lock becomes free must be observed
    // before the constructor returns and the command can take effect.
    Check;
  finally
    Interrupt.Free;
  end;
end;

destructor TPlatformFileLock.Destroy;
begin
  if FHandle <> INVALID_HANDLE_VALUE then
    if FOwnsLock then ReleaseLockHandle(FHandle) else CloseHandle(FHandle);
  inherited Destroy;
end;

end.
