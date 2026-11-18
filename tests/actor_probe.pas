program ActorProbe;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} Classes, SysUtils, FPJSON,
  ScuAuditActor, ScuAudit, ScuCommand, ScuExecutor, ScuErrors, ScuFiles,
  ScuOutput, ScuPlatformPaths, ScuSQLite
  {$IFDEF WINDOWS}, Windows{$ENDIF};
type EProbeSkip = class(Exception);
{$IFDEF WINDOWS}
function ParseSID(Text: PWideChar; out SID: PSID): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertStringSidToSidW';
function CountHandles(Process: THandle; out Count: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetProcessHandleCount';

function ProcessHandleCount: DWORD;
begin
  if not CountHandles(GetCurrentProcess, Result) then
    RaiseSystemError('Could not count probe handles', GetLastError);
end;

procedure CheckSID(Event: TJSONObject);
var Token: THandle; Buffer: TBytes; Needed: DWORD; SID: PSID; Text: UnicodeString;
begin
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Token) then
    RaiseSystemError('Could not query oracle token', GetLastError);
  try
    Needed := 0; GetTokenInformation(Token, TokenUser, nil, 0, Needed);
    SetLength(Buffer, Needed);
    if not GetTokenInformation(Token, TokenUser, @Buffer[0], Needed, Needed) then
      RaiseSystemError('Could not query oracle identity', GetLastError);
    Text := UTF8Decode(Event.Objects['actor'].Strings['sid']);
    if not ParseSID(PWideChar(Text), SID) then RaiseSystemError('Invalid audit SID', GetLastError);
    try
      if not EqualSid(SID, PTokenUser(@Buffer[0])^.User.Sid) then
        raise EScuError.Create('Audit SID does not identify the process-token user.');
    finally LocalFree(HLOCAL(SID)); end;
  finally CloseHandle(Token); end;
end;
function Impersonate(Level: SECURITY_IMPERSONATION_LEVEL): THandle;
var Token: THandle;
begin
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY or TOKEN_DUPLICATE, Token) then
    RaiseSystemError('Could not open impersonation source token', GetLastError);
  try
    if not DuplicateToken(Token, Level, @Result) then
      RaiseSystemError('Could not duplicate impersonation token', GetLastError);
  finally CloseHandle(Token); end;
  if not SetThreadToken(nil, Result) then
  begin CloseHandle(Result); RaiseSystemError('Could not impersonate', GetLastError); end;
end;
procedure CheckAnonymous(Audit: TAuditLog);
var Token, Oracle: THandle; Error: DWORD; Rejected: Boolean;
  Event: TJSONObject; Command: TScuCommand;
begin
  Token := Impersonate(SecurityAnonymous);
  try
    // Distinguish a runtime with no anonymous-token semantics from a faulty
    // production fallback to the process identity.
    if OpenThreadToken(GetCurrentThread, TOKEN_QUERY, True, Oracle) then
    begin CloseHandle(Oracle); raise EProbeSkip.Create('Runtime permits querying an anonymous token.'); end;
    Error := GetLastError;
    if Error <> ERROR_CANT_OPEN_ANONYMOUS then
      raise EProbeSkip.Create('Runtime did not report ERROR_CANT_OPEN_ANONYMOUS.');
    Rejected := False;
    Event := TJSONObject.Create;
    Command := TScuCommand.Create('must_not_be_logged', nil);
    try
      try
        if Assigned(Audit) then Audit.BeginCommand(Command)
        else AddAuditActor(Event);
      except
        on E: EScuSystemError do
        begin
          if Pos('Windows audit thread token', E.Message) = 0 then raise;
          Rejected := True;
        end;
      end;
      if not Rejected or (Event.Count <> 0) then
        raise EScuError.Create('Anonymous token was silently recorded as another actor.');
    finally Command.Free; Event.Free; end;
  finally
    if not RevertToSelf then RaiseSystemError('Could not end impersonation', GetLastError);
    CloseHandle(Token);
  end;
end;
{$ENDIF}
function Actor: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    AddAuditActor(Result);
    {$IFDEF WINDOWS}CheckSID(Result);{$ENDIF}
  except Result.Free; raise; end;
end;
type
  TActorThread = class(TThread)
    Data: TJSONObject;
    Failure: string;
    procedure Execute; override;
  end;
procedure TActorThread.Execute;
begin
  try Data := Actor;
  except on E: Exception do Failure := E.Message; end;
end;
var Args: TStringList; Mode: string; Event: TJSONObject; I, Count: Integer;
  Output: TTerminalOutput; Executor: TScuExecutor; Command: TScuCommand;
  Parameters: TScuArguments; Worker: TActorThread;
  Database: TSQLiteLibrary; Audit: TAuditLog; Snapshots: TAuditSnapshots;
  Stream: TStream;
  {$IFDEF WINDOWS}Token: THandle; BeforeCount, AfterCount: DWORD;{$ENDIF}
