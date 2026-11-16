unit ScuPlatformTerminalSessionWindows;
{$mode objfpc}{$H+}
interface
uses Windows, ScuTerminalTypes, ScuPlatformTerminalKeysWindows;
type
  TPlatformRawTerminalSession = class(TTerminalSession)
  private
    FInput, FOutput: THandle;
    FInputMode, FOutputMode, FInputCP, FOutputCP: DWORD;
    FOwnsSignals, FConsole, FRawMode, FInputChanged, FOutputChanged, FCodePagesChanged: Boolean;
    FPending, FPlain: string;
    FEncoder: TConsoleKeyEncoder;
    function Pop(var Buffer; Size: SizeUInt): SizeInt;
    function ReadRedirected(var Buffer; Size: SizeUInt; Timeout: Integer): SizeInt;
  protected
    function GetReady: Boolean; override;
    function GetRawMode: Boolean; override;
  public
    constructor Create;
    destructor Destroy; override;
    function ReadInput(var Buffer; Size: SizeUInt; Timeout: Integer): SizeInt; override;
    procedure Suspend; override;
    procedure ResumeEditing; override;
    procedure FinishLine; override;
    procedure GetSize(out Columns, Rows: Integer); override;
  end;
function ReadRedirectedCommandLine(out Line: string): Boolean;
implementation
uses SysUtils, ScuErrors, ScuPlatformSignalsWindows, ScuPlatformTerminalWindows;
const EnableVT = $0004; EnableVTInput = $0200; EnableQuickEdit = $0040; EnableExtended = $0080;
constructor TPlatformRawTerminalSession.Create;
var Mode: DWORD;
begin
  inherited Create;
  FInput := GetStdHandle(STD_INPUT_HANDLE); FOutput := GetStdHandle(STD_ERROR_HANDLE);
  AcquireSignalWait; FOwnsSignals := True;
  UseTerminalLocale;
  FEncoder := TConsoleKeyEncoder.Create;
  FConsole := GetConsoleMode(FInput, FInputMode);
  if not FConsole then Exit;
  FInputCP := GetConsoleCP; FOutputCP := GetConsoleOutputCP;
  // ReadConsoleInputW delivers physical key/resize events. Do not let the
  // console edit, echo, translate Ctrl+C, or pause on Quick Edit selection.
  Mode := FInputMode and not (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT or ENABLE_PROCESSED_INPUT or EnableQuickEdit or EnableVTInput);
  Mode := Mode or ENABLE_WINDOW_INPUT or EnableExtended;
  if not SetConsoleMode(FInput, Mode) then RaiseSystemError('Could not enable Windows terminal editing', GetLastError);
  FInputChanged := True;
  if GetConsoleMode(FOutput, FOutputMode) and (GetEnvironmentVariable('TERM') <> 'dumb') then
    if SetConsoleMode(FOutput, FOutputMode or ENABLE_PROCESSED_OUTPUT or EnableVT) then
    begin FOutputChanged := True; FRawMode := True; end;
  FCodePagesChanged := True;
  if not SetConsoleCP(CP_UTF8) or not SetConsoleOutputCP(CP_UTF8) then
    RaiseSystemError('Could not enable UTF-8 terminal code pages', GetLastError);
end;
destructor TPlatformRawTerminalSession.Destroy;
begin
  if FInputChanged then SetConsoleMode(FInput, FInputMode);
  if FOutputChanged then SetConsoleMode(FOutput, FOutputMode);
  if FCodePagesChanged then begin SetConsoleCP(FInputCP); SetConsoleOutputCP(FOutputCP); end;
  FEncoder.Free;
  if FOwnsSignals then ReleaseSignalWait;
  inherited Destroy;
end;
function TPlatformRawTerminalSession.GetReady: Boolean;
begin Result := (FInput <> 0) and (FInput <> INVALID_HANDLE_VALUE); end;
function TPlatformRawTerminalSession.GetRawMode: Boolean;
begin Result := FRawMode; end;
function TPlatformRawTerminalSession.Pop(var Buffer; Size: SizeUInt): SizeInt;
begin
  Result := Length(FPending); if SizeUInt(Result) > Size then Result := Size;
  if Result > 0 then begin Move(FPending[1], Buffer, Result); Delete(FPending, 1, Result); end;
end;
function TPlatformRawTerminalSession.ReadRedirected(var Buffer; Size: SizeUInt; Timeout: Integer): SizeInt;
var Available, Count, Error: DWORD; Started: QWord;
begin
  Started := GetTickCount64;
  repeat
    CheckSessionInterrupt;
    if SessionEnding then Exit(0);
    if GetFileType(FInput) = FILE_TYPE_PIPE then
    begin
      if not PeekNamedPipe(FInput, nil, 0, nil, @Available, nil) then
      begin
        Error := GetLastError;
        if Error = ERROR_BROKEN_PIPE then Exit(0);
        RaiseSystemError('Could not inspect redirected input', Error);
      end;
      if Available = 0 then
      begin
        if (Timeout >= 0) and (GetTickCount64 - Started >= QWord(Timeout)) then Exit(0);
        WaitForSingleObject(SignalWaitHandle, 20); Continue;
      end;
      if Size > Available then Size := Available;
    end;
    if Size > High(LongInt) then Size := High(LongInt);
    if not Windows.ReadFile(FInput, Buffer, DWORD(Size), Count, nil) then
    begin
      Error := GetLastError;
      if Error in [ERROR_BROKEN_PIPE, ERROR_HANDLE_EOF] then Exit(0);
      RaiseSystemError('Could not read redirected input', Error);
    end;
    Exit(Count);
  until False;
