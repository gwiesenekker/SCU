unit ScuPlatformLockHandlesWindows;

{$mode objfpc}{$H+}

interface

uses Windows;

function OpenLockHandle(const Path: string): THandle;
function TryLockHandle(Handle: THandle; const Path: string): Boolean;
procedure ReleaseLockHandle(Handle: THandle);

implementation

uses SysUtils, ScuErrors, ScuPlatformPathsWindows, ScuPlatformFileSecurityWindows;

function OpenLockHandle(const Path: string): THandle;
var Attributes: TSecurityAttributes; Descriptor: PSecurityDescriptor; Info: TByHandleFileInformation;
begin
  PrivateSecurity(Attributes, Descriptor);
  try
    // Deny deletion/replacement of the sidecar while any participant is using
    // it. Creating a fresh inode here would split the lock into two domains.
    Result := CreateFileW(PWideChar(NativeFilePath(Path)), GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE, @Attributes, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL or OpenReparsePoint or FILE_FLAG_BACKUP_SEMANTICS, 0);
    if Result = INVALID_HANDLE_VALUE then RaiseSystemError('Could not open lock file "' + Path + '"', GetLastError);
    try
      if not GetFileInformationByHandle(Result, Info) then
        RaiseSystemError('Could not inspect lock file "' + Path + '"', GetLastError);
      if (GetFileType(Result) <> FILE_TYPE_DISK) or
        ((Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0) then
        raise EScuError.Create('Expected a regular lock file at "' + Path + '".');
    except
      CloseHandle(Result);
      raise;
    end;
  finally
    LocalFree(HLOCAL(Descriptor));
  end;
end;

function TryLockHandle(Handle: THandle; const Path: string): Boolean;
var Lock: TOverlapped; Error: DWORD;
begin
  FillChar(Lock, SizeOf(Lock), 0);
  Result := LockFileEx(Handle, LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, Lock);
  if Result then Exit;
  Error := GetLastError;
  if Error <> ERROR_LOCK_VIOLATION then
    RaiseSystemError('Could not acquire lock "' + Path + '"', Error);
end;

procedure ReleaseLockHandle(Handle: THandle);
var Lock: TOverlapped;
begin
  if Handle = INVALID_HANDLE_VALUE then Exit;
  FillChar(Lock, SizeOf(Lock), 0);
  UnlockFileEx(Handle, 0, 1, 0, Lock);
  CloseHandle(Handle);
end;

end.