begin
  InitializePlatformPaths;
  Args := TStringList.Create;
  try
    try
      ReadInvocationArguments(Args); Mode := Args[0];
      if Mode = 'directory' then WriteLn(CanonicalDirectory(Args[1]))
      else if Mode = 'actor' then
      begin Event := Actor; try WriteLn(Event.AsJSON); finally Event.Free; end; end
      else if Mode = 'stream-copy' then
      begin
        {$IFDEF WINDOWS}
        BeforeCount := ProcessHandleCount;
        Stream := OpenReadFile(Args[1]); Stream.Free;
        AfterCount := ProcessHandleCount;
        if BeforeCount <> AfterCount then raise EScuError.Create('Read stream leaked a handle.');
        {$ENDIF}
        Stream := OpenReadFile(Args[1]);
        try AtomicWrite(Args[2], Stream); finally Stream.Free; end;
      end
      else if (Mode = 'execute') {$IFDEF WINDOWS}or (Mode = 'recover'){$ENDIF} then
      begin
        {$IFDEF WINDOWS}
        if Mode = 'recover' then
        begin
          if not SetEnvironmentVariableW('TMP', PWideChar(UTF8Decode(Args[1]))) or
            not SetEnvironmentVariableW('TEMP', PWideChar(UTF8Decode(Args[1]))) then
            RaiseSystemError('Could not set recovery temporary directory', GetLastError);
          Args.Delete(1);
        end;
        {$ENDIF}
        Output := TTerminalOutput.Create;
        Executor := TScuExecutor.Create(Args[1], False, Output);
        try
          SetLength(Parameters, Args.Count - 3);
          for I := 3 to Args.Count - 1 do
          begin
            Count := Pos('=', Args[I]);
            if Count = 0 then raise EScuError.Create('Expected a named command argument');
            Parameters[I-3].Name := Copy(Args[I], 1, Count - 1);
            Parameters[I-3].Value := Copy(Args[I], Count + 1, MaxInt);
            Parameters[I-3].Provided := True;
          end;
          Command := TScuCommand.Create(Args[2], Parameters);
          try Executor.Execute(Command); finally Command.Free; end;
        finally Executor.Free; Output.Free; end;
      end
      else if Mode = 'build-record' then
      begin
        Database := TSQLiteLibrary.OpenWrite(Args[1]);
        try
          Audit := TAuditLog.Open(Database);
          try Audit.RecordBuild(Audit.Head, 'probe build', 'output', True, ''); Database.Commit;
          finally Audit.Free; end;
        finally Database.Free; end;
      end
      {$IFDEF WINDOWS}
      else if Mode = 'thread' then
      begin
        Token := Impersonate(SecurityImpersonation);
        try
          Event := Actor; try WriteLn(Event.AsJSON); finally Event.Free; end;
          Worker := TActorThread.Create(True);
          try
            Worker.Start; Worker.WaitFor;
            if Worker.Failure <> '' then raise EScuError.Create(Worker.Failure);
            try WriteLn(Worker.Data.AsJSON); finally Worker.Data.Free; end;
          finally Worker.Free; end;
        finally RevertToSelf; CloseHandle(Token); end;
        Event := Actor; try WriteLn(Event.AsJSON); finally Event.Free; end;
      end
      else if Mode = 'anonymous' then begin CheckAnonymous(nil); WriteLn('rejected'); end
      else if Mode = 'anonymous-audit' then
      begin
        Database := TSQLiteLibrary.OpenWrite(Args[1]);
        try
          Audit := TAuditLog.Open(Database);
          try
            Count := Audit.Records; CheckAnonymous(Audit);
            if Audit.Records <> Count then raise EScuError.Create('Failed actor appended an audit row.');
            Command := TScuCommand.Create('restored_identity', nil);
            try Audit.BeginCommand(Command); finally Command.Free; end;
            Snapshots := Default(TAuditSnapshots);
            Audit.EndCommand(True, '', Snapshots); Database.Commit;
          finally Audit.Free; end;
        finally Database.Free; end;
      end
      else if Mode = 'handles' then
      begin
        Event := Actor; Event.Free;
        BeforeCount := ProcessHandleCount;
        for I := 1 to 2000 do begin Event := Actor; Event.Free; end;
        AfterCount := ProcessHandleCount;
        if BeforeCount <> AfterCount then raise EScuError.Create('Audit identity leaked token handles.');
        WriteLn('handles ok');
      end
      {$ENDIF}
      else raise EScuError.Create('Unknown actor probe mode');
    except
      on E: EProbeSkip do begin WriteLn(StdErr, E.Message); Halt(77); end;
      on E: Exception do begin WriteLn(StdErr, E.Message); Halt(1); end;
    end;
  finally Args.Free; end;
end.
