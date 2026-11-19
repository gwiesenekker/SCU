program ProcessProbe;
{$mode objfpc}{$H+}
uses Classes, SysUtils, ScuBuild, ScuBuildTypes, ScuProcessTypes, ScuOutputLock,
  ScuFiles, ScuErrors, ScuPlatformPaths
  {$IFDEF WINDOWS}, Windows, ScuPlatformProcessWindows, ScuPlatformProcessStringsWindows
  {$ELSE}, Process, BaseUnix, ScuProcess, ScuSignals{$ENDIF};
{$IFDEF WINDOWS}
type TWideArgs = array[0..65535] of PWideChar; PWideArgs = ^TWideArgs;
function WideArgs(Text: PWideChar; out Count: Integer): PWideArgs; stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
{$ENDIF}
function Arg(Index: Integer): string;
{$IFDEF WINDOWS}
var Args: PWideArgs; Count: Integer;
begin
  Args := WideArgs(GetCommandLineW, Count);
  try if Index < Count then Result := UTF8Encode(UnicodeString(Args^[Index])) else Result := '';
  finally LocalFree(HLOCAL(Args)); end;
end;
{$ELSE}
begin Result := ParamStr(Index); end;
{$ENDIF}
function ArgCount: Integer;
{$IFDEF WINDOWS}
var Args: PWideArgs; Count: Integer;
begin Args := WideArgs(GetCommandLineW, Count); LocalFree(HLOCAL(Args)); Result := Count - 1; end;
{$ELSE}
begin Result := ParamCount; end;
{$ENDIF}
procedure HexLine(const Name, Value: string);
var Index: Integer;
begin
  Write(Name, '='); for Index := 1 to Length(Value) do Write(IntToHex(Ord(Value[Index]), 2)); WriteLn;
end;
function Env(const Name: string): string;
begin Result := {$IFDEF WINDOWS}WindowsEnvironmentValue{$ELSE}GetEnvironmentVariable{$ENDIF}(Name); end;
function ShellQuote(const Value: string): string;
begin
  {$IFDEF WINDOWS}Result := UTF8Encode(QuoteWindowsArgument(Value));
  {$ELSE}Result := '''' + StringReplace(Value, '''', '''"''"''', [rfReplaceAll]) + '''';{$ENDIF}
end;
{$IFNDEF WINDOWS}
type TProbeProcess = class(TProcess)
    procedure Prepare(Sender: TObject);
  end;
procedure TProbeProcess.Prepare(Sender: TObject);
var InputHandle: cint;
begin
  InputHandle := fpOpen('/dev/null', O_RDONLY); fpDup2(InputHandle, 0); fpClose(InputHandle);
  StartBuildProcessGroup;
end;
{$ENDIF}
var CancelAt: QWord; ConsoleCancel: Boolean; CancelMarker: string;
procedure Check;
begin
  if (CancelMarker <> '') and FileExists(CancelMarker) then
  begin CancelMarker := ''; CancelAt := GetTickCount64 + 100; end;
  if (CancelAt <> 0) and (GetTickCount64 >= CancelAt) then
  begin
    {$IFDEF WINDOWS}
    if ConsoleCancel then
    begin
      CancelAt := 0;
      if not GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) then RaiseLastOSError;
      Exit;
    end;
    {$ENDIF}
    raise ECommandCancelled.Create('Command cancelled.');
  end;
end;
function RunRequest(Request: TChildProcessRequest): Integer;
{$IFDEF WINDOWS}
begin Result := RunWindowsChild(Request, [ScuProcessTypes.cpOwnProcessGroup]); end;
{$ELSE}
var Child: TProbeProcess; Index: Integer; Item: string;
begin
  Child := TProbeProcess.Create(nil);
  try
    Child.Executable := Request.Executable; Child.CurrentDirectory := Request.WorkingDirectory;
    Child.Parameters.Assign(Request.Arguments); Child.OnForkEvent := @Child.Prepare;
    for Index := 1 to GetEnvironmentVariableCount do Child.Environment.Add(GetEnvironmentString(Index));
    for Item in Request.Environment do Child.Environment.Values[Copy(Item, 1, Pos('=', Item)-1)] := Copy(Item, Pos('=', Item)+1, MaxInt);
    Result := ScuProcess.WaitForChild(Child, [ScuProcess.cpOwnProcessGroup]);
  finally Child.Free; end;
