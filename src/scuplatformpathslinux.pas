unit ScuPlatformPathsLinux;

{$mode objfpc}{$H+}

interface

function ResolveDirectory(const Path: string): string;
function AbsolutePath(const Path: string): string;
function RunningExecutable: string;
function InvocationExecutable: string;
function StateRoot: string;
function ConfigRoot: string;
function PathsEqual(const Left, Right: string): Boolean;

implementation

uses SysUtils, BaseUnix, InitC, ScuErrors;

function realpath(Path, Resolved: PChar): PChar; cdecl; external 'c';

function ResolveDirectory(const Path: string): string;
var
  Resolved: array[0..4095] of Char;
begin
  if realpath(PChar(Path), @Resolved[0]) = nil then
    raise EScuError.CreateFmt('Could not resolve directory %s: %s', [Path, SysErrorMessage(cerrno)]);
  Result := StrPas(@Resolved[0]);
end;

function AbsolutePath(const Path: string): string;
begin
  Result := ExpandFileName(Path);
end;

function RunningExecutable: string;
var
  Buffer: array[0..4095] of Char;
  Count: ssize_t;
begin
  Count := fpReadLink('/proc/self/exe', @Buffer[0], SizeOf(Buffer));
  if (Count < 0) or (Count = SizeOf(Buffer)) then
    raise EScuError.Create('Could not locate the running SCU executable.');
  SetString(Result, PChar(@Buffer[0]), Count);
end;

function InvocationExecutable: string;
begin
  Result := ExpandFileName(ParamStr(0));
end;

function StateRoot: string;
begin
  Result := GetEnvironmentVariable('XDG_STATE_HOME');
  if Copy(Result, 1, 1) <> DirectorySeparator then
  begin
    Result := GetEnvironmentVariable('HOME');
    if Copy(Result, 1, 1) <> DirectorySeparator then Exit('');
    Result := IncludeTrailingPathDelimiter(Result) + '.local/state';
  end;
end;

function ConfigRoot: string;
begin
  Result := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Result = '' then Result := IncludeTrailingPathDelimiter(GetUserDir) + '.config';
end;

function PathsEqual(const Left, Right: string): Boolean;
begin
  Result := Left = Right;
end;

end.
