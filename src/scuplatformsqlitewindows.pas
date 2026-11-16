unit ScuPlatformSQLiteWindows;

{$mode objfpc}{$H+}

interface

function CanRecoverSQLite(const Path: string): Boolean;
procedure CreateSQLiteFile(const Path: string);
function SQLiteFilename(const Path: string): RawByteString;

implementation

uses Windows, ScuErrors, ScuFiles, ScuPlatformPathsWindows,
  ScuPlatformFileSecurityWindows;

function CanRecoverSQLite(const Path: string): Boolean;
var Handle: THandle; Error: DWORD;
begin
  // Opening an existing file neither changes its bytes nor creates companions.
  // Do not trust attributes alone: ACLs can prohibit writes to a normal file.
  Handle := CreateFileW(PWideChar(NativeFilePath(Path)), GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);
  if Handle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(Handle);
    Exit(True);
  end;
  Error := GetLastError;
  if Error in [ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION, ERROR_WRITE_PROTECT,
    ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND] then Exit(False);
  RaiseSystemError('Could not inspect SQLite library "' + Path + '"', Error);
  Result := False;
end;

procedure CreateSQLiteFile(const Path: string);
var
  Handle: THandle;
  Attributes: TSecurityAttributes;
  Descriptor: PSecurityDescriptor;
begin
  if RegularFileExists(Path) then Exit;
  PrivateSecurity(Attributes, Descriptor);
  try
    Handle := CreateFileW(PWideChar(NativeFilePath(Path)), GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, @Attributes,
      CREATE_NEW, FILE_ATTRIBUTE_NORMAL or FILE_FLAG_WRITE_THROUGH, 0);
    if Handle = INVALID_HANDLE_VALUE then
      RaiseSystemError('Could not create SQLite library "' + Path + '"', GetLastError);
    try
      SyncFile(Handle, Path);
    finally
      CloseHandle(Handle);
    end;
    SyncParent(Path);
  finally
    LocalFree(HLOCAL(Descriptor));
  end;
end;

function SQLiteFilename(const Path: string): RawByteString;
begin
  // sqlite3_open_v2 takes UTF-8 even on Windows. Use an absolute extended
  // path for Unicode and long names; do not use open16 (it lacks open flags).
  Result := UTF8Encode(NativeFilePath(Path));
end;

end.