end;
{$ENDIF}
procedure Spawn(const Started, Completed: string);
{$IFDEF WINDOWS}
var Info: TStartupInfoW; Child: TProcessInformation; Application, Line: UnicodeString;
begin
  FillChar(Info, SizeOf(Info), 0); Info.cb := SizeOf(Info);
  Application := UTF8Decode(RunningExecutablePath);
  Line := QuoteWindowsArgument(RunningExecutablePath) + ' "linger" ' + QuoteWindowsArgument(Started) + ' ' + QuoteWindowsArgument(Completed);
  if not CreateProcessW(PWideChar(Application), PWideChar(Line), nil, nil, False, 0, nil, nil, @Info, @Child) then RaiseLastOSError;
  CloseHandle(Child.hThread); CloseHandle(Child.hProcess);
end;
{$ELSE}
var Child: TProcess;
begin
  Child := TProcess.Create(nil);
  try
    Child.Executable := RunningExecutablePath; Child.Parameters.Add('linger');
    Child.Parameters.Add(Started); Child.Parameters.Add(Completed); Child.Execute;
  finally Child.Free; end;
end;
{$ENDIF}
var
  Mode, Failure: string; Index, Status: Integer; Buffer: Byte;
  Request: TChildProcessRequest; Build: TBuildRequest; Lock, OtherLock: TOutputDirectoryLock;
  Deadline: QWord;
  {$IFDEF WINDOWS}Secret: THandle; Attributes: TSecurityAttributes;{$ENDIF}
  {$IFNDEF WINDOWS}Previous: TSessionSignalHandlers;{$ENDIF}
