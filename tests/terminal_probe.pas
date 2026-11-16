program TerminalProbe;
{$mode objfpc}{$H+}
uses Classes, SysUtils, ScuLineEditor, ScuTerminalSession, ScuTerminal, ScuHistory,
  ScuSignals, ScuErrors, ScuFiles, ScuLocks, ScuInput, ScuPlatformPaths, ScuOutput
  {$IFDEF WINDOWS}, Windows, ScuPlatformTerminalKeysWindows, ScuPlatformSignalsWindows, ScuPlatformPathsWindows{$ENDIF};
{$IFDEF WINDOWS}
type TWideArgs = array[0..65535] of PWideChar; PWideArgs = ^TWideArgs;
function WideArgs(Text: PWideChar; out Count: Integer): PWideArgs; stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
{$ENDIF}
function Arg(Index: Integer): string;
{$IFDEF WINDOWS}
var Args: PWideArgs; Count: Integer;
begin Args := WideArgs(GetCommandLineW, Count);
  try if Index < Count then Result := UTF8Encode(UnicodeString(Args^[Index])) else Result := '';
  finally LocalFree(HLOCAL(Args)); end;
end;
{$ELSE}
begin Result := ParamStr(Index); end;
{$ENDIF}
function Decode(const Hex: string): string;
var Index: Integer;
begin
  Result := ''; for Index := 1 to Length(Hex) div 2 do Result := Result + Char(StrToInt('$' + Copy(Hex, Index * 2 - 1, 2)));
end;
procedure Encoded(const Name, Value: string);
var Index: Integer;
begin Write(Name, '='); for Index := 1 to Length(Value) do Write(IntToHex(Ord(Value[Index]), 2)); WriteLn; end;
type
  TReplaySession = class(TTerminalSession)
  private
    FActions: TStringList; FNext: Integer; FBytes: string;
    {$IFDEF WINDOWS}FEncoder: TConsoleKeyEncoder;{$ENDIF}
    function EncodeText(const Text: string): string;
    function EncodeKey(const Name: string): string;
  protected
    function GetReady: Boolean; override;
    function GetRawMode: Boolean; override;
  public
    constructor Create(const Path: string);
    destructor Destroy; override;
    function ReadInput(var Buffer; Size: SizeUInt; Timeout: Integer): SizeInt; override;
    procedure Suspend; override;
    procedure ResumeEditing; override;
    procedure FinishLine; override;
    procedure GetSize(out Columns, Rows: Integer); override;
    procedure Complete(const Before, Prefix, After: string; Candidates: TStrings; out AppendCharacter: Char);
  end;
constructor TReplaySession.Create(const Path: string);
begin
  inherited Create; FActions := TStringList.Create; FActions.Text := ReadBytes(Path, 1024*1024);
  {$IFDEF WINDOWS}FEncoder := TConsoleKeyEncoder.Create;{$ENDIF}
end;
destructor TReplaySession.Destroy;
begin FActions.Free; {$IFDEF WINDOWS}FEncoder.Free;{$ENDIF} inherited Destroy; end;
function TReplaySession.GetReady: Boolean;
begin Result := True; end;
function TReplaySession.GetRawMode: Boolean;
begin Result := True; end;
procedure TReplaySession.Suspend;
begin end;
procedure TReplaySession.ResumeEditing;
begin end;
procedure TReplaySession.FinishLine;
begin end;
procedure TReplaySession.GetSize(out Columns, Rows: Integer);
begin Columns := 32; Rows := 4; end;
function TReplaySession.EncodeText(const Text: string): string;
{$IFDEF WINDOWS}
var Wide: UnicodeString; Key: TKeyEventRecord; Index: Integer;
begin
  Result := ''; Wide := UTF8Decode(Text);
  for Index := 1 to Length(Wide) do
  begin
    FillChar(Key, SizeOf(Key), 0); Key.bKeyDown := True; Key.wRepeatCount := 1; Key.UnicodeChar := Wide[Index];
    Result := Result + FEncoder.Encode(Key);
  end;
