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
procedure WaitForChild(Child: TProcess; OwnProcessGroup: Boolean = False);
function ChildExitStatus(Child: TProcess): Integer;

implementation

uses
  SysUtils;

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

procedure HandleSessionSignal(Signal: cint; Info: PSigInfo; Context: PSigContext); cdecl;
begin
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
      RaiseLastOSError(fpGetErrNo);
end;

procedure RestoreSessionSignals(const Previous: TSessionSignalHandlers);
var
  Index: Integer;
begin
  for Index := Low(SessionSignals) to High(SessionSignals) do
    fpSigAction(SessionSignals[Index], @Previous[Index], nil);
end;

procedure WaitForChild(Child: TProcess; OwnProcessGroup: Boolean);
var
  Sent: cint;
  Deadline: QWord;
begin
  Sent := 0;
  Deadline := 0;
  Child.Execute;
  while Child.Running do
  begin
    if (SessionSignal <> 0) and (SessionSignal <> Sent) then
    begin
      Sent := SessionSignal;
      if not OwnProcessGroup or (fpKill(-Child.ProcessID, Sent) <> 0) then
        fpKill(Child.ProcessID, Sent);
      if OwnProcessGroup or (Sent <> SIGINT) then
        Deadline := GetTickCount64 + 1500;
    end
    else if (Deadline <> 0) and (GetTickCount64 >= Deadline) then
    begin
      if not OwnProcessGroup or (fpKill(-Child.ProcessID, SIGKILL) <> 0) then
        fpKill(Child.ProcessID, SIGKILL);
      Deadline := 0;
    end;
    Sleep(10);
  end;
end;

function ChildExitStatus(Child: TProcess): Integer;
begin
  if WIfSignaled(Child.ExitStatus) then
    Result := 128 + WTermSig(Child.ExitStatus)
  else
    Result := Child.ExitCode;
end;

end.
