unit ScuWindowsEditCleanup;
{$mode objfpc}{$H+}{$packrecords c}
interface
procedure RemoveEditorDirectory(const Path: string);
implementation
uses Windows, SysUtils, ScuPlatformPathsWindows, ScuPlatformFileSecurityWindows,
  ScuWindowsDelete;
type
  TNativeString = record Length, MaximumLength: Word; Buffer: PWideChar; end;
  TObjectAttributes = record
    Length: ULONG; RootDirectory: THandle; ObjectName: ^TNativeString;
    Attributes: ULONG; SecurityDescriptor, SecurityQualityOfService: Pointer;
  end;
  TIOStatus = record Status: PtrInt; Information: PtrUInt; end;
  TNameInfo = record NextOffset, FileIndex, NameLength: ULONG; end;
function OpenRelative(out Handle: THandle; Access: DWORD; Attributes: Pointer;
  out Status: TIOStatus; Sharing, Options: ULONG): LongInt; stdcall;
  external 'ntdll.dll' name 'NtOpenFile';
function QueryNames(Handle, Event: THandle; Routine, Context: Pointer;
  out Status: TIOStatus; Buffer: Pointer; Size, Kind: ULONG;
  SingleEntry: Byte; Name: Pointer; Restart: Byte): LongInt; stdcall;
  external 'ntdll.dll' name 'NtQueryDirectoryFile';
const
  SyncAccess = DWORD($00100000);
  OpenSynchronous = $20;
  OpenForBackup = $4000;
  OpenLink = $00200000;
  NoMoreFiles = DWORD($80000006);
  CleanupAccess = GENERIC_READ or FileDeleteAccess or FILE_WRITE_ATTRIBUTES or FileReadControl or SyncAccess;

function OpenChild(Parent: THandle; const Name: UnicodeString): THandle;
var Text: TNativeString; Attributes: TObjectAttributes; Status: TIOStatus;
begin
  Result := INVALID_HANDLE_VALUE;
  if (Name = '') or (Name = '.') or (Name = '..') or
    (Pos('\', Name) > 0) or (Pos('/', Name) > 0) or (Pos(#0, Name) > 0) then Exit;
  Text.Length := Length(Name) * SizeOf(WideChar);
  Text.MaximumLength := Text.Length;
  Text.Buffer := PWideChar(Name);
  FillChar(Attributes, SizeOf(Attributes), 0);
  Attributes.Length := SizeOf(Attributes);
  Attributes.RootDirectory := Parent;
  Attributes.ObjectName := @Text;
  // Native relative opens keep traversal anchored to the inspected parent;
  // no case folding is needed for names returned by that directory itself.
  if OpenRelative(Result, CleanupAccess, @Attributes, Status,
    FILE_SHARE_READ or FILE_SHARE_WRITE, OpenLink or OpenSynchronous or OpenForBackup) < 0 then
    Result := INVALID_HANDLE_VALUE;
end;

procedure RemoveContents(Directory: THandle; Depth: Integer); forward;
procedure RemoveChild(Parent: THandle; const Name: UnicodeString; Depth: Integer);
var Child: THandle; Info: TByHandleFileInformation;
begin
  Child := OpenChild(Parent, Name);
  if Child = INVALID_HANDLE_VALUE then Exit;
  try
    if (GetFileType(Child) <> FILE_TYPE_DISK) or
      not GetFileInformationByHandle(Child, Info) then Exit;
    if ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
      ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) = 0) then
    begin
      if Depth >= 128 then Exit;
      RemoveContents(Child, Depth + 1);
    end;
    // A reparse entry is only unlinked; never enumerate its target.
    DeleteOpenedFile(Child, True);
  finally
    CloseHandle(Child);
  end;
end;
procedure RemoveContents(Directory: THandle; Depth: Integer);
var Buffer: TBytes; Status: TIOStatus; Code: LongInt; Offset: SizeUInt;
  Entry: ^TNameInfo; Name: UnicodeString;
begin
  SetLength(Buffer, 65536);
  repeat
    Code := QueryNames(Directory, 0, nil, nil, Status, @Buffer[0], Length(Buffer),
      12 {FileNamesInformation}, 0, nil, 0);
    if (DWORD(Code) = NoMoreFiles) or (Code < 0) or (Status.Information = 0) then Exit;
    if Status.Information > SizeUInt(Length(Buffer)) then Exit;
    Offset := 0;
    repeat
      if Status.Information - Offset < SizeOf(TNameInfo) then Exit;
      Entry := Pointer(@Buffer[Offset]);
      if Odd(Entry^.NameLength) or (Entry^.NameLength > Status.Information - Offset - SizeOf(TNameInfo)) then Exit;
      SetString(Name, PWideChar(@Buffer[Offset + SizeOf(TNameInfo)]), Entry^.NameLength div 2);
      RemoveChild(Directory, Name, Depth);
      if Entry^.NextOffset = 0 then Break;
      if (Entry^.NextOffset < SizeOf(TNameInfo)) or (Entry^.NextOffset >= Status.Information - Offset) then Exit;
      Inc(Offset, Entry^.NextOffset);
    until False;
  until False;
end;
procedure RemoveEditorDirectory(const Path: string);
var Handle: THandle; Info: TByHandleFileInformation;
begin
  // This runs in a finally block. Cleanup must never replace editor failures,
  // consume cancellation, or turn a successful edit into a command failure.
  try
    Handle := CreateFileW(PWideChar(NativeFilePath(ExcludeTrailingPathDelimiter(Path))), CleanupAccess,
      FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
      OpenReparsePoint or FILE_FLAG_BACKUP_SEMANTICS, 0);
    if Handle = INVALID_HANDLE_VALUE then Exit;
    try
      if (GetFileType(Handle) <> FILE_TYPE_DISK) or
        not GetFileInformationByHandle(Handle, Info) or
        ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0) or
        ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) or
        not IsCurrentUserOwned(Handle) then Exit;
      RemoveContents(Handle, 0);
      DeleteOpenedFile(Handle, True);
    finally
      CloseHandle(Handle);
    end;
  except
    // Leave blocked/uninspectable entries for manual cleanup, as on Linux.
  end;
end;
end.