end;
{$ELSE}
begin Result := Text; end;
{$ENDIF}
{$IFDEF WINDOWS}
procedure NativeKey(const Name: string; out Key: TKeyEventRecord);
begin
  FillChar(Key, SizeOf(Key), 0); Key.bKeyDown := True; Key.wRepeatCount := 1;
  if Name = 'LEFT' then Key.wVirtualKeyCode := VK_LEFT
  else if Name = 'RIGHT' then Key.wVirtualKeyCode := VK_RIGHT
  else if Name = 'UP' then Key.wVirtualKeyCode := VK_UP
  else if Name = 'DOWN' then Key.wVirtualKeyCode := VK_DOWN
  else if Name = 'HOME' then Key.wVirtualKeyCode := VK_HOME
  else if Name = 'END' then Key.wVirtualKeyCode := VK_END
  else if Name = 'DELETE' then Key.wVirtualKeyCode := VK_DELETE
  else if Name = 'BACK' then Key.wVirtualKeyCode := VK_BACK
  else if Name = 'ENTER' then Key.wVirtualKeyCode := VK_RETURN
  else if Name = 'TAB' then Key.wVirtualKeyCode := VK_TAB
  else if Name = 'CTRL_LEFT' then begin Key.wVirtualKeyCode := VK_LEFT; Key.dwControlKeyState := LEFT_CTRL_PRESSED; end
  else if Copy(Name, 1, 5) = 'CTRL_' then
  begin Key.wVirtualKeyCode := Ord(Name[6]); Key.dwControlKeyState := LEFT_CTRL_PRESSED; end;
end;
{$ENDIF}
function TReplaySession.EncodeKey(const Name: string): string;
{$IFDEF WINDOWS}var Key: TKeyEventRecord;{$ENDIF}
begin
  Result := '';
  {$IFDEF WINDOWS}
  NativeKey(Name, Key);
  Result := FEncoder.Encode(Key);
  {$ELSE}
  if Name = 'LEFT' then Result := #27'[D' else if Name = 'RIGHT' then Result := #27'[C'
  else if Name = 'UP' then Result := #27'[A' else if Name = 'DOWN' then Result := #27'[B'
  else if Name = 'HOME' then Result := #27'[H' else if Name = 'END' then Result := #27'[F'
  else if Name = 'DELETE' then Result := #27'[3~' else if Name = 'BACK' then Result := #127
  else if Name = 'ENTER' then Result := #13 else if Name = 'TAB' then Result := #9
  else if Name = 'CTRL_LEFT' then Result := #27'b'
  else if Copy(Name, 1, 5) = 'CTRL_' then Result := Char(Ord(Name[6]) - Ord('A') + 1);
  {$ENDIF}
end;
function TReplaySession.ReadInput(var Buffer; Size: SizeUInt; Timeout: Integer): SizeInt;
var Action: string;
begin
  CheckSessionInterrupt;
  while FBytes = '' do
  begin
    if FNext >= FActions.Count then Exit(0);
    Action := FActions[FNext]; Inc(FNext);
    if Copy(Action, 1, 5) = 'text ' then FBytes := EncodeText(Decode(Copy(Action, 6, MaxInt)))
    else if Copy(Action, 1, 4) = 'key ' then FBytes := EncodeKey(Copy(Action, 5, MaxInt))
    else if Action = 'resize' then Exit(TerminalResized)
    else if Action = 'signal' then begin NoteSessionSignal(SignalInterrupt); CheckSessionInterrupt; end;
  end;
  Result := Length(FBytes); if SizeUInt(Result) > Size then Result := Size;
  Move(FBytes[1], Buffer, Result); Delete(FBytes, 1, Result);
end;
procedure TReplaySession.Complete(const Before, Prefix, After: string; Candidates: TStrings; out AppendCharacter: Char);
var Index: Integer;
begin
  AppendCharacter := ' ';
  if Prefix = 'disd' then Candidates.Add('display_deck')
  else if Copy(Prefix, 1, 7) = 'choice_' then
    for Index := 1 to 30 do Candidates.Add('choice_' + Format('%.2d', [Index]));
end;
{$IFDEF WINDOWS}
type
  TConsoleInjector = class(TThread)
  private FInput: THandle; FScript: TStringList; FError: string;
    procedure Send(var RecordData: TInputRecord);
  protected procedure Execute; override;
  public
    constructor Create(InputHandle: THandle; const Script: string);
    destructor Destroy; override;
    property Error: string read FError;
  end;
