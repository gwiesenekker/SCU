unit ScuPlatformCleanupWindows;
{$mode objfpc}{$H+}
interface
uses ScuPlatformScanWindows;
type TReleaseDirectoryScan = class(TPlatformDirectoryScan)
  public constructor Create(const Directory: string);
end;
procedure EnsureRealReleaseDirectory(const Path: string);
function ReleaseFileEligible(const Path: string; AllowMissing: Boolean): Boolean;
procedure RemoveObsoleteReleaseFile(const Path: string);
procedure RemoveWorkingDirectory(const Path: string);
implementation
uses Windows, SysUtils, ScuErrors, ScuPlatformPathsWindows, ScuPlatformFileSecurityWindows,
  ScuWindowsDelete, ScuWindowsEditCleanup;
constructor TReleaseDirectoryScan.Create(const Directory: string);
begin inherited Create(Directory, True); end;
function OpenReleaseFile(const Path: string; Access: DWORD): THandle;
begin
  Result := CreateFileW(PWideChar(NativeFilePath(Path)), Access,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    OpenReparsePoint or FILE_FLAG_BACKUP_SEMANTICS, 0);
end;
function IsRegular(Handle: THandle; const Path: string): Boolean;
var Info: TByHandleFileInformation;
begin
  if not GetFileInformationByHandle(Handle, Info) then
    RaiseSystemError('Could not inspect release file "' + Path + '"', GetLastError);
  Result := (GetFileType(Handle) = FILE_TYPE_DISK) and
    ((Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) = 0);
end;
procedure MakeReleaseDirectory(const Path: string);
var Error: DWORD; Parent: string;
begin
  if CreateDirectoryW(PWideChar(NativeFilePath(Path)), nil) then Exit;
  Error := GetLastError;
  if Error = ERROR_ALREADY_EXISTS then Exit;
  if Error = ERROR_PATH_NOT_FOUND then
  begin
    Parent := ExtractFileDir(ExcludeTrailingPathDelimiter(Path));
    if (Parent <> '') and (Parent <> Path) then
    begin
      MakeReleaseDirectory(Parent);
      if CreateDirectoryW(PWideChar(NativeFilePath(Path)), nil) then Exit;
      Error := GetLastError;
      if Error = ERROR_ALREADY_EXISTS then Exit;
    end;
  end;
  RaiseSystemError('Could not create export directory "' + Path + '"', Error);
end;
procedure EnsureRealReleaseDirectory(const Path: string);
var Handle: THandle; Info: TByHandleFileInformation; Error: DWORD;
begin
  Handle := OpenReleaseFile(Path, 0);
  if Handle = INVALID_HANDLE_VALUE then
  begin
    Error := GetLastError;
    if not (Error in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND]) then
      RaiseSystemError('Could not inspect export directory "' + Path + '"', Error);
    MakeReleaseDirectory(Path);
    Handle := OpenReleaseFile(Path, 0);
    if Handle = INVALID_HANDLE_VALUE then
      RaiseSystemError('Could not inspect export directory "' + Path + '"', GetLastError);
  end;
  try
    if not GetFileInformationByHandle(Handle, Info) then
      RaiseSystemError('Could not inspect export directory "' + Path + '"', GetLastError);
    if (GetFileType(Handle) <> FILE_TYPE_DISK) or
      ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0) or
      ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
      raise EScuError.Create('Expected a real export directory, not a file or symbolic link: "' + Path + '".');
  finally CloseHandle(Handle); end;
end;
function ReleaseFileEligible(const Path: string; AllowMissing: Boolean): Boolean;
var Handle: THandle; Error: DWORD;
begin
  Handle := OpenReleaseFile(Path, 0);
  if Handle = INVALID_HANDLE_VALUE then
  begin
    Error := GetLastError;
    if AllowMissing and (Error in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND]) then Exit(True);
    RaiseSystemError('Could not inspect release file "' + Path + '"', Error);
  end;
  try Result := IsRegular(Handle, Path);
  finally CloseHandle(Handle); end;
end;
procedure RemoveObsoleteReleaseFile(const Path: string);
var Handle: THandle;
begin
  Handle := OpenReleaseFile(Path, FileDeleteAccess);
  if Handle = INVALID_HANDLE_VALUE then
    RaiseSystemError('Could not remove obsolete release file "' + Path + '"', GetLastError);
  try
    if not IsRegular(Handle, Path) then
      raise EScuError.Create('Refusing to remove a non-regular release file: "' + Path + '".');
    // Do not change release-file attributes or permissions to force deletion.
    if not DeleteOpenedFile(Handle, False) then
      RaiseSystemError('Could not remove obsolete release file "' + Path + '"', GetLastError);
  finally CloseHandle(Handle); end;
end;
procedure RemoveWorkingDirectory(const Path: string);
begin RemoveEditorDirectory(Path); end;
end.
