unit ScuTerminalSession;

{$mode objfpc}{$H+}

interface

uses
  BaseUnix, Termio;

const
  TerminalSuspended = -2;
  TerminalResumed = -3;
  TerminalResized = -4;

type
  TRawTerminalSession = class
  private
    FSignalHandle: cint;
    FPreviousMask: TSigSet;
    FMaskBlocked, FRawMode, FEditingApplied: Boolean;
    FOriginal, FEditing: TermIOS;
    function GetReady: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function ReadInput(var Buffer; Size: SizeUInt; Timeout: Integer): ssize_t;
    procedure Suspend;
    procedure ResumeEditing;
    procedure FinishLine;
    property Ready: Boolean read GetReady;
    property RawMode: Boolean read FRawMode;
  end;

implementation

uses
  SysUtils, Linux, InitC, ScuErrors, ScuOutput, ScuSignals;

function signalfd(Handle: cint; Mask: PSigSet; Flags: cint): cint; cdecl; external 'c';
function sigpending(Mask: PSigSet): cint; cdecl; external 'c';
function tcgetpgrp(Handle: cint): cint; cdecl; external 'c';

constructor TRawTerminalSession.Create;
var
  Signals: TSigSet;
  Signal: cint;
  EnableRawMode: Boolean;
begin
  inherited Create;
  FSignalHandle := -1;
  EnableRawMode := (GetEnvironmentVariable('TERM') <> 'dumb') and (IsATTY(StdErr) = 1);
  fpSigEmptySet(Signals);
  for Signal in SessionSignals do
    fpSigAddSet(Signals, Signal);
  if EnableRawMode then
  begin
    fpSigAddSet(Signals, SIGTSTP);
    fpSigAddSet(Signals, SIGCONT);
    fpSigAddSet(Signals, SIGWINCH);
  end;
  if fpSigProcMask(SIG_BLOCK, @Signals, @FPreviousMask) <> 0 then
    RaiseSystemError('Could not block signals while reading the terminal', fpGetErrNo);
  FMaskBlocked := True;
  if PendingSignal <> 0 then
    Exit;
  FSignalHandle := signalfd(-1, @Signals, O_CLOEXEC);
  if FSignalHandle < 0 then
    RaiseSystemError('Could not open the terminal signal descriptor', cerrno);
  if not EnableRawMode then
    Exit;

  if TCGetAttr(StdInputHandle, FOriginal) <> 0 then
    RaiseSystemError('Could not read terminal attributes', fpGetErrNo);
  FEditing := FOriginal;
  FEditing.c_lflag := FEditing.c_lflag and not (ICANON or ECHO or ISIG or IEXTEN);
  FEditing.c_iflag := FEditing.c_iflag and not (IXON or IXOFF);
  FEditing.c_cc[VMIN] := 1;
  FEditing.c_cc[VTIME] := 0;
  if TCSetAttr(StdInputHandle, TCSANOW, FEditing) <> 0 then
    RaiseSystemError('Could not enable terminal editing mode', fpGetErrNo);
  FRawMode := True;
  FEditingApplied := True;
end;

destructor TRawTerminalSession.Destroy;
begin
  if FEditingApplied then
    TCSetAttr(StdInputHandle, TCSANOW, FOriginal);
  if FSignalHandle >= 0 then
    fpClose(FSignalHandle);
  if FMaskBlocked then
    fpSigProcMask(SIG_SETMASK, @FPreviousMask, nil);
  inherited Destroy;
end;

function TRawTerminalSession.GetReady: Boolean;
begin
  Result := FSignalHandle >= 0;
end;

function TRawTerminalSession.ReadInput(var Buffer; Size: SizeUInt; Timeout: Integer): ssize_t;
var
  Handles: array[0..1] of TPollFD;
  SignalData: array[0..127] of Byte;
  PollResult, Error: cint;
begin
  Handles[0].fd := StdInputHandle;
  Handles[0].events := POLLIN;
  Handles[1].fd := FSignalHandle;
  Handles[1].events := POLLIN;
  repeat
    repeat
      PollResult := fpPoll(@Handles[0], Length(Handles), Timeout);
    until (PollResult >= 0) or (fpGetErrNo <> ESysEINTR);
    if PollResult < 0 then
      RaiseSystemError('Could not poll terminal input', fpGetErrNo);
    if PollResult = 0 then
      Exit(0);
    if (Handles[1].revents and POLLIN) <> 0 then
    begin
      if fpRead(FSignalHandle, SignalData, SizeOf(SignalData)) < 0 then
        RaiseSystemError('Could not read terminal signals', fpGetErrNo);
      case PCardinal(@SignalData[0])^ of
        SIGINT: raise ECommandCancelled.Create('Command cancelled.');
        SIGTSTP: Exit(TerminalSuspended);
        SIGCONT: Exit(TerminalResumed);
        SIGWINCH: Exit(TerminalResized);
      end;
      NoteSessionSignal(PCardinal(@SignalData[0])^);
      Exit(0);
    end;
    Result := fpRead(StdInputHandle, Buffer, Size);
    if Result >= 0 then
      Exit;
    Error := fpGetErrNo;
    if Error = ESysEINTR then
      Continue;
    if Error = ESysEIO then
    begin
      // A background read with SIGTTIN ignored also returns EIO.
      if ((Handles[0].revents and POLLHUP) <> 0) or
        (tcgetpgrp(StdInputHandle) = fpGetPGrp) or (PendingSignal = SIGHUP) then
      begin
        NoteSessionSignal(SIGHUP);
        Exit(0);
      end;
      Sleep(20);
      Continue;
    end;
    RaiseSystemError('Could not read terminal input', Error);
  until False;
end;

procedure TRawTerminalSession.Suspend;
var
  Signals, Previous: TSigSet;
begin
  if TCSetAttr(StdInputHandle, TCSANOW, FOriginal) = 0 then
    FEditingApplied := False;
  WriteDiagnostic('');
  fpSigEmptySet(Signals);
  fpSigAddSet(Signals, SIGTSTP);
  fpSigProcMask(SIG_UNBLOCK, @Signals, @Previous);
  if fpGetPGrp = fpGetPid then
    fpKill(-fpGetPid, SIGTSTP)
  else
    fpKill(fpGetPid, SIGTSTP);
  fpSigProcMask(SIG_SETMASK, @Previous, nil);
  ResumeEditing;
end;

procedure TRawTerminalSession.ResumeEditing;
var
  Pending: TSigSet;
  Signal: cint;
begin
  if sigpending(@Pending) = 0 then
    for Signal in SessionSignals do
      if (Signal <> SIGINT) and (fpSigIsMember(Pending, Signal) = 1) then
      begin
        NoteSessionSignal(Signal);
        Exit;
      end;
  if not SessionEnding and (TCSetAttr(StdInputHandle, TCSANOW, FEditing) = 0) then
    FEditingApplied := True;
end;

procedure TRawTerminalSession.FinishLine;
var
  Group: cint;
begin
  if PendingSignal = SIGHUP then
    Exit;
  Group := tcgetpgrp(StdInputHandle);
  if not SessionEnding or (Group < 0) or (Group = fpGetPGrp) then
    WriteDiagnostic('');
end;

end.
