unit ScuPlatformPathsWindows;

{$mode objfpc}{$H+}

interface

uses Classes;

procedure LoadInvocationArguments(Arguments: TStrings);

function NativeFilePath(const Path: string): UnicodeString;
function ResolveDirectory(const Path: string): string;
function CommandFilePath(const FileName, ParentFile: string): string;
function AbsolutePath(const Path: string): string;
function RunningExecutable: string;
function InvocationExecutable: string;
function StateRoot: string;
function ConfigRoot: string;
function PathsEqual(const Left, Right: string): Boolean;

implementation

uses Windows, SysUtils, ScuErrors;

type
  TWideArgumentArray = array[0..65535] of PWideChar;
  PWideArgumentArray = ^TWideArgumentArray;
function WideArguments(CommandLine: PWideChar; out Count: Integer): PWideArgumentArray;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';

procedure LoadInvocationArguments(Arguments: TStrings);
var Values: PWideArgumentArray; Count, Index: Integer;
begin
  Values := WideArguments(GetCommandLineW, Count);
  if Values = nil then RaiseSystemError('Could not read command-line arguments', GetLastError);
  try
    Arguments.Clear;
    for Index := 1 to Count - 1 do
      Arguments.Add(UTF8Encode(UnicodeString(Values^[Index])));
  finally
    LocalFree(HLOCAL(Values));
  end;
end;

const
  MaxPathBuffer = 32768;
  OrdinalEqual = 2; // CompareStringOrdinal result, CSTR_EQUAL in the Windows SDK.

// These Vista+ APIs are absent from some Free Pascal Windows unit versions.
function FinalPathName(Handle: THandle; Buffer: PWideChar; Size, Flags: DWORD): DWORD;
  stdcall; external 'kernel32.dll' name 'GetFinalPathNameByHandleW';
function CompareOrdinal(Left: PWideChar; LeftLength: Integer; Right: PWideChar;
  RightLength: Integer; IgnoreCase: BOOL): Integer;
  stdcall; external 'kernel32.dll' name 'CompareStringOrdinal';

function WideAbsolutePath(const Path: string): UnicodeString;
var
  Input: UnicodeString;
  Count, Capacity: DWORD;
begin
  Input := UTF8Decode(Path);
  Capacity := 256;
  repeat
    SetLength(Result, Capacity);
    Count := GetFullPathNameW(PWideChar(Input), Capacity, PWideChar(Result), PLPWSTR(nil));
    if Count = 0 then RaiseSystemError('Could not resolve path "' + Path + '"', GetLastError);
    if Count < Capacity then
    begin
      SetLength(Result, Count);
      Exit;
    end;
    Capacity := Count + 1;
  until Capacity > MaxPathBuffer;
  raise EScuError.Create('Path is too long: "' + Path + '".');
end;

