unit ScuPlatformFileCleanupWindows;

{$mode objfpc}{$H+}

interface

uses Windows;

procedure DiscardAtomicFile(Handle: THandle);
function TryLockAtomicFile(Handle: THandle): Boolean;
procedure CleanupWindowsAtomicFiles(const Directory: string);

implementation

uses SysUtils, ScuPlatformPathsWindows, ScuPlatformFileSecurityWindows;

type
  TVisitFile = procedure(const Path, Name: string; Attributes: DWORD);
  TDispositionInfo = record
    DeleteFile: Byte;
  end;

function SetHandleInformation(Handle: THandle; InformationClass: Integer;
  Information: Pointer; Size: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'SetFileInformationByHandle';

function TryLockAtomicFile(Handle: THandle): Boolean;
var Lock: TOverlapped;
begin
  FillChar(Lock, SizeOf(Lock), 0);
  // Lock beyond any supported source-file size. Windows byte locks are
  // mandatory: byte zero would briefly block readers after the rename.
  Lock.OffsetHigh := $7FFFFFFF;
  Lock.Offset := $FFFFFFFE;
  Result := LockFileEx(Handle, LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, Lock);
end;

function OpenOwned(const Path: string; Directory: Boolean; Access: DWORD): THandle;
var Info: TByHandleFileInformation; Sharing: DWORD;
begin
  Sharing := FILE_SHARE_READ or FILE_SHARE_WRITE;
  if not Directory or ((Access and FileDeleteAccess) <> 0) then Sharing := Sharing or FILE_SHARE_DELETE;
  Result := CreateFileW(PWideChar(NativeFilePath(Path)), Access or FileReadControl,
    Sharing, nil, OPEN_EXISTING,
    OpenReparsePoint or FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Result = INVALID_HANDLE_VALUE then Exit;
  if not GetFileInformationByHandle(Result, Info) or
    ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) or
    (((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) <> Directory) or
    (GetFileType(Result) <> FILE_TYPE_DISK) or not IsCurrentUserOwned(Result) then
  begin
    CloseHandle(Result);
    Result := INVALID_HANDLE_VALUE;
  end;
end;

procedure DeleteOpened(Handle: THandle);
var Info: TDispositionInfo;
begin
  Info.DeleteFile := 1;
  // Delete the inspected object by handle, not a name that could be swapped.
  SetHandleInformation(Handle, 4 {FileDispositionInfo}, @Info, SizeOf(Info));
end;

procedure DiscardAtomicFile(Handle: THandle);
begin
  DeleteOpened(Handle);
end;

function Visit(const Directory, Pattern: string; Callback: TVisitFile): Boolean;
var Search: THandle; Data: WIN32_FIND_DATAW; Name: string;
begin
  Result := False;
  Search := FindFirstFileW(PWideChar(NativeFilePath(IncludeTrailingPathDelimiter(Directory) + Pattern)), @Data);
  if Search = INVALID_HANDLE_VALUE then Exit;
  try
    repeat
      Name := UTF8Encode(UnicodeString(PWideChar(@Data.cFileName[0])));
      if (Name <> '.') and (Name <> '..') then
        Callback(IncludeTrailingPathDelimiter(Directory) + Name, Name, Data.dwFileAttributes);
    until not FindNextFileW(Search, @Data);
    Result := GetLastError = ERROR_NO_MORE_FILES;
  finally
    Windows.FindClose(Search);
  end;
end;

function ValidTemporaryName(const Name, Prefix: string): Boolean;
var Tail: string; Dash, Pid, Index: Integer;
begin
  Result := False;
  if Copy(Name, 1, Length(Prefix)) <> Prefix then Exit;
  Tail := Copy(Name, Length(Prefix) + 1, MaxInt);
  Dash := Pos('-', Tail);
  if (Dash < 2) or not TryStrToInt(Copy(Tail, 1, Dash - 1), Pid) or (Pid <= 0) or
    (Length(Tail) - Dash <> 32) then Exit;
  for Index := Dash + 1 to Length(Tail) do
    if not (Tail[Index] in ['0'..'9', 'a'..'f', 'A'..'F']) then Exit;
  Result := True;
end;

procedure RemoveTemporary(const Path, Name: string; Attributes: DWORD);
var Handle: THandle;
begin
  if not ValidTemporaryName(Name, '.scu-tmp-') then Exit;
  Handle := OpenOwned(Path, False, GENERIC_READ or FileDeleteAccess);
  if Handle = INVALID_HANDLE_VALUE then Exit;
  try
    if TryLockAtomicFile(Handle) then DeleteOpened(Handle);
  finally
    CloseHandle(Handle);
  end;
end;

procedure RemoveStageItem(const Path, Name: string; Attributes: DWORD);
var Handle: THandle; Number: Integer;
begin
  if not TryStrToInt(Name, Number) or (Number <= 0) then Exit;
  Handle := OpenOwned(Path, False, FileDeleteAccess);
  if Handle = INVALID_HANDLE_VALUE then Exit;
  try
    DeleteOpened(Handle);
  finally
    CloseHandle(Handle);
  end;
end;

procedure RemoveStage(const Path, Name: string; Attributes: DWORD);
var Directory, Owner: THandle; Lock: TOverlapped; Before, After: TByHandleFileInformation;
begin
  if not ValidTemporaryName(Name, '.scu-stage-') then Exit;
  Directory := OpenOwned(Path, True, 0);
  if Directory = INVALID_HANDLE_VALUE then Exit;
  try
    if not GetFileInformationByHandle(Directory, Before) then Exit;
    Owner := OpenOwned(IncludeTrailingPathDelimiter(Path) + '.owner', False, GENERIC_READ or FileDeleteAccess);
    if Owner = INVALID_HANDLE_VALUE then Exit;
    try
      // The future Windows lock backend must use byte zero on sidecar files.
      // A stage without a valid ownership marker is never removed.
      FillChar(Lock, SizeOf(Lock), 0);
      if not LockFileEx(Owner, LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, Lock) then Exit;
      if not Visit(Path, '*', @RemoveStageItem) then Exit;
      DeleteOpened(Owner);
    finally
      CloseHandle(Owner);
    end;
  finally
    CloseHandle(Directory);
  end;
  // FindFirstFile may omit delete sharing, so the enumeration guard cannot
  // request DELETE access. Reopen after enumeration and verify identity before
  // marking the original directory for deletion. Never recurse into children.
  Directory := OpenOwned(Path, True, FileDeleteAccess);
  if Directory = INVALID_HANDLE_VALUE then Exit;
  try
    if GetFileInformationByHandle(Directory, After) and
      (Before.dwVolumeSerialNumber = After.dwVolumeSerialNumber) and
      (Before.nFileIndexHigh = After.nFileIndexHigh) and
      (Before.nFileIndexLow = After.nFileIndexLow) then DeleteOpened(Directory);
  finally
    CloseHandle(Directory);
  end;
end;

procedure CleanupWindowsAtomicFiles(const Directory: string);
begin
  Visit(Directory, '.scu-stage-*', @RemoveStage);
  Visit(Directory, '.scu-tmp-*', @RemoveTemporary);
end;

end.
