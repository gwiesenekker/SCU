unit ScuLocks;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
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

implementation

uses
  BaseUnix, Unix, Linux, ScuErrors;

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

end.
