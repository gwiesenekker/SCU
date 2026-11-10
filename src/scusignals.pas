unit ScuSignals;

{$mode objfpc}{$H+}

interface

uses
  BaseUnix, Process, ScuIO;

const
  SessionSignals: array[0..3] of cint = (SIGINT, SIGHUP, SIGTERM, SIGQUIT);

type
  ECommandCancelled = class(EScuError);
  TSessionSignalHandlers = array[Low(SessionSignals)..High(SessionSignals)] of SigActionRec;

var
  SessionSignal: cint;

procedure StartSessionSignals(out Previous: TSessionSignalHandlers);
procedure RestoreSessionSignals(const Previous: TSessionSignalHandlers);
procedure NoteSessionSignal(Signal: cint); cdecl;
procedure CheckSessionInterrupt;
function SessionEnding: Boolean;
procedure StartBuildProcessGroup;
function WaitForChild(Child: TProcess; OwnProcessGroup: Boolean = False;
  ChildHandlesInterrupt: Boolean = False): Integer;

implementation

uses
  SysUtils, Unix, Termio, InitC;

var
  ChildOwnsInterrupt: Boolean;

function setpgid(Pid, Group: cint): cint; cdecl; external 'c';
function tcgetpgrp(Handle: cint): cint; cdecl; external 'c';
function tcsetpgrp(Handle, Group: cint): cint; cdecl; external 'c';

procedure NoteSessionSignal(Signal: cint); cdecl;
begin
  if (SessionSignal = 0) or (Signal <> SIGINT) then
    SessionSignal := Signal;
end;

procedure CheckSessionInterrupt;
begin
  if SessionSignal = SIGINT then
    raise ECommandCancelled.Create('Command cancelled.');
end;

function SessionEnding: Boolean;
begin
  Result := SessionSignal in [SIGHUP, SIGTERM, SIGQUIT];
end;

procedure HandleSessionSignal(Signal: cint; Info: PSigInfo; Context: PSigContext); cdecl;
begin
  if (Signal <> SIGINT) or not ChildOwnsInterrupt then
    NoteSessionSignal(Signal);
end;

procedure StartSessionSignals(out Previous: TSessionSignalHandlers);
var
  Action: SigActionRec;
  Index: Integer;
begin
  SessionSignal := 0;
  FillChar(Action, SizeOf(Action), 0);
  Action.sa_handler := @HandleSessionSignal;
  Action.sa_flags := SA_SIGINFO;
  for Index := Low(SessionSignals) to High(SessionSignals) do
    fpSigAddSet(Action.sa_mask, SessionSignals[Index]);
  for Index := Low(SessionSignals) to High(SessionSignals) do
    if fpSigAction(SessionSignals[Index], @Action, @Previous[Index]) <> 0 then
      RaiseSystemError(Format('Could not install the handler for signal %d', [SessionSignals[Index]]), fpGetErrNo);
end;

procedure RestoreSessionSignals(const Previous: TSessionSignalHandlers);
var
  Index: Integer;
begin
  for Index := Low(SessionSignals) to High(SessionSignals) do
    fpSigAction(SessionSignals[Index], @Previous[Index], nil);
end;

function SetForegroundGroup(Group: cint): Boolean;
var
  Blocked, Previous: TSigSet;
  Status: cint;
begin
  // The caller may be in the background while transferring the terminal.
  fpSigEmptySet(Blocked);
  fpSigAddSet(Blocked, SIGTTOU);
  if fpSigProcMask(SIG_BLOCK, @Blocked, @Previous) <> 0 then
    Exit(False);
  repeat
    Status := tcsetpgrp(StdInputHandle, Group);
  until (Status = 0) or (cerrno <> ESysEINTR);
  fpSigProcMask(SIG_SETMASK, @Previous, nil);
  Result := Status = 0;
end;

procedure StartBuildProcessGroup;
var
  Foreground: Boolean;
begin
  Foreground := tcgetpgrp(StdInputHandle) = fpGetPGrp;
  if setpgid(0, 0) <> 0 then
    fpExit(126);
  // Give the build the terminal before it can read or write to it.
  if Foreground and not SetForegroundGroup(fpGetPGrp) then
    fpExit(126);
end;

function WaitForChild(Child: TProcess; OwnProcessGroup, ChildHandlesInterrupt: Boolean): Integer;
var
  Sent, Status, WaitOptions, ForegroundGroup: cint;
  Pid, Waited: TPid;
  Deadline: QWord;
  TerminalMode: TermIOS;
  RestoreTerminal, Stopped: Boolean;

  procedure SignalChild(Signal: cint);
  begin
    if not OwnProcessGroup or (fpKill(-Pid, Signal) <> 0) then
      fpKill(Pid, Signal);
  end;

begin
  CheckSessionInterrupt;
  if SessionEnding then
    raise ECommandCancelled.Create('Command cancelled.');
  ForegroundGroup := fpGetPGrp;
  RestoreTerminal := OwnProcessGroup and (tcgetpgrp(StdInputHandle) = ForegroundGroup) and
    (TCGetAttr(StdInputHandle, TerminalMode) = 0);
  WaitOptions := WNOHANG;
  if OwnProcessGroup then
    WaitOptions := WaitOptions or WUNTRACED;
  Sent := 0;
  Deadline := 0;
  Stopped := False;
  ChildOwnsInterrupt := ChildHandlesInterrupt;
  try
    try
      Child.Execute;
    except
      on E: EProcess do
        raise EScuError.CreateFmt('Could not start "%s": %s', [Child.Executable, E.Message]);
    end;
    Pid := Child.ProcessID;
    repeat
      repeat
        Waited := fpWaitPid(Pid, @Status, WaitOptions);
      until (Waited >= 0) or (fpGetErrNo <> ESysEINTR);
      if Waited < 0 then
        RaiseSystemError('Could not wait for "' + Child.Executable + '"', fpGetErrNo);
      if Waited = Pid then
      begin
        if not WIfStopped(Status) then
          Break;
        // A stopped build cannot finish while SCU is waiting for it.
        Stopped := True;
        SignalChild(SIGKILL);
      end
      else if (SessionSignal <> 0) and (SessionSignal <> Sent) then
      begin
        Sent := SessionSignal;
        SignalChild(Sent);
        Deadline := GetTickCount64 + 1500;
      end
      else if (Deadline <> 0) and (GetTickCount64 >= Deadline) then
      begin
        SignalChild(SIGKILL);
        Deadline := 0;
      end;
      Sleep(10);
    until False;
    if Stopped then
      raise EScuError.Create('Build command stopped before it finished.');
    if WIfSignaled(Status) then
      Result := 128 + WTermSig(Status)
    else
      Result := WExitStatus(Status);
  finally
    ChildOwnsInterrupt := False;
    if RestoreTerminal and SetForegroundGroup(ForegroundGroup) then
    begin
      while (TCSetAttr(StdInputHandle, TCSANOW, TerminalMode) <> 0) and
        (fpGetErrNo = ESysEINTR) do ;
    end;
  end;
end;

end.
