unit ScuProcess;

{$mode objfpc}{$H+}

interface

uses
  Process;

type
  TChildProcessOptions = set of (cpOwnProcessGroup, cpHandlesInterrupt);

procedure StartBuildProcessGroup;
function WaitForChild(Child: TProcess; Options: TChildProcessOptions = []): Integer;

implementation

uses
  SysUtils, BaseUnix, Unix, Termio, InitC, ScuErrors, ScuSignals;

function setpgid(Pid, Group: cint): cint; cdecl; external 'c';
function tcgetpgrp(Handle: cint): cint; cdecl; external 'c';
function tcsetpgrp(Handle, Group: cint): cint; cdecl; external 'c';

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

function WaitForChild(Child: TProcess; Options: TChildProcessOptions): Integer;
var
  Sent, Status, WaitOptions, ForegroundGroup: cint;
  Pid, Waited: TPid;
  Deadline: QWord;
  TerminalMode: TermIOS;
  RestoreTerminal, Stopped: Boolean;
  Received: cint;

  procedure SignalChild(Signal: cint);
  begin
    if not (cpOwnProcessGroup in Options) or (fpKill(-Pid, Signal) <> 0) then
      fpKill(Pid, Signal);
  end;

  function SuspendBuild: Boolean;
  var
    BuildMode: TermIOS;
    HasBuildMode: Boolean;
  begin
    // Return the terminal to SCU before stopping so its shell can regain it.
    if not RestoreTerminal or (tcgetpgrp(StdInputHandle) <> Pid) or
      not SetForegroundGroup(ForegroundGroup) then
      Exit(False);
    HasBuildMode := TCGetAttr(StdInputHandle, BuildMode) = 0;
    TCSetAttr(StdInputHandle, TCSANOW, TerminalMode);
    if ForegroundGroup = fpGetPid then
      fpKill(-ForegroundGroup, SIGTSTP)
    else
      fpKill(fpGetPid, SIGTSTP);
    // A background resume leaves the terminal with the shell.
    if tcgetpgrp(StdInputHandle) = ForegroundGroup then
    begin
      if HasBuildMode then
        TCSetAttr(StdInputHandle, TCSANOW, BuildMode);
      if not SetForegroundGroup(Pid) then
        Exit(False);
    end;
    SignalChild(SIGCONT);
    Result := True;
  end;

begin
  CheckSessionInterrupt;
  if SessionEnding then
    raise ECommandCancelled.Create('Command cancelled.');
  ForegroundGroup := fpGetPGrp;
  RestoreTerminal := (cpOwnProcessGroup in Options) and (tcgetpgrp(StdInputHandle) = ForegroundGroup) and
    (TCGetAttr(StdInputHandle, TerminalMode) = 0);
  WaitOptions := WNOHANG;
  if cpOwnProcessGroup in Options then
    WaitOptions := WaitOptions or WUNTRACED;
  Sent := 0;
  Deadline := 0;
  Stopped := False;
  SetChildHandlesInterrupt(cpHandlesInterrupt in Options);
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
        if (WStopSig(Status) = SIGTSTP) and (PendingSignal = 0) and SuspendBuild then
          Continue;
        // Other stops cannot be resumed through the shell's job control.
        Stopped := True;
        SignalChild(SIGKILL);
      end
      else
      begin
        Received := PendingSignal;
        if (Received <> 0) and (Received <> Sent) then
        begin
          Sent := Received;
          SignalChild(Sent);
          Deadline := GetTickCount64 + 1500;
        end
        else if (Deadline <> 0) and (GetTickCount64 >= Deadline) then
        begin
          SignalChild(SIGKILL);
          Deadline := 0;
        end;
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
    SetChildHandlesInterrupt(False);
    if RestoreTerminal and SetForegroundGroup(ForegroundGroup) then
    begin
      while (TCSetAttr(StdInputHandle, TCSANOW, TerminalMode) <> 0) and
        (fpGetErrNo = ESysEINTR) do ;
    end;
  end;
end;

end.
