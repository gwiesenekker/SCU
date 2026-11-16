unit ScuPlatformHistoryWindows;
{$mode objfpc}{$H+}
interface
function CommandHistoryPath: string;
implementation
uses Windows, SysUtils, ScuErrors, ScuPlatformPaths, ScuPlatformPathsWindows,
  ScuPlatformFileSecurityWindows;
procedure EnsureRoot(const Path: string);
var Attributes: DWORD; Parent: string;
begin
  Attributes := GetFileAttributesW(PWideChar(NativeFilePath(Path)));
  if Attributes <> INVALID_FILE_ATTRIBUTES then
  begin
    if (Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then raise EScuError.Create('Expected a state directory: ' + Path);
    Exit;
  end;
  Parent := ExtractFileDir(ExcludeTrailingPathDelimiter(Path));
  if (Parent = '') or (Parent = Path) then RaiseSystemError('Could not locate state directory ' + Path, GetLastError);
  EnsureRoot(Parent);
  if not CreateDirectoryW(PWideChar(NativeFilePath(Path)), nil) and (GetLastError <> ERROR_ALREADY_EXISTS) then
    RaiseSystemError('Could not create state directory ' + Path, GetLastError);
end;
function CommandHistoryPath: string;
var Root, Directory: string; Security: TSecurityAttributes; Descriptor: PSecurityDescriptor;
  Handle: THandle; Info: TByHandleFileInformation;
begin
  Root := HistoryStateRoot; EnsureRoot(Root);
  Directory := IncludeTrailingPathDelimiter(PlatformCanonicalDirectory(Root)) + 'scu';
  PrivateSecurity(Security, Descriptor);
  try
    if not CreateDirectoryW(PWideChar(NativeFilePath(Directory)), @Security) and
      (GetLastError <> ERROR_ALREADY_EXISTS) then RaiseSystemError('Could not create SCU state directory ' + Directory, GetLastError);
  finally LocalFree(HLOCAL(Descriptor)); end;
  Handle := CreateFileW(PWideChar(NativeFilePath(Directory)), FileReadControl,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, OpenReparsePoint or FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseSystemError('Could not inspect SCU state directory ' + Directory, GetLastError);
  try
    if not GetFileInformationByHandle(Handle, Info) then RaiseSystemError('Could not inspect SCU state directory ' + Directory, GetLastError);
    if ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0) or
      ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) or not IsPrivateOwnedDirectory(Handle) then
      raise EScuError.Create('Expected a private user-owned SCU state directory at ' + Directory);
  finally CloseHandle(Handle); end;
  Result := IncludeTrailingPathDelimiter(Directory) + 'history.json';
end;
end.
