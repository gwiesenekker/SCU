unit ScuPlatformLockInterruptWindows;

{$mode objfpc}{$H+}

interface

type
  // Catch console Ctrl+C/Break only while acquiring a lock. The console thread
  // records a flag; Pascal exceptions are raised by the waiting thread.
  TLockInterruptScope = class
  private
    FActive: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Check;
  end;

implementation

uses Windows, SysUtils, ScuErrors;

var
  Guard: TRTLCriticalSection;
  Waiters: Integer;
  Interrupted: LongInt;

function HandleControl(Event: DWORD): BOOL; stdcall;
begin
  Result := Event in [CTRL_C_EVENT, CTRL_BREAK_EVENT];
  if Result then System.InterlockedExchange(Interrupted, 1);
end;

constructor TLockInterruptScope.Create;
begin
  inherited Create;
  System.EnterCriticalSection(Guard);
  try
    if Waiters = 0 then
    begin
      System.InterlockedExchange(Interrupted, 0);
      if not SetConsoleCtrlHandler(@HandleControl, True) then
        RaiseSystemError('Could not enable Ctrl+C during the lock wait', GetLastError);
    end;
    Inc(Waiters);
    FActive := True;
  finally
    System.LeaveCriticalSection(Guard);
  end;
end;

procedure TLockInterruptScope.Check;
begin
  if System.InterlockedCompareExchange(Interrupted, 0, 0) <> 0 then
    raise ECommandCancelled.Create('Command cancelled.');
end;

destructor TLockInterruptScope.Destroy;
begin
  System.EnterCriticalSection(Guard);
  try
    if FActive then
    begin
      Dec(Waiters);
      if Waiters = 0 then
      begin
        SetConsoleCtrlHandler(@HandleControl, False);
        System.InterlockedExchange(Interrupted, 0);
      end;
    end;
  finally
    System.LeaveCriticalSection(Guard);
  end;
  inherited Destroy;
end;

initialization
  System.InitCriticalSection(Guard);
finalization
  System.DoneCriticalSection(Guard);
end.