constructor TConsoleInjector.Create(InputHandle: THandle; const Script: string);
begin
  inherited Create(True); FInput := InputHandle;
  FScript := TStringList.Create; FScript.Text := ReadBytes(Script, 1024*1024);
end;
destructor TConsoleInjector.Destroy;
begin FScript.Free; inherited Destroy; end;
procedure TConsoleInjector.Send(var RecordData: TInputRecord);
var Count: DWORD;
begin
  if not WriteConsoleInputW(FInput, RecordData, 1, Count) or (Count <> 1) then RaiseLastOSError;
end;
procedure TConsoleInjector.Execute;
var Action: string; Wide: UnicodeString; Index: Integer; RecordData: TInputRecord;
begin
  try
    Sleep(100);
    for Action in FScript do
    begin
      FillChar(RecordData, SizeOf(RecordData), 0); RecordData.EventType := KEY_EVENT;
      RecordData.Event.KeyEvent.bKeyDown := True; RecordData.Event.KeyEvent.wRepeatCount := 1;
      if Copy(Action, 1, 5) = 'text ' then
      begin
        Wide := UTF8Decode(Decode(Copy(Action, 6, MaxInt)));
        for Index := 1 to Length(Wide) do
        begin RecordData.Event.KeyEvent.UnicodeChar := Wide[Index]; Send(RecordData); end;
      end
      else if Copy(Action, 1, 4) = 'key ' then
      begin NativeKey(Copy(Action, 5, MaxInt), RecordData.Event.KeyEvent); Send(RecordData); end;
    end;
  except
    on E: Exception do
    begin
      FError := E.Message; FillChar(RecordData, SizeOf(RecordData), 0); RecordData.EventType := KEY_EVENT;
      RecordData.Event.KeyEvent.bKeyDown := True; RecordData.Event.KeyEvent.UnicodeChar := #3;
      RecordData.Event.KeyEvent.wRepeatCount := 1; WriteConsoleInputW(FInput, RecordData, 1, DWORD(Index));
    end;
  end;
end;
procedure SpecialKeys;
var Encoder: TConsoleKeyEncoder; Key: TKeyEventRecord;
begin
  Encoder := TConsoleKeyEncoder.Create;
  try
    FillChar(Key, SizeOf(Key), 0); Key.bKeyDown := True; Key.wRepeatCount := 3; Key.UnicodeChar := 'a';
    Encoded('repeat', Encoder.Encode(Key)); Key.bKeyDown := False; Encoded('release', Encoder.Encode(Key));
    Key.bKeyDown := True; Key.wRepeatCount := 1; Key.UnicodeChar := WideChar($20AC);
    Key.dwControlKeyState := RIGHT_ALT_PRESSED or LEFT_CTRL_PRESSED; Encoded('altgr', Encoder.Encode(Key));
    Key.dwControlKeyState := LEFT_ALT_PRESSED; Key.UnicodeChar := 'b'; Encoded('alt', Encoder.Encode(Key));
    Key.dwControlKeyState := 0; Key.UnicodeChar := WideChar($D83D); Encoder.Encode(Key);
    Key.UnicodeChar := #0; Key.wVirtualKeyCode := VK_SHIFT; Encoder.Encode(Key);
    Key.wVirtualKeyCode := 0; Key.UnicodeChar := WideChar($DE00); Encoded('pair', Encoder.Encode(Key));
    Key.UnicodeChar := WideChar($DC00); Encoded('unpaired', Encoder.Encode(Key));
  finally Encoder.Free; end;
end;
function ConvertTestSecurity(Text: PWideChar; Revision: DWORD; out Descriptor: PSecurityDescriptor; Size: Pointer): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';
procedure MakeUnsafeState(const Directory: string);
var Descriptor: PSecurityDescriptor;
begin
  if not ConvertTestSecurity('D:P(A;;FA;;;WD)', 1, Descriptor, nil) then RaiseLastOSError;
  try
    if not SetFileSecurityW(PWideChar(NativeFilePath(Directory)), DACL_SECURITY_INFORMATION, Descriptor) then RaiseLastOSError;
  finally LocalFree(HLOCAL(Descriptor)); end;
end;
type TSignalTimer = class(TThread)
  protected procedure Execute; override;
