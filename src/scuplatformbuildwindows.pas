unit ScuPlatformBuildWindows;
{$mode objfpc}{$H+}
interface
uses ScuBuildTypes;
function RunBuildProcess(const Build: TBuildRequest; Interactive: Boolean; OutputLock: THandle): string;
implementation
uses Windows, SysUtils, ScuErrors, ScuProcessTypes, ScuPlatformProcessWindows,
  ScuPlatformProcessStringsWindows;
function RunBuildProcess(const Build: TBuildRequest; Interactive: Boolean; OutputLock: THandle): string;
var Request: TChildProcessRequest; Status: Integer; Buffer: array[0..32767] of WideChar; Count: UINT;
begin
  Result := '';
  try
    if WindowsEnvironmentValue('SCU_BUILD_ACTIVE') = '1' then
      raise EScuError.Create('Nested SCU builds are disabled. Use build=no in the build command.');
    Request := TChildProcessRequest.Create;
    try
      Request.Executable := WindowsEnvironmentValue('COMSPEC');
      if Request.Executable = '' then
      begin
        Count := GetSystemDirectoryW(@Buffer[0], Length(Buffer));
        if (Count = 0) or (Count >= Length(Buffer)) then RaiseSystemError('Could not find Windows command processor', GetLastError);
        Request.Executable := IncludeTrailingPathDelimiter(UTF8Encode(UnicodeString(PWideChar(@Buffer[0])))) + 'cmd.exe';
      end;
      Request.WorkingDirectory := Build.WorkingDirectory;
      Request.ShellCommand := Build.Command; Request.NullInput := True; Request.OutputLock := OutputLock;
      Request.Environment.Values['SCU_BUILD_ACTIVE'] := '1';
      Request.Environment.Values['SCU_BUILD_LIBRARY'] := Build.LibraryPath;
      Request.Environment.Values['SCU_BUILD_OUTPUT'] := Build.OutputPath;
      Status := RunWindowsChild(Request, [cpOwnProcessGroup]);
      if DWORD(Status) = $C000013A then raise EScuError.Create('Build command interrupted.');
      if Status <> 0 then raise EScuError.CreateFmt('Build command failed with exit status %d.', [Status]);
    finally Request.Free; end;
  except
    on E: ECommandCancelled do raise;
    on E: Exception do Result := E.Message;
  end;
end;
end.
