program LocksProbe;

{$mode objfpc}{$H+}

uses Classes, SysUtils, ScuErrors, ScuLocks, ScuOutputLock, ScuLockTypes,
  ScuFiles, ScuLibraryNames, ScuPlatformPaths
  {$IFDEF WINDOWS}, Windows, ScuPlatformPathsWindows{$ELSE}, BaseUnix, Unix, Linux, ScuSignals{$ENDIF};

{$IFDEF WINDOWS}
type TWideArguments = array[0..65535] of PWideChar; PWideArguments = ^TWideArguments;
function WideArguments(CommandLine: PWideChar; out Count: Integer): PWideArguments;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
{$ENDIF}

function Argument(Index: Integer): string;
{$IFDEF WINDOWS}
var Arguments: PWideArguments; Count: Integer;
begin
  Arguments := WideArguments(GetCommandLineW, Count);
  if Arguments = nil then RaiseLastOSError;
  try
    if Index < Count then Result := UTF8Encode(UnicodeString(Arguments^[Index])) else Result := '';
  finally
    LocalFree(HLOCAL(Arguments));
  end;
end;
{$ELSE}
begin
  Result := ParamStr(Index);
end;
{$ENDIF}

var
  Kind, Path, Action, Reply: string;
  Lock: TObject;
  Started: QWord;
  Checks: Integer;
  Generated: Boolean;
  {$IFNDEF WINDOWS}Previous: TSessionSignalHandlers;{$ENDIF}

procedure Check;
begin
  Inc(Checks);
  {$IFNDEF WINDOWS}CheckSessionInterrupt;{$ENDIF}
  if Checks = 1 then begin WriteLn('waiting'); Flush(Output); end;
  if (Action = 'cancel_after') and (Checks = {$IFDEF WINDOWS}3{$ELSE}2{$ENDIF}) then
    raise ECommandCancelled.Create('Command cancelled.');
  if (Action = 'cancel') and (GetTickCount64 - Started >= 150) then
    raise ECommandCancelled.Create('Command cancelled.');
  if (Action = 'console_cancel') and not Generated and (GetTickCount64 - Started >= 150) then
  begin
    Generated := True;
    {$IFDEF WINDOWS}
    if not GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) then
    begin WriteLn(StdErr, 'Console control events unavailable.'); Halt(77); end;
    {$ELSE}
    fpKill(fpGetPid, SIGINT);
    {$ENDIF}
  end;
  if (Action = 'console_cancel') and (GetTickCount64 - Started >= 2000) then
    raise EScuError.Create('Console cancellation did not arrive.');
end;

function Stop: Boolean;
begin
  Result := (Action = 'stop') and (GetTickCount64 - Started >= 150);
end;

begin
  {$IFDEF WINDOWS}SetMultiByteConversionCodePage(CP_UTF8);{$ENDIF}
  InitializePlatformPaths;
  Lock := nil;
  Kind := Argument(1); Path := Argument(2); Action := Argument(3);
  {$IFNDEF WINDOWS}StartSessionSignals(Previous);{$ENDIF}
  try
    try
      {$IFDEF WINDOWS}
      if Kind = 'protect' then
      begin
        if not DeleteFileW(PWideChar(NativeFilePath(Path))) then
          raise EScuError.Create('Lock sidecar is protected against deletion.');
        Halt(0);
      end;
      {$ENDIF}
      if Kind = 'stage' then begin WriteLn(MakeStagingDirectory(Path)); Halt(0); end;
      if Kind = 'cleanup' then begin CleanupStaleAtomicFiles(Path); Halt(0); end;
      if Kind = 'write' then begin AtomicWrite(Path, 'staged'); Halt(0); end;
      if Kind = 'validate' then
      begin ValidateSourceFileName(Path); Halt(0); end;
      Started := GetTickCount64;
      if Kind = 'library' then Lock := TFileLock.Create(Path, @Stop, @Check)
      else if Kind = 'output' then
      begin
        if Action = 'reuse' then
          Lock := TOutputDirectoryLock.CreateWithBuildLockReuse(Path, @Stop, @Check)
        else Lock := TOutputDirectoryLock.Create(Path, @Stop, @Check);
      end
      else raise EScuError.Create('Unknown lock kind.');
      if Action = 'flags' then
      begin
        {$IFDEF WINDOWS}
        Checks := 0;
        if not GetHandleInformation(TOutputDirectoryLock(Lock).BuildHandle, DWORD(Checks)) then RaiseLastOSError;
        WriteLn('flags=', Checks and HANDLE_FLAG_INHERIT);
        {$ELSE}
        WriteLn('flags=', fpFcntl(TOutputDirectoryLock(Lock).BuildHandle, F_GETFD) and 1 {FD_CLOEXEC});
        {$ENDIF}
      end;
      WriteLn('locked'); Flush(Output);
      if Action = 'hold' then ReadLn(Reply);
      if Argument(4) <> '' then AtomicWrite(Argument(4), 'effect');
    except
      on E: Exception do
      begin
        WriteLn(StdErr, E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    Lock.Free;
    {$IFNDEF WINDOWS}RestoreSessionSignals(Previous);{$ENDIF}
  end;
end.