function CommandFilePath(const FileName, ParentFile: string): string;
var Value, Parent: string;
begin
  Value := StringReplace(FileName, '/', '\', [rfReplaceAll]);
  Parent := StringReplace(ParentFile, '/', '\', [rfReplaceAll]);
  // An explicit drive (including C:relative) or UNC/extended path belongs to
  // Win32 resolution, never to the including script's directory.
  if (Parent <> '') and (Value <> '') and
    not ((Length(Value) >= 2) and ((Value[2] = ':') or (Copy(Value, 1, 2) = '\\'))) then
  begin
    if Value[1] = '\' then Value := ExtractFileDrive(Parent) + Value
    else Value := IncludeTrailingPathDelimiter(ExtractFileDir(Parent)) + Value;
  end;
  Result := AbsolutePath(Value);
end;

function AbsolutePath(const Path: string): string;
begin
  Result := UTF8Encode(WideAbsolutePath(Path));
end;

function NativePath(const Path: UnicodeString): UnicodeString;
begin
  // Full paths only: the extended prefix bypasses the legacy MAX_PATH limit.
  if Copy(Path, 1, 4) = '\\?\' then Exit(Path);
  if Copy(Path, 1, 2) = '\\' then Exit('\\?\UNC\' + Copy(Path, 3, MaxInt));
  Result := '\\?\' + Path;
end;

function NativeFilePath(const Path: string): UnicodeString;
begin
  Result := NativePath(WideAbsolutePath(Path));
end;

function DisplayPath(const Path: UnicodeString): string;
var Value: UnicodeString;
begin
  Value := Path;
  if Copy(Value, 1, 8) = '\\?\UNC\' then Value := '\\' + Copy(Value, 9, MaxInt)
  else if Copy(Value, 1, 4) = '\\?\' then Delete(Value, 1, 4);
  Result := UTF8Encode(Value);
end;

function ResolveDirectory(const Path: string): string;
var
  Handle: THandle;
  Info: TByHandleFileInformation;
  FullPath, Buffer: UnicodeString;
  Count, Capacity: DWORD;
begin
  FullPath := NativeFilePath(Path);
  Handle := CreateFileW(PWideChar(FullPath), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then
    RaiseSystemError('Could not resolve directory ' + Path, GetLastError);
  try
    if not GetFileInformationByHandle(Handle, Info) then
      RaiseSystemError('Could not inspect directory ' + Path, GetLastError);
    if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then
      raise EScuError.Create('Expected a directory: ' + Path);
    Capacity := 256;
    repeat
      SetLength(Buffer, Capacity);
      Count := FinalPathName(Handle, PWideChar(Buffer), Capacity, 0);
      if Count = 0 then RaiseSystemError('Could not resolve directory ' + Path, GetLastError);
      if Count < Capacity then
      begin
        SetLength(Buffer, Count);
        Exit(DisplayPath(Buffer));
      end;
      Capacity := Count + 1;
    until Capacity > MaxPathBuffer;
    raise EScuError.Create('Directory path is too long: ' + Path);
  finally
    CloseHandle(Handle);
  end;
end;

function RunningExecutable: string;
var Buffer: UnicodeString; Count, Capacity: DWORD;
begin
  Capacity := 256;
  repeat
    SetLength(Buffer, Capacity);
    Count := GetModuleFileNameW(0, PWideChar(Buffer), Capacity);
    if Count = 0 then
      RaiseSystemError('Could not locate the running SCU executable', GetLastError);
    if Count < Capacity then
    begin
      SetLength(Buffer, Count);
      Exit(DisplayPath(Buffer));
    end;
    Capacity := Capacity * 2;
  until Capacity > MaxPathBuffer;
  raise EScuError.Create('SCU executable path is too long.');
end;

function InvocationExecutable: string;
begin
  Result := RunningExecutable;
end;

function EnvironmentPath(const Name: UnicodeString): string;
var Buffer: UnicodeString; Count, Capacity: DWORD;
begin
  Capacity := 256;
  repeat
    SetLength(Buffer, Capacity);
    Count := GetEnvironmentVariableW(PWideChar(Name), PWideChar(Buffer), Capacity);
    if Count = 0 then Exit('');
    if Count < Capacity then
    begin
      SetLength(Buffer, Count);
      Exit(UTF8Encode(Buffer));
    end;
    Capacity := Count + 1;
  until Capacity > MaxPathBuffer;
  raise EScuError.Create('Application data directory path is too long.');
end;

function StateRoot: string;
begin
  Result := EnvironmentPath('LOCALAPPDATA');
  if Result = '' then Result := EnvironmentPath('APPDATA');
  if Result = '' then raise EScuError.Create('Could not locate the application data directory.');
  Result := AbsolutePath(Result);
end;

function ConfigRoot: string;
begin
  Result := StateRoot;
end;

function PathsEqual(const Left, Right: string): Boolean;
var WideLeft, WideRight: UnicodeString; Comparison: Integer;
begin
  WideLeft := UTF8Decode(StringReplace(Left, '/', '\', [rfReplaceAll]));
  WideRight := UTF8Decode(StringReplace(Right, '/', '\', [rfReplaceAll]));
  Comparison := CompareOrdinal(PWideChar(WideLeft), Length(WideLeft),
    PWideChar(WideRight), Length(WideRight), True);
  if Comparison = 0 then RaiseSystemError('Could not compare paths', GetLastError);
  Result := Comparison = OrdinalEqual;
end;

end.