end;
procedure TSignalTimer.Execute;
begin Sleep(150); NoteSessionSignal(SignalInterrupt); end;
procedure NativeConsole(const Script: string; History: TStrings);
var InputHandle, OutputHandle, OldInput, OldError, OldTextError: THandle;
  InputMode, OutputMode, AfterMode, InputCP, OutputCP: DWORD;
  Session: TRawTerminalSession; Injector: TConsoleInjector; Completion: TReplaySession; Line: string;
begin
  InputHandle := CreateFileW('CONIN$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  OutputHandle := CreateFileW('CONOUT$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if (InputHandle = INVALID_HANDLE_VALUE) or (OutputHandle = INVALID_HANDLE_VALUE) then
  begin
    if InputHandle <> INVALID_HANDLE_VALUE then CloseHandle(InputHandle);
    if OutputHandle <> INVALID_HANDLE_VALUE then CloseHandle(OutputHandle);
    raise EScuError.Create('Native console unavailable.');
  end;
  OldInput := GetStdHandle(STD_INPUT_HANDLE); OldError := GetStdHandle(STD_ERROR_HANDLE);
  OldTextError := TTextRec(StdErr).Handle;
  Session := nil; Injector := nil; Completion := nil;
  try
    if not GetConsoleMode(InputHandle, InputMode) or not GetConsoleMode(OutputHandle, OutputMode) then RaiseLastOSError;
    InputCP := GetConsoleCP; OutputCP := GetConsoleOutputCP;
    Flush(StdErr); SetStdHandle(STD_INPUT_HANDLE, InputHandle); SetStdHandle(STD_ERROR_HANDLE, OutputHandle);
    TTextRec(StdErr).Handle := OutputHandle;
    FlushConsoleInputBuffer(InputHandle);
    try
      Session := TRawTerminalSession.Create;
      if not Session.Ready or not Session.RawMode then raise EScuError.Create('Native VT console unavailable.');
      Completion := TReplaySession.Create(Script);
      Injector := TConsoleInjector.Create(InputHandle, Script); Injector.Start;
      try
        if ReadTerminalLineWithSession('scu> ', History, @Completion.Complete, Session, Line) then Encoded('line', Line) else WriteLn('eof');
      finally
        Injector.WaitFor;
        if Injector.Error <> '' then raise EScuError.Create(Injector.Error);
      end;
    finally
      Injector.Free; Completion.Free; Session.Free;
      if not GetConsoleMode(InputHandle, AfterMode) or (AfterMode <> InputMode) then raise EScuError.Create('Console input mode was not restored.');
      if not GetConsoleMode(OutputHandle, AfterMode) or (AfterMode <> OutputMode) then raise EScuError.Create('Console output mode was not restored.');
      if (GetConsoleCP <> InputCP) or (GetConsoleOutputCP <> OutputCP) then raise EScuError.Create('Console code pages were not restored.');
      WriteLn('console-restored');
    end;
  finally
    Flush(StdErr); TTextRec(StdErr).Handle := OldTextError;
    SetStdHandle(STD_INPUT_HANDLE, OldInput); SetStdHandle(STD_ERROR_HANDLE, OldError);
    CloseHandle(InputHandle); CloseHandle(OutputHandle);
  end;
end;
{$ENDIF}
var Previous: TSessionSignalHandlers; History: TCommandHistory; Replay: TReplaySession;
  {$IFDEF WINDOWS}Timer: TSignalTimer; State: array[0..32767] of WideChar; StateLength: DWORD;{$ENDIF}
  Line, Mode: string; Bytes: RawByteString; OutputStream: TTerminalOutput; Index, Ending: SizeInt; Lock: TFileLock;
begin
  {$IFDEF WINDOWS}
  StateLength := GetEnvironmentVariableW('SCU_TEST_STATE', @State[0], Length(State));
  if (StateLength > 0) and (StateLength < Length(State)) then SetEnvironmentVariableW('LOCALAPPDATA', @State[0]);
  {$ENDIF}
  InitializePlatformPaths; UseTerminalLocale; StartSessionSignals(Previous);
  try
    try
      Mode := Arg(1);
      if (Mode = 'editor') or (Mode = 'native') or (Mode = 'native-console') then
      begin
        History := TCommandHistory.Create;
        try
          History.Load;
          {$IFDEF WINDOWS}
          if Mode = 'native-console' then NativeConsole(Arg(2), History.Entries)
          else
          {$ENDIF}
          if Mode = 'editor' then
          begin
            Replay := TReplaySession.Create(Arg(2));
            try
              if ReadTerminalLineWithSession('scu> ', History.Entries, @Replay.Complete, Replay, Line) then
              begin Encoded('line', Line); History.Remember(Line); end else WriteLn('eof');
            finally Replay.Free; end;
          end
          else if ReadCommandLine('scu> ', Line, nil, History) then Encoded('line', Line) else WriteLn('eof');
        finally History.Free; end;
      end
      else if Mode = 'history-add' then
      begin History := TCommandHistory.Create; try History.Load; History.Remember(Arg(2)); finally History.Free; end; end
      else if Mode = 'hold-lock' then
      begin Lock := TFileLock.Create(Arg(2)); try WriteLn('locked'); Flush(Output); ReadLn(Line); finally Lock.Free; end; end
      {$IFDEF WINDOWS}
      else if Mode = 'unsafe-state' then MakeUnsafeState(Arg(2))
      else if Mode = 'history-cancel' then
      begin
        History := TCommandHistory.Create; Timer := nil;
        try History.Load; Timer := TSignalTimer.Create(False); History.Remember('not-saved');
        finally if Assigned(Timer) then begin Timer.WaitFor; Timer.Free; end; History.Free; end;
      end
      {$ENDIF}
      else if Mode = 'history' then
      begin
        History := TCommandHistory.Create;
        try History.Load; for Index := 0 to History.Entries.Count - 1 do Encoded('history', History.Entries[Index]); finally History.Free; end;
      end
      else if Mode = 'output' then
      begin
        SetLength(Bytes, 256); for Index := 0 to 255 do Bytes[Index + 1] := Char(Index);
        OutputStream := TTerminalOutput.Create;
        try OutputStream.Write(Bytes); OutputStream.WriteLine('end'); OutputStream.Flush; finally OutputStream.Free; end;
      end
      {$IFDEF WINDOWS}
      else if Mode = 'special-keys' then SpecialKeys
      {$ENDIF}
      else if Mode = 'width' then
      begin
        Line := Arg(2); Index := 0;
        while Index < Length(Line) do begin Ending := NextCharacter(Line, Index); WriteLn(CellWidth(Line, Index, Ending)); Index := Ending; end;
      end
      else if Mode = 'signals' then
      begin
        NoteSessionSignal(SignalInterrupt);
        try CheckSessionInterrupt; except on E: ECommandCancelled do WriteLn('cancelled'); end;
        WriteLn('clear=', Ord(ClearInterrupt), ' pending=', PendingSignal);
        NoteSessionSignal(SignalTerminate); NoteSessionSignal(SignalInterrupt);
        WriteLn('ending=', Ord(SessionEnding), ' clear=', Ord(ClearInterrupt), ' pending=', PendingSignal);
      end
      else if Mode = 'scope' then
      begin
        NoteSessionSignal(SignalInterrupt);
        try Lock := TFileLock.Create(Arg(2), nil, @CheckSessionInterrupt); Lock.Free;
        except on E: ECommandCancelled do WriteLn('cancelled'); end;
        WriteLn('pending=', PendingSignal, ' clear=', Ord(ClearInterrupt));
        Lock := TFileLock.Create(Arg(2), nil, @CheckSessionInterrupt); Lock.Free; WriteLn('reacquired');
      end
      {$IFDEF WINDOWS}
      else if Mode = 'batch-cancel' then
      begin
        Timer := TSignalTimer.Create(False);
        try WriteLn('ready'); Flush(Output); ReadCommandLine('', Line);
        finally Timer.WaitFor; Timer.Free; end;
      end
      {$ENDIF}
      else if Mode = 'batch' then
      begin while ReadCommandLine('', Line) do Encoded('line', Line); end
      else raise EScuError.Create('Unknown terminal probe mode.');
    except on E: Exception do begin WriteLn(StdErr, E.Message); ExitCode := 1; end; end;
  finally RestoreSessionSignals(Previous); end;
end.
