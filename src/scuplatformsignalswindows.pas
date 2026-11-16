unit ScuPlatformSignalsWindows;
{$mode objfpc}{$H+}
interface
uses Windows;
const SignalInterrupt = 2; SignalHangup = 1; SignalTerminate = 15; SignalQuit = 3;
type TSessionSignalHandlers = record Active: Boolean; end;
procedure StartSessionSignals(out Previous: TSessionSignalHandlers);
procedure RestoreSessionSignals(const Previous: TSessionSignalHandlers);
procedure NoteSessionSignal(Signal: Integer); cdecl;
function PendingSignal: Integer;
function ClearInterrupt: Boolean;
procedure CheckSessionInterrupt;
function SessionEnding: Boolean;
procedure SetChildHandlesInterrupt(Value: Boolean);
function ConsumeChildInterrupt: Boolean;
procedure AcquireSignalWait;
procedure ReleaseSignalWait;
function SignalWaitHandle: THandle;
implementation
uses SysUtils, ScuErrors;
var
  Guard: TRTLCriticalSection;
  Users, Sessions: Integer;
  Pending, ChildOwns, ChildInterrupted: LongInt;
  Wake, Finished: THandle;
function PendingSignal: Integer;
begin Result := System.InterlockedCompareExchange(Pending, 0, 0); end;
procedure RefreshWake;
begin
  ResetEvent(Wake);
  if (PendingSignal <> 0) or (System.InterlockedCompareExchange(ChildInterrupted, 0, 0) <> 0) then SetEvent(Wake);
end;
procedure NoteSessionSignal(Signal: Integer); cdecl;
begin
  if Signal = SignalInterrupt then System.InterlockedCompareExchange(Pending, Signal, 0)
  else System.InterlockedExchange(Pending, Signal);
  SetEvent(Wake);
end;
function HandleControl(Event: DWORD): BOOL; stdcall;
begin
  Result := True;
  case Event of
    CTRL_C_EVENT, CTRL_BREAK_EVENT:
      begin
        if System.InterlockedCompareExchange(ChildOwns, 0, 0) <> 0 then
        begin System.InterlockedExchange(ChildInterrupted, 1); SetEvent(Wake); end
        else NoteSessionSignal(SignalInterrupt);
      end;
    CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        NoteSessionSignal(SignalTerminate);
        // Windows ends the process when this callback returns. Give the main
        // thread bounded time to unwind children, locks and session saves.
        WaitForSingleObject(Finished, 4000);
      end;
    else Result := False;
  end;
end;
procedure AcquireSignalWait;
begin
  System.EnterCriticalSection(Guard);
  try
    if Users = 0 then
    begin
      ResetEvent(Finished);
      if not SetConsoleCtrlHandler(@HandleControl, True) then
        RaiseSystemError('Could not install Windows session signal handler', GetLastError);
    end;
    Inc(Users);
  finally System.LeaveCriticalSection(Guard); end;
end;
function ClearInterrupt: Boolean;
begin
  Result := System.InterlockedCompareExchange(Pending, 0, SignalInterrupt) = SignalInterrupt;
  RefreshWake;
end;
procedure ReleaseSignalWait;
begin
  System.EnterCriticalSection(Guard);
  try
    Dec(Users);
    if Users = 0 then
    begin
      SetConsoleCtrlHandler(@HandleControl, False);
      if Sessions = 0 then
      begin ClearInterrupt; System.InterlockedExchange(ChildInterrupted, 0); RefreshWake; end;
      SetEvent(Finished);
    end;
  finally System.LeaveCriticalSection(Guard); end;
end;
procedure StartSessionSignals(out Previous: TSessionSignalHandlers);
begin
  Previous.Active := False;
  AcquireSignalWait;
  try
    // CREATE_NEW_PROCESS_GROUP can inherit an ignore-Ctrl+C attribute. An
    // explicit SCU session owns cancellation and enables normal delivery.
    if not SetConsoleCtrlHandler(nil, False) then
      RaiseSystemError('Could not enable Windows session Ctrl+C', GetLastError);
    System.EnterCriticalSection(Guard);
    try
      Inc(Sessions); Previous.Active := True;
      System.InterlockedExchange(Pending, 0); System.InterlockedExchange(ChildInterrupted, 0); RefreshWake;
    finally System.LeaveCriticalSection(Guard); end;
  except ReleaseSignalWait; raise; end;
end;
procedure RestoreSessionSignals(const Previous: TSessionSignalHandlers);
begin
  if not Previous.Active then Exit;
  System.EnterCriticalSection(Guard);
  try Dec(Sessions); finally System.LeaveCriticalSection(Guard); end;
  ReleaseSignalWait;
end;
procedure CheckSessionInterrupt;
begin
  if PendingSignal = SignalInterrupt then raise ECommandCancelled.Create('Command cancelled.');
end;
function SessionEnding: Boolean;
begin Result := PendingSignal in [SignalHangup, SignalTerminate, SignalQuit]; end;
procedure SetChildHandlesInterrupt(Value: Boolean);
begin System.InterlockedExchange(ChildOwns, Ord(Value)); end;
function ConsumeChildInterrupt: Boolean;
begin Result := System.InterlockedExchange(ChildInterrupted, 0) <> 0; RefreshWake; end;
function SignalWaitHandle: THandle;
begin Result := Wake; end;
initialization
  System.InitCriticalSection(Guard);
  Wake := CreateEvent(nil, True, False, nil); Finished := CreateEvent(nil, True, True, nil);
  if (Wake = 0) or (Finished = 0) then RaiseSystemError('Could not create Windows session signal events', GetLastError);
// Events live until process teardown: a console-close callback can still be
// waiting during Pascal unit finalization, so closing its wait handle is unsafe.
finalization
  SetEvent(Finished);
  System.DoneCriticalSection(Guard);
end.
