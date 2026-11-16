unit ScuPlatformOutputLockLinux;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuLockTypes;

type
  TPlatformOutputDirectoryLock = class
  private
    FHandle, FBorrowedHandle: THandle;
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

uses
  BaseUnix, Unix, Linux, SysUtils, ScuErrors, ScuSignals;

function TryLock(Handle: THandle; const Directory: string): Boolean;
var
  Status, Error: cint;
begin
  repeat
    Status := fpFlock(Handle, LOCK_EX or LOCK_NB);
    Error := fpGetErrNo;
  until (Status = 0) or (Error <> ESysEINTR);
  if (Status <> 0) and (Error <> ESysEWOULDBLOCK) then
    RaiseSystemError('Could not lock output directory "' + Directory + '"', Error);
  Result := Status = 0;
end;

constructor TPlatformOutputDirectoryLock.Create(const Directory: string;
  StopWaiting: TStopLockWait; CheckInterrupt: TCheckLockInterrupt);
begin
  inherited Create;
  Acquire(Directory, False, StopWaiting, CheckInterrupt);
end;

constructor TPlatformOutputDirectoryLock.CreateWithBuildLockReuse(const Directory: string;
  StopWaiting: TStopLockWait; CheckInterrupt: TCheckLockInterrupt);
begin
  inherited Create;
  Acquire(Directory, True, StopWaiting, CheckInterrupt);
end;

procedure TPlatformOutputDirectoryLock.Acquire(const Directory: string; AllowBuildReuse: Boolean;
  StopWaiting: TStopLockWait; CheckInterrupt: TCheckLockInterrupt);
var
  BuildLock: string;
  InheritedHandle: Integer;
  OutputInfo, BuildInfo: Stat;
begin
  if not Assigned(StopWaiting) then StopWaiting := @SessionEnding;
  if not Assigned(CheckInterrupt) then CheckInterrupt := @CheckSessionInterrupt;
  FBorrowedHandle := -1;
  FHandle := fpOpen(Directory, O_RDONLY or O_DIRECTORY or O_CLOEXEC);
  if FHandle < 0 then
    RaiseSystemError('Could not open output directory "' + Directory + '"', fpGetErrNo);
  CheckInterrupt();
  FOwnsLock := TryLock(FHandle, Directory);
  if not FOwnsLock then
  begin
    BuildLock := GetEnvironmentVariable(BuildOutputLockVariable);
    if BuildLock <> '' then
    begin
      // A synchronous build child can reuse only the lock on this directory.
      // Trying flock on the inherited descriptor confirms it shares the lock.
      if AllowBuildReuse and TryStrToInt(BuildLock, InheritedHandle) and
        (InheritedHandle >= 3) and (InheritedHandle <> FHandle) and
        (fpFStat(InheritedHandle, BuildInfo) = 0) and (fpFStat(FHandle, OutputInfo) = 0) and
        (BuildInfo.st_dev = OutputInfo.st_dev) and (BuildInfo.st_ino = OutputInfo.st_ino) and
        TryLock(InheritedHandle, Directory) then
        FBorrowedHandle := InheritedHandle
      else
        // Waiting from inside a build can deadlock its parent or another build.
        raise EScuError.CreateFmt('An expansion is already using output directory %s.', [Directory]);
    end
    else
      repeat
        if StopWaiting() then
          raise EScuError.CreateFmt('Output directory %s is busy during shutdown.', [Directory]);
        Sleep(20);
        CheckInterrupt();
        FOwnsLock := TryLock(FHandle, Directory);
      until FOwnsLock;
  end;
  CheckInterrupt();
end;

function TPlatformOutputDirectoryLock.GetBuildHandle: THandle;
begin
  if FBorrowedHandle >= 0 then
    Exit(FBorrowedHandle);
  Result := FHandle;
end;

destructor TPlatformOutputDirectoryLock.Destroy;
begin
  if FHandle >= 0 then
  begin
    // A background child can still have a descriptor after the build returns.
    if FOwnsLock then
      fpFlock(FHandle, LOCK_UN);
    fpClose(FHandle);
  end;
  inherited Destroy;
end;

end.
