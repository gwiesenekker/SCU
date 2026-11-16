unit ScuWindowsDelete;
{$mode objfpc}{$H+}{$packrecords c}
interface
uses Windows;
function DeleteOpenedFile(Handle: THandle; ClearPrivateReadOnly: Boolean): Boolean;
implementation
type
  TBasicInfo = record
    CreationTime, LastAccessTime, LastWriteTime, ChangeTime: Int64;
    Attributes: DWORD;
  end;
  TDispositionInfo = record DeleteFile: Byte; end;
function SetInformation(Handle: THandle; Kind: Integer; Data: Pointer; Size: DWORD): BOOL;
  stdcall; external 'kernel32.dll' name 'SetFileInformationByHandle';
function DeleteOpenedFile(Handle: THandle; ClearPrivateReadOnly: Boolean): Boolean;
var Disposition: TDispositionInfo; Info: TByHandleFileInformation; Basic: TBasicInfo;
begin
  Disposition.DeleteFile := 1;
  Result := SetInformation(Handle, 4, @Disposition, SizeOf(Disposition));
  if Result or not ClearPrivateReadOnly then Exit;
  if not GetFileInformationByHandle(Handle, Info) then Exit;
  // File attributes belong to the shared file, not an individual hard link.
  // Do not alter a hard-linked or reparse object's attributes to remove it.
  if (Info.nNumberOfLinks > 1) or
    ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) or
    ((Info.dwFileAttributes and FILE_ATTRIBUTE_READONLY) = 0) then Exit;
  FillChar(Basic, SizeOf(Basic), 0);
  Basic.Attributes := Info.dwFileAttributes and not FILE_ATTRIBUTE_READONLY;
  if Basic.Attributes = 0 then Basic.Attributes := FILE_ATTRIBUTE_NORMAL;
  if not SetInformation(Handle, 0, @Basic, SizeOf(Basic)) then Exit;
  Result := SetInformation(Handle, 4, @Disposition, SizeOf(Disposition));
  if not Result then
  begin
    Basic.Attributes := Info.dwFileAttributes;
    SetInformation(Handle, 0, @Basic, SizeOf(Basic));
  end;
end;
end.
