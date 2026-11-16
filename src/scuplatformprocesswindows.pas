unit ScuPlatformProcessWindows;
{$mode objfpc}{$H+}
interface
uses ScuProcessTypes;
function RunWindowsChild(Request: TChildProcessRequest; Options: TChildProcessOptions = []): Integer;
implementation
uses Windows, SysUtils, Classes, ScuErrors, ScuLockTypes, ScuPlatformPathsWindows,
  ScuPlatformProcessStringsWindows, ScuPlatformProcessHandlesWindows,
  ScuPlatformProcessJobWindows, ScuPlatformBuildLeaseWindows, ScuPlatformLockInterruptWindows;
function RunWindowsChild(Request: TChildProcessRequest; Options: TChildProcessOptions): Integer;
var
  Job: TProcessJob;
  Lease: TBuildLeaseServer;
  Overrides: TStringList;
  Handles: TChildHandles;
  Interrupt: TLockInterruptScope;
  Info: TStartupInfoExtended;
  Process: TProcessInformation;
  Application, CommandLine, Directory, Environment: UnicodeString;
  Executable: string;
  Status, Waited, CreationFlags: DWORD;
  DirectoryPointer: PWideChar;
  Started, Cancelled, Contained: Boolean;
  Deadline: QWord;
  procedure Check;
  begin
    if cpHandlesInterrupt in Options then Interrupt.Consume else Interrupt.Check;
    if Assigned(Request.CheckInterrupt) then Request.CheckInterrupt();
  end;
begin
  FillChar(Process, SizeOf(Process), 0);
  Job := nil; Lease := nil; Handles := nil; Interrupt := nil; Overrides := nil;
  Started := False; Contained := False; Cancelled := False; Deadline := 0;
  try
    Interrupt := TLockInterruptScope.Create;
    Check;
    Executable := ResolveWindowsExecutable(Request.Executable);
    Application := UTF8Decode(Executable);
    if Request.ShellCommand = '' then CommandLine := WindowsCommandLine(Executable, Request.Arguments)
    else
    begin
      if Pos(#0, Request.ShellCommand) <> 0 then raise EScuError.Create('NUL is not allowed in a build command.');
      CommandLine := QuoteWindowsArgument(Executable) + ' /D /S /C "' + UTF8Decode(Request.ShellCommand) + '"';
      if Length(CommandLine) >= 32767 then raise EScuError.Create('Windows build command line is too long.');
    end;
    Job := TProcessJob.Create;
    Overrides := TStringList.Create; Overrides.Assign(Request.Environment);
    if Request.OutputLock <> THandle(-1) then
    begin
      Lease := TBuildLeaseServer.Create(Request.OutputLock, Job.Handle);
      Overrides.Values[WindowsBuildLeaseVariable] := Lease.Endpoint;
      Overrides.Values[BuildOutputLockVariable] := '';
    end;
    Environment := WindowsEnvironment(Overrides);
    DirectoryPointer := nil;
    if Request.WorkingDirectory <> '' then
    begin Directory := UTF8Decode(AbsolutePath(Request.WorkingDirectory)); DirectoryPointer := PWideChar(Directory); end;
    Handles := TChildHandles.Create(Request.NullInput);
    Info := Handles.Info;
    Check;
    // Assign to the job before user code executes. Inherit only the three
    // explicit standard-stream duplicates, never library/output lock handles.
    CreationFlags := CREATE_SUSPENDED or CREATE_UNICODE_ENVIRONMENT or $80000;
    if not (cpHandlesInterrupt in Options) then CreationFlags := CreationFlags or CREATE_NEW_PROCESS_GROUP;
    if not CreateProcessW(PWideChar(Application), PWideChar(CommandLine), nil, nil, True,
      CreationFlags,
      PWideChar(Environment), DirectoryPointer, @Info.Startup, @Process) then
      RaiseSystemError('Could not start "' + Request.Executable + '"', GetLastError);
    Started := True;
    Job.Assign(Process.hProcess); Contained := True;
    Check;
    if ResumeThread(Process.hThread) = DWORD(-1) then RaiseSystemError('Could not resume child process', GetLastError);
    repeat
      Waited := WaitForSingleObject(Process.hProcess, 10);
      if Waited = WAIT_OBJECT_0 then Break;
      if Waited = WAIT_FAILED then RaiseSystemError('Could not wait for child process', GetLastError);
      if Assigned(Lease) then Lease.Poll;
      if not Cancelled then
      begin
        try Check;
        except
          on E: ECommandCancelled do
          begin
            Cancelled := True; Deadline := GetTickCount64 + 1500;
            // Best effort when sharing a console. Job termination remains the
            // fallback for GUI/no-console and uncooperative descendants.
            GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, Process.dwProcessId);
          end;
        end;
      end
      else if GetTickCount64 >= Deadline then
      begin Job.TerminateAndWait; Break; end;
    until False;
    if not GetExitCodeProcess(Process.hProcess, Status) then RaiseSystemError('Could not read child exit status', GetLastError);
    // Retire the entire job, including background children, before the caller
    // can release the output lock. No build lease survives this operation.
    Lease.Free; Lease := nil;
    Job.TerminateAndWait;
    if Cancelled then raise ECommandCancelled.Create('Command cancelled.');
    Result := Integer(Status);
  finally
    try
      if Started then
      begin
        if Contained then Job.TerminateAndWait
        else begin TerminateProcess(Process.hProcess, 1); WaitForSingleObject(Process.hProcess, INFINITE); end;
      end;
    finally
      Lease.Free;
      if Process.hThread <> 0 then CloseHandle(Process.hThread);
      if Process.hProcess <> 0 then CloseHandle(Process.hProcess);
      Handles.Free; Overrides.Free; Job.Free; Interrupt.Free;
    end;
  end;
end;
end.
