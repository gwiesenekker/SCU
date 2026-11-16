program ScanProbe;
{$mode objfpc}{$H+}
uses Classes, SysUtils, Contnrs, ScuErrors, ScuFiles, ScuFileScan,
  ScuLibraryNames, ScuCommandFiles, ScuPlatformPaths, ScuSignals
  {$IFDEF WINDOWS}, Windows, ScuPlatformPathsWindows{$ENDIF};
{$IFDEF WINDOWS}
type
  TWideArguments = array[0..65535] of PWideChar;
  PWideArguments = ^TWideArguments;
function WideArguments(CommandLine: PWideChar; out Count: Integer): PWideArguments;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
{$ENDIF}

function Argument(Index: Integer): string;
{$IFDEF WINDOWS}
var Arguments: PWideArguments; Count: Integer;
begin
  Arguments := WideArguments(GetCommandLineW, Count);
  if Arguments = nil then RaiseSystemError('Could not parse probe arguments', GetLastError);
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

{$IFDEF WINDOWS}
function MakeSymbolicLink(Link, Target: PWideChar; Flags: DWORD): Byte; stdcall;
  external 'kernel32.dll' name 'CreateSymbolicLinkW';

procedure WindowsLink(const Link, Target: string);
begin
  if (MakeSymbolicLink(PWideChar(NativeFilePath(Link)), PWideChar(NativeFilePath(Target)), 2) = 0) and
    (MakeSymbolicLink(PWideChar(NativeFilePath(Link)), PWideChar(NativeFilePath(Target)), 0) = 0) then
  begin
    WriteLn(StdErr, 'Symbolic links unavailable: ', SysErrorMessage(GetLastError));
    Halt(77);
  end;
  if (GetFileAttributesW(PWideChar(NativeFilePath(Link))) = INVALID_FILE_ATTRIBUTES) or
    ((GetFileAttributesW(PWideChar(NativeFilePath(Link))) and FILE_ATTRIBUTE_REPARSE_POINT) = 0) then
  begin
    WriteLn(StdErr, 'This runtime/filesystem did not create an observable reparse point.');
    Halt(77);
  end;
end;
{$ENDIF}

var Mode, Line, Location: string; Patterns: TStringList;
  Scan: TLibraryFileScan; Files: TCommandFiles; I: Integer;
  Owners: TFPHashObjectList; Binding: TDeckFileBinding;
begin
  InitializePlatformPaths;
  try
    Mode := Argument(1);
    {$IFDEF WINDOWS}
    if Mode = 'link' then begin WindowsLink(Argument(2), Argument(3)); Exit; end;
    if Mode = 'hidden' then
    begin
      if not SetFileAttributesW(PWideChar(NativeFilePath(Argument(2))), FILE_ATTRIBUTE_HIDDEN) then
        RaiseSystemError('Could not hide probe file', GetLastError);
      Exit;
    end;
    {$ENDIF}
    if Mode = 'argv' then
    begin
      Patterns := TStringList.Create;
      try
        ReadInvocationArguments(Patterns);
        for I := 1 to Patterns.Count - 1 do WriteLn('arg:', Patterns[I]);
      finally Patterns.Free; end;
    end
    else if Mode = 'parse-file' then WriteLn(ParseCommandFileName(Argument(2)))
    else if Mode = 'match' then WriteLn(Ord(MatchesFilePattern(Argument(2), Argument(3))))
    else if Mode = 'name' then ValidateSourceFileName(Argument(2))
    else if Mode = 'resolve' then WriteLn(ResolveCommandFilePath(Argument(2), Argument(3)))
    else if Mode = 'files' then
    begin
      Files := TCommandFiles.Create;
      try
        Files.Push(Argument(2));
        while Files.ReadLine(Line, Location) do
          if Copy(Line, 1, 1) = '!' then Files.Push(ParseCommandFileName(Copy(Line, 2, MaxInt)))
          else WriteLn(Location, '|', Line);
      finally Files.Free; end;
    end
    else if Mode = 'depth' then
    begin
      Files := TCommandFiles.Create;
      try
        for I := 1 to 17 do Files.Push(Argument(2));
      finally Files.Free; end;
    end
    else if (Mode = 'scan') or (Mode = 'owner') or (Mode = 'owners') or (Mode = 'cancel') then
    begin
      Patterns := TStringList.Create; Owners := TFPHashObjectList.Create(True);
      try
        Patterns.Add(Argument(4));
        if (Mode = 'owner') or (Mode = 'owners') then
        begin
          Binding := TDeckFileBinding.Create; Binding.Deck := 'tracked-deck';
          Owners.Add(Argument(5), Binding);
          if Mode = 'owners' then
          begin
            Binding := TDeckFileBinding.Create; Binding.Deck := 'other-deck';
            Owners.Add(Argument(6), Binding);
          end;
        end;
        if Mode = 'cancel' then
        begin
          // Cancellation must propagate through scanner construction.
          NoteSessionSignal(SignalInterrupt);
        end;
        Scan := TLibraryFileScan.Create(Argument(2), Argument(3), Patterns, Owners);
        try
          for I := 0 to Scan.Count - 1 do WriteLn(Scan.Decks[I], '|', Scan.RelativePaths[I]);
        finally Scan.Free; end;
      finally Owners.Free; Patterns.Free; end;
    end
    else raise EScuError.Create('Unknown scan probe mode');
  except
    on E: Exception do begin WriteLn(StdErr, E.Message); Halt(1); end;
  end;
end.
