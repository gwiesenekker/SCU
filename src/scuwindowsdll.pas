unit ScuWindowsDLL;
{$mode objfpc}{$H+}
interface
uses Windows;
type
  TWindowsDLL = class
  private
    FHandle: HMODULE;
    FPath: string;
  public
    constructor Create(const Component: string; const Names: array of string);
    destructor Destroy; override;
    function Require(const Name: AnsiString): Pointer;
    property Path: string read FPath;
  end;
implementation
uses SysUtils, ScuErrors, ScuPlatformPathsWindows, ScuPlatformFileSecurityWindows;
const SearchDLLDirectory = $00000100; SearchSystem32 = $00000800;
constructor TWindowsDLL.Create(const Component: string; const Names: array of string);
var Directory, Name, Expected: string; FileHandle: THandle;
  Info: TByHandleFileInformation; Error: DWORD;
begin
  inherited Create;
  Directory := IncludeTrailingPathDelimiter(ExtractFileDir(RunningExecutable));
  Expected := '';
  for Name in Names do
  begin
    if Expected <> '' then Expected := Expected + ', ';
    Expected := Expected + Name;
    FPath := Directory + Name;
    FileHandle := CreateFileW(PWideChar(NativeFilePath(FPath)), GENERIC_READ,
      FILE_SHARE_READ, nil, OPEN_EXISTING, OpenReparsePoint or FILE_FLAG_BACKUP_SEMANTICS, 0);
    if FileHandle = INVALID_HANDLE_VALUE then
    begin
      Error := GetLastError;
      // An installed but broken preferred DLL is an error, not a reason to
      // silently switch implementations or search less trusted directories.
      if Error = ERROR_FILE_NOT_FOUND then Continue;
      RaiseSystemError('Could not open ' + Component + ' DLL "' + FPath + '"', Error);
    end;
    try
      if not GetFileInformationByHandle(FileHandle, Info) then
        RaiseSystemError('Could not inspect DLL "' + FPath + '"', GetLastError);
      if (GetFileType(FileHandle) <> FILE_TYPE_DISK) or
        ((Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0) then
        raise EScuError.Create('Expected a regular DLL without a reparse point: "' + FPath + '".');
      // Full Unicode path; primary DLLs are never found through CWD/PATH.
      // Their dependencies may come only from this DLL's directory/System32
      // (in addition to Windows' existing module/KnownDLL resolution).
      FHandle := LoadLibraryExW(PWideChar(NativeFilePath(FPath)), 0,
        SearchDLLDirectory or SearchSystem32);
      if FHandle = 0 then
        RaiseSystemError('Could not load ' + Component + ' DLL "' + FPath +
          '" (check its architecture and app-local dependencies)', GetLastError);
      Exit;
    finally
      CloseHandle(FileHandle);
    end;
  end;
  raise EScuError.CreateFmt('Could not find %s DLL beside the executable in "%s". Expected %s.',
    [Component, Directory, Expected]);
end;
destructor TWindowsDLL.Destroy;
begin
  if FHandle <> 0 then FreeLibrary(FHandle);
  inherited Destroy;
end;
function TWindowsDLL.Require(const Name: AnsiString): Pointer;
begin
  Result := GetProcAddress(FHandle, PAnsiChar(Name));
  if Result = nil then
    raise EScuError.CreateFmt('DLL "%s" is missing required export %s.', [FPath, Name]);
end;
end.
