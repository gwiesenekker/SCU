unit ScuOutputLock;

{$mode objfpc}{$H+}

interface

uses
  Classes;

const
  BuildOutputLockVariable = 'SCU_BUILD_OUTPUT_LOCK_FD';

type
  TOutputDirectoryLock = class
  private
    FHandle, FBorrowedHandle: THandle;
    FOwnsLock: Boolean;
    procedure Acquire(const Directory: string; AllowBuildReuse: Boolean);
    function GetBuildHandle: THandle;
  public
    constructor Create(const Directory: string);
    constructor CreateWithBuildLockReuse(const Directory: string);
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

constructor TOutputDirectoryLock.Create(const Directory: string);
begin
  inherited Create;
  Acquire(Directory, False);
end;

constructor TOutputDirectoryLock.CreateWithBuildLockReuse(const Directory: string);
begin
  inherited Create;
  Acquire(Directory, True);
end;

procedure TOutputDirectoryLock.Acquire(const Directory: string; AllowBuildReuse: Boolean);
var
  BuildLock: string;
  InheritedHandle: Integer;
  OutputInfo, BuildInfo: Stat;
begin
  FBorrowedHandle := -1;
  FHandle := fpOpen(Directory, O_RDONLY or O_DIRECTORY or O_CLOEXEC);
  if FHandle < 0 then
    RaiseSystemError('Could not open output directory "' + Directory + '"', fpGetErrNo);
  CheckSessionInterrupt;
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
        if SessionEnding then
          raise EScuError.CreateFmt('Output directory %s is busy during shutdown.', [Directory]);
        Sleep(20);
        CheckSessionInterrupt;
        FOwnsLock := TryLock(FHandle, Directory);
      until FOwnsLock;
  end;
  CheckSessionInterrupt;
end;

function TOutputDirectoryLock.GetBuildHandle: THandle;
begin
  if FBorrowedHandle >= 0 then
    Exit(FBorrowedHandle);
  Result := FHandle;
end;

destructor TOutputDirectoryLock.Destroy;
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