begin
  {$IFDEF WINDOWS}SetMultiByteConversionCodePage(CP_UTF8);{$ELSE}StartSessionSignals(Previous);{$ENDIF}
  InitializePlatformPaths;
  try
    try
      Mode := Arg(1);
      if Mode = 'echo' then
      begin
        for Index := 2 to ArgCount do HexLine('arg', Arg(Index));
        HexLine('env', Env('SCU_TEST')); HexLine('cwd', PlatformCanonicalDirectory('.'));
        // GetFullPathName('.') uses wide-character APIs on Windows.
        {$IFDEF WINDOWS}HexLine('directory', PlatformCanonicalDirectory('.'));{$ENDIF}
        WriteLn(StdErr, 'child-stderr');
        if FileRead(TTextRec(Input).Handle, Buffer, 1) = 0 then WriteLn('input-eof');
      end
      else if Mode = 'exit' then Halt(StrToInt(Arg(2)))
      else if Mode = 'linger' then
      begin AtomicWrite(Arg(2), 'started'); Sleep(3000); AtomicWrite(Arg(3), 'escaped'); Sleep(30000); end
      else if (Mode = 'spawn_exit') or (Mode = 'spawn_wait') then
      begin
        Spawn(Arg(2), Arg(3)); Deadline := GetTickCount64 + 5000;
        while not FileExists(Arg(2)) do begin if GetTickCount64 > Deadline then raise Exception.Create('Grandchild did not start.'); Sleep(10); end;
        WriteLn('tree-started'); Flush(Output);
        if Mode = 'spawn_wait' then Sleep(30000);
      end
      else if Mode = 'nested' then
      begin
        Lock := TOutputDirectoryLock.CreateWithBuildLockReuse(Arg(2));
        try AtomicWrite(Arg(3), 'nested'); WriteLn('nested-ok'); finally Lock.Free; end;
      end
      else if Mode = 'lease_wait' then
      begin AtomicWrite(Arg(2), Env('SCU_BUILD_OUTPUT_LEASE')); Sleep(4000); end
      {$IFDEF WINDOWS}
      else if Mode = 'check_handle' then
      begin
        // A child may allocate its own event at the same numeric handle. The
        // parent checks its original event to distinguish reuse from inheritance.
        if SetEvent(THandle(StrToQWord(Arg(2)))) then WriteLn('handle-number-reused') else WriteLn('handle-number-absent');
      end
      else if Mode = 'inheritance' then
      begin
        FillChar(Attributes, SizeOf(Attributes), 0); Attributes.nLength := SizeOf(Attributes); Attributes.bInheritHandle := True;
        Secret := CreateEvent(@Attributes, True, False, nil);
        if Secret = 0 then RaiseLastOSError;
        Request := TChildProcessRequest.Create;
        try
          Request.Executable := RunningExecutablePath; Request.NullInput := True;
          Request.Arguments.Add('check_handle'); Request.Arguments.Add(UIntToStr(Secret));
          if RunRequest(Request) <> 0 then raise Exception.Create('Inheritance child failed.');
          if WaitForSingleObject(Secret, 0) <> WAIT_TIMEOUT then raise Exception.Create('Unrelated handle leaked.');
          WriteLn('handle-isolated');
        finally Request.Free; CloseHandle(Secret); end;
      end
      {$ENDIF}
      else if Mode = 'run' then
      begin
        Request := TChildProcessRequest.Create;
        try
          if Arg(2) = 'self' then Request.Executable := RunningExecutablePath else Request.Executable := Arg(2);
          Request.WorkingDirectory := Arg(3); Request.NullInput := True;
          Request.Environment.Values['SCU_TEST'] := 'override-日本語';
          for Index := 4 to ArgCount do Request.Arguments.Add(Arg(Index));
          Status := RunRequest(Request); WriteLn('status=', Status);
        finally Request.Free; end;
      end
      else if (Mode = 'tree') or (Mode = 'cancel_tree') or (Mode = 'console_tree') or (Mode = 'pre_cancel') then
      begin
        Request := TChildProcessRequest.Create;
        try
          Request.Executable := RunningExecutablePath; Request.NullInput := True;
          if Mode = 'tree' then Request.Arguments.Add('spawn_exit') else Request.Arguments.Add('spawn_wait');
          Request.Arguments.Add(Arg(2)); Request.Arguments.Add(Arg(3));
          if Mode <> 'tree' then
          begin
            ConsoleCancel := Mode = 'console_tree';
            if Mode = 'pre_cancel' then CancelAt := 1 else CancelMarker := Arg(2);
            Request.CheckInterrupt := @Check;
          end;
          Status := RunRequest(Request); WriteLn('status=', Status);
        finally Request.Free; end;
      end
      else if (Mode = 'build') or (Mode = 'lease_wrong') then
      begin
        Lock := TOutputDirectoryLock.Create(Arg(2)); OtherLock := nil;
        try
          Build.Command := Arg(3);
          Build.WorkingDirectory := Arg(2); Build.LibraryPath := Arg(2) + DirectorySeparator + 'library.sqlite';
          Build.OutputPath := Arg(2) + DirectorySeparator + 'out file';
          if Mode = 'lease_wrong' then
          begin
            OtherLock := TOutputDirectoryLock.Create(Arg(3));
            Build.Command := ShellQuote(RunningExecutablePath) + ' nested ' + ShellQuote(Arg(3)) + ' ' + ShellQuote(Arg(4));
          end;
          Failure := RunBuildProcess(Build, False, Lock.BuildHandle);
          if Failure <> '' then raise EScuError.Create(Failure);
        finally OtherLock.Free; Lock.Free; end;
      end
      else raise EScuError.Create('Unknown process probe mode.');
    except
      on E: Exception do begin WriteLn(StdErr, E.Message); ExitCode := 1; end;
    end;
  finally
    {$IFNDEF WINDOWS}RestoreSessionSignals(Previous);{$ENDIF}
  end;
end.
