unit ScuSignals;

{$mode objfpc}{$H+}{$macro on}

interface

uses
  {$IFDEF WINDOWS}ScuPlatformSignalsWindows{$ELSE}BaseUnix, ScuPlatformSignalsLinux{$ENDIF};

const
  SignalInterrupt = 2;
  SignalHangup = 1;
  SignalTerminate = 15;
  SignalQuit = 3;
  {$IFDEF WINDOWS}
  SIGINT = SignalInterrupt;
  SIGHUP = SignalHangup;
  SIGTERM = SignalTerminate;
  SIGQUIT = SignalQuit;
  {$ENDIF}
  SessionSignals: array[0..3] of Integer = (SignalInterrupt, SignalHangup, SignalTerminate, SignalQuit);
type
  TSessionSignalHandlers = {$IFDEF WINDOWS}ScuPlatformSignalsWindows{$ELSE}ScuPlatformSignalsLinux{$ENDIF}.TSessionSignalHandlers;

procedure StartSessionSignals(out Previous: TSessionSignalHandlers);
procedure RestoreSessionSignals(const Previous: TSessionSignalHandlers);
procedure NoteSessionSignal(Signal: Integer); cdecl;
function PendingSignal: Integer;
function ClearInterrupt: Boolean;
procedure CheckSessionInterrupt;
function SessionEnding: Boolean;
// Editors in SCU's process group receive terminal Ctrl+C directly.
procedure SetChildHandlesInterrupt(Value: Boolean);
function ConsumeChildInterrupt: Boolean;

implementation
{$IFDEF WINDOWS}{$DEFINE Backend := ScuPlatformSignalsWindows}
{$ELSE}{$DEFINE Backend := ScuPlatformSignalsLinux}{$ENDIF}
procedure StartSessionSignals(out Previous: TSessionSignalHandlers);
begin
  Backend.StartSessionSignals(Previous);
end;
procedure RestoreSessionSignals(const Previous: TSessionSignalHandlers);
begin
  Backend.RestoreSessionSignals(Previous);
end;
procedure NoteSessionSignal(Signal: Integer); cdecl;
begin
  Backend.NoteSessionSignal(Signal);
end;
function PendingSignal: Integer;
begin
  Result := Backend.PendingSignal;
end;
function ClearInterrupt: Boolean;
begin
  Result := Backend.ClearInterrupt;
end;
procedure CheckSessionInterrupt;
begin
  Backend.CheckSessionInterrupt;
end;
function SessionEnding: Boolean;
begin
  Result := Backend.SessionEnding;
end;
procedure SetChildHandlesInterrupt(Value: Boolean);
begin
  Backend.SetChildHandlesInterrupt(Value);
end;
function ConsumeChildInterrupt: Boolean;
begin
  Result := Backend.ConsumeChildInterrupt;
end;
end.
