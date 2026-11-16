program CleanupProbe;
{$mode objfpc}{$H+}
uses Classes, SysUtils, ScuCleanupFiles, ScuReleaseFiles, ScuFiles,
  ScuErrors, ScuSignals, ScuPlatformPaths
  {$IFDEF WINDOWS}, Windows, ScuPlatformPathsWindows{$ENDIF};
{$IFDEF WINDOWS}
function MakeLink(Link, Target: PWideChar; Flags: DWORD): Byte; stdcall;
  external 'kernel32.dll' name 'CreateSymbolicLinkW';
function MakeHardLink(Link, Target: PWideChar; Security: Pointer): BOOL; stdcall;
  external 'kernel32.dll' name 'CreateHardLinkW';
function HandleCount(Process: THandle; out Count: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetProcessHandleCount';
{$ENDIF}
var Args, Patterns, Selected, Tracked, Names: TStringList;
  Mode, Path: string; I: Integer;
  {$IFDEF WINDOWS}Flags, BeforeCount, AfterCount: DWORD; Handle: THandle;{$ENDIF}
function Arg(Index: Integer): string;
begin
  if Index < Args.Count then Result := Args[Index] else Result := '';
end;
begin
  InitializePlatformPaths;
  Args := TStringList.Create;
  try
    try
      ReadInvocationArguments(Args);
      Mode := Arg(0); Path := Arg(1);
      if Mode = 'editor' then RemoveWorkingDirectory(Path)
      else if Mode = 'failure' then
      begin
        try raise EScuError.Create('Original editor failure');
        finally RemoveWorkingDirectory(Path); end;
      end
      else if Mode = 'cancel' then
      begin
        NoteSessionSignal(SignalInterrupt);
        RemoveWorkingDirectory(Path);
        CheckSessionInterrupt;
      end
      else if Mode = 'release-delete' then RemoveObsoleteReleaseFile(Path)
      else if Mode = 'ensure' then EnsureRealReleaseDirectory(Path)
      else if Mode = 'inspect' then WriteLn(Ord(ReleaseFileEligible(Path, Arg(2) = 'missing')))
      else if Mode = 'collect' then
      begin
        Patterns := TStringList.Create; Selected := TStringList.Create;
        Tracked := TStringList.Create; Names := NewCleanupFileList;
        try
          Patterns.Text := Arg(3); Selected.Text := Arg(4); Tracked.Text := Arg(5);
          CollectReleaseCleanupFiles(Path, Arg(2), Patterns, Selected, Tracked, Names);
          for I := 0 to Names.Count - 1 do WriteLn(Names[I]);
        finally Names.Free; Tracked.Free; Selected.Free; Patterns.Free; end;
      end
      {$IFDEF WINDOWS}
      else if Mode = 'attributes' then
      begin
        Flags := FILE_ATTRIBUTE_NORMAL;
        if Arg(2) = 'readonly' then Flags := FILE_ATTRIBUTE_READONLY;
        if Arg(2) = 'hidden' then Flags := FILE_ATTRIBUTE_HIDDEN;
        if not SetFileAttributesW(PWideChar(NativeFilePath(Path)), Flags) then
          RaiseSystemError('Could not set probe attributes', GetLastError);
      end
      else if Mode = 'hardlink' then
      begin
        if not MakeHardLink(PWideChar(NativeFilePath(Path)), PWideChar(NativeFilePath(Arg(2))), nil) then
          RaiseSystemError('Could not create probe hard link', GetLastError);
      end
      else if Mode = 'link' then
      begin
        Flags := StrToIntDef(Arg(3), 0);
        if (MakeLink(PWideChar(NativeFilePath(Path)), PWideChar(NativeFilePath(Arg(2))), Flags or 2) = 0) and
          (MakeLink(PWideChar(NativeFilePath(Path)), PWideChar(NativeFilePath(Arg(2))), Flags) = 0) then Halt(77);
        Flags := GetFileAttributesW(PWideChar(NativeFilePath(Path)));
        if (Flags = INVALID_FILE_ATTRIBUTES) or ((Flags and FILE_ATTRIBUTE_REPARSE_POINT) = 0) then Halt(77);
      end
      else if Mode = 'blocked' then
      begin
        Handle := CreateFileW(PWideChar(NativeFilePath(Arg(2))), 0,
          FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
        if Handle = INVALID_HANDLE_VALUE then RaiseSystemError('Could not hold probe file', GetLastError);
        try
          if not HandleCount(GetCurrentProcess, BeforeCount) then RaiseSystemError('Could not count handles', GetLastError);
          for I := 1 to 100 do RemoveWorkingDirectory(Path);
          if not HandleCount(GetCurrentProcess, AfterCount) then RaiseSystemError('Could not count handles', GetLastError);
          if BeforeCount <> AfterCount then raise EScuError.Create('Editor cleanup leaked handles.');
          if GetFileAttributesW(PWideChar(NativeFilePath(Arg(2)))) = INVALID_FILE_ATTRIBUTES then
            raise EScuError.Create('Blocked file was unexpectedly removed.');
        finally CloseHandle(Handle); end;
        RemoveWorkingDirectory(Path);
      end
      {$ENDIF}
      else raise EScuError.Create('Unknown cleanup probe mode');
    except
      on E: Exception do begin WriteLn(StdErr, E.Message); Halt(1); end;
    end;
  finally Args.Free; end;
end.