end;
function TPlatformRawTerminalSession.ReadInput(var Buffer; Size: SizeUInt; Timeout: Integer): SizeInt;
var Handles: array[0..1] of THandle; RecordData: TInputRecord; Count, Waited, Milliseconds: DWORD;
  Started: QWord; Keys: string; Index, Offset: Integer;
begin
  if Size = 0 then Exit(0);
  CheckSessionInterrupt; if SessionEnding then Exit(0);
  if FPending <> '' then Exit(Pop(Buffer, Size));
  if not FConsole then Exit(ReadRedirected(Buffer, Size, Timeout));
  Handles[0] := SignalWaitHandle; Handles[1] := FInput; Started := GetTickCount64;
  repeat
    CheckSessionInterrupt; if SessionEnding then Exit(0);
    if Timeout < 0 then Milliseconds := INFINITE
    else
    begin
      if GetTickCount64 - Started >= QWord(Timeout) then Milliseconds := 0
      else Milliseconds := Timeout - (GetTickCount64 - Started);
    end;
    Waited := WaitForMultipleObjects(2, @Handles[0], False, Milliseconds);
    if Waited = WAIT_TIMEOUT then Exit(0);
    if Waited = WAIT_FAILED then RaiseSystemError('Could not wait for Windows terminal input', GetLastError);
    if Waited = WAIT_OBJECT_0 then
    begin
      CheckSessionInterrupt; if SessionEnding then Exit(0);
      // Child-owned interrupts are consumed by the CLI after the child exits.
      ConsumeChildInterrupt; Continue;
    end;
    if not ReadConsoleInputW(FInput, RecordData, 1, Count) then RaiseSystemError('Could not read Windows terminal input', GetLastError);
    if Count = 0 then Continue;
    if RecordData.EventType = WINDOW_BUFFER_SIZE_EVENT then
    begin if FRawMode then Exit(TerminalResized) else Continue; end;
    if RecordData.EventType <> KEY_EVENT then Continue;
    Keys := FEncoder.Encode(RecordData.Event.KeyEvent);
    if FRawMode then
    begin FPending := Keys; if FPending <> '' then Exit(Pop(Buffer, Size)); end
    else
    begin
      if (Keys <> '') and (Keys[1] = #27) then Continue;
      for Index := 1 to Length(Keys) do
        case Keys[Index] of
          #3: raise ECommandCancelled.Create('Command cancelled.');
          #4, #26: if FPlain = '' then Exit(0);
          #8, #127:
            if FPlain <> '' then
            begin
              Offset := Length(FPlain);
              while (Offset > 1) and (FPlain[Offset] in [#$80..#$BF]) do Dec(Offset);
              Delete(FPlain, Offset, MaxInt); Write(StdErr, #8' '#8); Flush(StdErr);
            end;
          #10, #13:
            begin FPending := FPlain + #10; FPlain := ''; WriteLn(StdErr); Flush(StdErr); Exit(Pop(Buffer, Size)); end;
          #9: begin FPlain := FPlain + #9; Write(StdErr, #9); Flush(StdErr); end;
          #27: ; // Navigation is unavailable without VT rendering; never insert escapes.
          ' '..#126, #128..#255:
            begin FPlain := FPlain + Keys[Index]; Write(StdErr, Keys[Index]); Flush(StdErr); end;
        end;
    end;
  until False;
end;
procedure TPlatformRawTerminalSession.Suspend;
begin
  // Windows has no Unix terminal job-control suspension. Ctrl+Z is ignored in
  // the raw editor; Ctrl+D remains the shared editor's empty-line EOF shortcut.
end;
procedure TPlatformRawTerminalSession.ResumeEditing;
begin end;
procedure TPlatformRawTerminalSession.FinishLine;
begin
  if not SessionEnding then begin WriteLn(StdErr); Flush(StdErr); end;
end;
procedure TPlatformRawTerminalSession.GetSize(out Columns, Rows: Integer);
begin ScuPlatformTerminalWindows.TerminalSize(FOutput, Columns, Rows); end;
var RedirectedBuffer: string; RedirectedHandle: THandle;
function ReadRedirectedCommandLine(out Line: string): Boolean;
var Session: TPlatformRawTerminalSession; Buffer: array[0..4095] of Char; Count, Ending: SizeInt;
begin
  Line := '';
  if RedirectedHandle <> GetStdHandle(STD_INPUT_HANDLE) then
  begin RedirectedBuffer := ''; RedirectedHandle := GetStdHandle(STD_INPUT_HANDLE); end;
  Session := TPlatformRawTerminalSession.Create;
  try
    repeat
      CheckSessionInterrupt; if SessionEnding then Exit(False);
      Ending := Pos(#10, RedirectedBuffer);
      if Ending > 0 then
      begin
        Line := Copy(RedirectedBuffer, 1, Ending - 1); Delete(RedirectedBuffer, 1, Ending);
        if (Line <> '') and (Line[Length(Line)] = #13) then SetLength(Line, Length(Line) - 1);
        Exit(True);
      end;
      Count := Session.ReadInput(Buffer, SizeOf(Buffer), -1);
      if Count = 0 then
      begin Result := RedirectedBuffer <> ''; Line := RedirectedBuffer; RedirectedBuffer := ''; Exit; end;
      SetString(Line, PChar(@Buffer[0]), Count); RedirectedBuffer := RedirectedBuffer + Line; Line := '';
    until False;
  finally Session.Free; end;
end;
end.
