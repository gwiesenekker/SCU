unit ScuSignals;

{$mode objfpc}{$H+}

interface

uses
  BaseUnix;

const
  SessionSignals: array[0..3] of cint = (SIGINT, SIGHUP, SIGTERM, SIGQUIT);

type
  TSessionSignalHandlers = array[Low(SessionSignals)..High(SessionSignals)] of SigActionRec;

var
  SessionSignal: cint;

procedure StartSessionSignals(out Previous: TSessionSignalHandlers);
procedure RestoreSessionSignals(const Previous: TSessionSignalHandlers);
procedure NoteSessionSignal(Signal: cint); cdecl;
procedure CheckSessionInterrupt;
function SessionEnding: Boolean;
// Editors in SCU's process group receive terminal Ctrl+C directly.
procedure SetChildHandlesInterrupt(Value: Boolean);

implementation

uses
  SysUtils, ScuErrors;

var
  ChildOwnsInterrupt: Boolean;

procedure SetChildHandlesInterrupt(Value: Boolean);
begin
  ChildOwnsInterrupt := Value;
end;

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

end.
