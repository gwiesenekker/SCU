unit ScuPlatformFilesWindows;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, ScuFileTypes;

function FileEntryExists(const Path: string): Boolean;
function RegularFileExists(const Path: string): Boolean;
function IsSQLiteFile(const Path: string): Boolean;
procedure CleanupStaleAtomicFiles(const Directory: string);
function OpenReadFile(const Path: string): TStream;
function ReadBytes(const Path: string; Limit: Int64; Options: TReadBytesOptions): RawByteString;
procedure AtomicWrite(const Path: string; Data: TStream; Options: TAtomicWriteOptions);
function MakeTempDirectory(const Prefix: string): string;
function MakeStagingDirectory(const Directory: string): string;
procedure SyncFile(Handle: THandle; const Path: string);
procedure SyncParent(const Path: string);

implementation

uses Windows, ScuErrors, ScuPlatformPathsWindows, ScuPlatformFileSecurityWindows,
  ScuPlatformFileCleanupWindows;

const
  MoveWriteThrough = DWORD($00000008); // MOVEFILE_WRITE_THROUGH in the Windows SDK.
  ShareAll = FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE;

function InspectFile(Handle: THandle; const Path: string; NoFollow: Boolean): TByHandleFileInformation;
begin
  if GetFileType(Handle) <> FILE_TYPE_DISK then
    raise EScuError.CreateFmt('Expected a regular file: %s', [Path]);
  if not GetFileInformationByHandle(Handle, Result) then
    RaiseSystemError('Could not inspect opened file "' + Path + '"', GetLastError);
  if NoFollow and ((Result.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
    raise EScuError.Create('Refusing to read a symbolic link or reparse point: "' + Path + '".');
  if (GetFileType(Handle) <> FILE_TYPE_DISK) or
    ((Result.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0) then
    raise EScuError.CreateFmt('Expected a regular file: %s', [Path]);
end;

function OpenRead(const Path: string; NoFollow: Boolean): THandle;
var Flags: DWORD;
begin
  Flags := FILE_FLAG_BACKUP_SEMANTICS;
  if NoFollow then Flags := Flags or OpenReparsePoint;
  Result := CreateFileW(PWideChar(NativeFilePath(Path)), GENERIC_READ, ShareAll,
    nil, OPEN_EXISTING, Flags, 0);
end;

type
  TOwnedReadStream = class(THandleStream)
    destructor Destroy; override;
  end;
destructor TOwnedReadStream.Destroy;
begin
  CloseHandle(Handle);
  inherited Destroy;
end;
function OpenReadFile(const Path: string): TStream;
var Handle: THandle;
begin
  Handle := OpenRead(Path, True);
  if Handle = INVALID_HANDLE_VALUE then
    RaiseSystemError('Could not open ' + Path, GetLastError);
  try
    InspectFile(Handle, Path, True);
    Result := TOwnedReadStream.Create(Handle);
    Handle := INVALID_HANDLE_VALUE;
  finally
    if Handle <> INVALID_HANDLE_VALUE then CloseHandle(Handle);
  end;
end;

function FileEntryExists(const Path: string): Boolean;
var Attributes, Error: DWORD;
begin
  if Path = '' then Exit(False);
  Attributes := GetFileAttributesW(PWideChar(NativeFilePath(Path)));
  if Attributes <> INVALID_FILE_ATTRIBUTES then Exit(True);
  Error := GetLastError;
  if not (Error in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND]) then
    RaiseSystemError('Could not inspect "' + Path + '"', Error);
  Result := False;
end;

function RegularFileExists(const Path: string): Boolean;
var Handle: THandle; Error: DWORD;
begin
  if Path = '' then Exit(False);
  Handle := CreateFileW(PWideChar(NativeFilePath(Path)), 0, ShareAll, nil,
    OPEN_EXISTING, OpenReparsePoint or FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then
  begin
    Error := GetLastError;
    if Error in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND] then Exit(False);
    RaiseSystemError('Could not inspect "' + Path + '"', Error);
  end;
  try
    InspectFile(Handle, Path, False);
    Result := True;
  finally
    CloseHandle(Handle);
  end;
end;

function ReadBytes(const Path: string; Limit: Int64; Options: TReadBytesOptions): RawByteString;
var
  Handle: THandle;
  Info: TByHandleFileInformation;
  Size: QWord;
  Stream: THandleStream;
begin
  Handle := OpenRead(Path, rbNoFollow in Options);
  if Handle = INVALID_HANDLE_VALUE then RaiseSystemError('Could not open ' + Path, GetLastError);
  try
    Info := InspectFile(Handle, Path, rbNoFollow in Options);
    Size := (QWord(Info.nFileSizeHigh) shl 32) or Info.nFileSizeLow;
    if (Limit < 0) or (Size > QWord(Limit)) or (Size > QWord(High(SizeInt))) then
      raise EScuError.CreateFmt('File exceeds the %d-byte limit: %s', [Limit, Path]);
    SetLength(Result, SizeInt(Size));
    if Result <> '' then
    begin
      Stream := THandleStream.Create(Handle);
      try
        try
          Stream.ReadBuffer(Result[1], Length(Result));
        except
          on E: EStreamError do
            raise EScuError.CreateFmt('Could not read "%s": %s', [Path, E.Message]);
        end;
      finally
        Stream.Free;
      end;
    end;
  finally
    CloseHandle(Handle);
  end;
end;

function IsSQLiteFile(const Path: string): Boolean;
const Header: array[0..15] of AnsiChar = 'SQLite format 3'#0;
var Handle: THandle; Magic: array[0..15] of AnsiChar; Count: DWORD;
begin
  Result := False;
  if Path = '' then Exit;
  Handle := OpenRead(Path, True);
  if Handle = INVALID_HANDLE_VALUE then Exit;
  try
    // Probing storage candidates must not follow links or block on devices.
    try
      InspectFile(Handle, Path, True);
    except
      on E: EScuError do Exit;
    end;
    if Windows.ReadFile(Handle, Magic, SizeOf(Magic), Count, nil) and (Count = SizeOf(Magic)) then
      Result := CompareByte(Magic, Header, SizeOf(Header)) = 0;
  finally
    CloseHandle(Handle);
  end;
end;

function UniqueTail: string;
var Identifier: TGUID;
begin
  if CreateGUID(Identifier) <> 0 then raise EScuError.Create('Could not generate a temporary filename.');
  Result := StringReplace(Copy(GUIDToString(Identifier), 2, 36), '-', '', [rfReplaceAll]);
end;

function PrivateDirectory(const Directory, Prefix: string): string;
var
  Attributes: TSecurityAttributes;
  Descriptor: PSecurityDescriptor;
  Attempt: Integer;
  Error: DWORD;
begin
  PrivateSecurity(Attributes, Descriptor);
  try
    for Attempt := 1 to 32 do
    begin
      Result := IncludeTrailingPathDelimiter(Directory) + Prefix + UniqueTail;
      if CreateDirectoryW(PWideChar(NativeFilePath(Result)), @Attributes) then Exit;
      Error := GetLastError;
      if Error <> ERROR_ALREADY_EXISTS then
        RaiseSystemError('Could not create temporary directory "' + Result + '"', Error);
    end;
    raise EScuError.Create('Could not allocate a unique temporary directory in "' + Directory + '".');
  finally
    LocalFree(HLOCAL(Descriptor));
  end;
end;

function MakeTempDirectory(const Prefix: string): string;
var Buffer: UnicodeString; Count: DWORD;
begin
  if (Pos('/', Prefix) <> 0) or (Pos('\', Prefix) <> 0) or (Pos(':', Prefix) <> 0) then
    raise EScuError.Create('Expected a temporary-directory prefix without path components.');
  SetLength(Buffer, 32768);
  Count := GetTempPathW(Length(Buffer), PWideChar(Buffer));
  if (Count = 0) or (Count >= DWORD(Length(Buffer))) then
    RaiseSystemError('Could not locate the temporary directory', GetLastError);
  SetLength(Buffer, Count);
  Result := PrivateDirectory(UTF8Encode(Buffer), Prefix + '-');
end;

function MakeStagingDirectory(const Directory: string): string;
begin
  Result := PrivateDirectory(Directory, '.scu-stage-' + IntToStr(GetCurrentProcessId) + '-');
end;

procedure SyncFile(Handle: THandle; const Path: string);
begin
  if not FlushFileBuffers(Handle) then RaiseSystemError('Could not sync "' + Path + '"', GetLastError);
end;

procedure SyncParent(const Path: string);
begin
  // Win32 has no supported directory-fsync equivalent. Validate the parent;
  // AtomicWrite uses FlushFileBuffers followed by a write-through rename.
  ResolveDirectory(ExtractFileDir(AbsolutePath(Path)));
end;

function CreateTemporaryOutput(const Directory: string; PrivateFile: Boolean; out Path: string): THandle;
var
  Attributes: TSecurityAttributes;
  Descriptor: PSecurityDescriptor;
  Security: PSecurityAttributes;
  Attempt: Integer;
  Error: DWORD;
begin
  Descriptor := nil;
  Security := nil;
  if PrivateFile then
  begin
    PrivateSecurity(Attributes, Descriptor);
    Security := @Attributes;
  end;
  try
    for Attempt := 1 to 32 do
    begin
      Path := IncludeTrailingPathDelimiter(Directory) + '.scu-tmp-' + IntToStr(GetCurrentProcessId) + '-' + UniqueTail;
      Result := CreateFileW(PWideChar(NativeFilePath(Path)), GENERIC_READ or GENERIC_WRITE or WRITE_DAC or FileDeleteAccess,
        ShareAll, Security, CREATE_NEW, FILE_ATTRIBUTE_NORMAL or FILE_FLAG_WRITE_THROUGH, 0);
      if Result <> INVALID_HANDLE_VALUE then Exit;
      Error := GetLastError;
      if (Error <> ERROR_FILE_EXISTS) and (Error <> ERROR_ALREADY_EXISTS) then
        RaiseSystemError('Could not create temporary file in ' + Directory, Error);
    end;
    raise EScuError.Create('Could not allocate a unique temporary file in ' + Directory);
  finally
    if Descriptor <> nil then LocalFree(HLOCAL(Descriptor));
  end;
end;

procedure PreserveSourceAccess(const Path: string; Destination: THandle);
var Source: THandle; Info: TByHandleFileInformation; Error: DWORD;
begin
  Source := CreateFileW(PWideChar(NativeFilePath(Path)), FileReadControl, ShareAll,
    nil, OPEN_EXISTING, OpenReparsePoint or FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Source = INVALID_HANDLE_VALUE then
  begin
    Error := GetLastError;
    if Error in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND] then Exit;
    RaiseSystemError('Could not inspect source permissions for "' + Path + '"', Error);
  end;
  try
    if not GetFileInformationByHandle(Source, Info) then
      RaiseSystemError('Could not inspect source permissions for "' + Path + '"', GetLastError);
    if (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) = 0 then
      CopyFileAccess(Source, Destination, Path);
  finally
    CloseHandle(Source);
  end;
end;

procedure CommitOutput(const TemporaryPath, Path: string; NoReplace: Boolean);
var Flags, Error: DWORD; Attempt: Integer;
begin
  Flags := MoveWriteThrough;
  if not NoReplace then Flags := Flags or MOVEFILE_REPLACE_EXISTING;
  for Attempt := 1 to 6 do
  begin
    // Temporary file and destination share a directory. Never permit a
    // cross-volume copy/delete fallback, nor delete the destination first.
    if MoveFileExW(PWideChar(NativeFilePath(TemporaryPath)), PWideChar(NativeFilePath(Path)), Flags) then Exit;
    Error := GetLastError;
    if ((Error <> ERROR_SHARING_VIOLATION) and (Error <> ERROR_ACCESS_DENIED)) or
      (Attempt = 6) then
      RaiseSystemError('Could not commit output "' + Path + '" (check permissions or close applications holding the file open)', Error);
    Sleep(20);
  end;
end;

procedure AtomicWrite(const Path: string; Data: TStream; Options: TAtomicWriteOptions);
var
  TemporaryPath: string;
  Handle: THandle;
  Stream: THandleStream;
begin
  TemporaryPath := '';
  Handle := CreateTemporaryOutput(ExtractFileDir(AbsolutePath(Path)),
    not (awSourceOutput in Options), TemporaryPath);
  try
    if not TryLockAtomicFile(Handle) then
      RaiseSystemError('Could not lock temporary output "' + TemporaryPath + '"', GetLastError);
    Stream := THandleStream.Create(Handle);
    try
      try
        if Data.Size > Data.Position then Stream.CopyFrom(Data, Data.Size - Data.Position);
      except
        on E: EStreamError do
          raise EScuError.CreateFmt('Could not write "%s": %s', [Path, E.Message]);
      end;
    finally
      Stream.Free;
    end;
    if (awSourceOutput in Options) and not (awNoReplace in Options) then PreserveSourceAccess(Path, Handle);
    SyncFile(Handle, TemporaryPath);
    // Keep the handle and cleanup lock alive across the rename. All SCU
    // read/temporary handles permit FILE_SHARE_DELETE for this operation.
    CommitOutput(TemporaryPath, Path, awNoReplace in Options);
    TemporaryPath := '';
  finally
    if TemporaryPath <> '' then DiscardAtomicFile(Handle);
    CloseHandle(Handle);
  end;
end;

procedure CleanupStaleAtomicFiles(const Directory: string);
begin
  CleanupWindowsAtomicFiles(Directory);
end;

end.
