unit ScuPlatformProcessHandlesWindows;
{$mode objfpc}{$H+}
interface
uses Windows;
type
  TStartupInfoExtended = record
    Startup: TStartupInfoW;
    Attributes: Pointer;
  end;
  TChildHandles = class
  private
    FHandles: array[0..2] of THandle;
    FInfo: TStartupInfoExtended;
    FInitialized: Boolean;
    function CopyStandard(ID: DWORD; NullHandle: Boolean): THandle;
  public
    constructor Create(NullInput: Boolean);
    destructor Destroy; override;
    property Info: TStartupInfoExtended read FInfo;
  end;
implementation
uses SysUtils, ScuErrors;
function InitAttributes(List: Pointer; Count, Flags: DWORD; var Size: PtrUInt): BOOL; stdcall; external 'kernel32.dll' name 'InitializeProcThreadAttributeList';
function UpdateAttribute(List: Pointer; Flags: DWORD; Attribute: PtrUInt; Value: Pointer;
  Size: PtrUInt; Previous, Returned: Pointer): BOOL; stdcall; external 'kernel32.dll' name 'UpdateProcThreadAttribute';
procedure DeleteAttributes(List: Pointer); stdcall; external 'kernel32.dll' name 'DeleteProcThreadAttributeList';
function TChildHandles.CopyStandard(ID: DWORD; NullHandle: Boolean): THandle;
var Source: THandle; Access: DWORD; Owns: Boolean;
begin
  Source := GetStdHandle(ID); Owns := NullHandle or (Source = 0) or (Source = INVALID_HANDLE_VALUE);
  if Owns then
  begin
    if ID = STD_INPUT_HANDLE then Access := GENERIC_READ else Access := GENERIC_WRITE;
    Source := CreateFileW('NUL', Access, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
    if Source = INVALID_HANDLE_VALUE then RaiseSystemError('Could not open child NUL stream', GetLastError);
  end;
  try
    if not DuplicateHandle(GetCurrentProcess, Source, GetCurrentProcess, @Result, 0, True, DUPLICATE_SAME_ACCESS) then
      RaiseSystemError('Could not duplicate child standard handle', GetLastError);
  finally
    if Owns then CloseHandle(Source);
  end;
end;
constructor TChildHandles.Create(NullInput: Boolean);
var Size: PtrUInt;
begin
  inherited Create;
  FHandles[0] := CopyStandard(STD_INPUT_HANDLE, NullInput);
  FHandles[1] := CopyStandard(STD_OUTPUT_HANDLE, False);
  FHandles[2] := CopyStandard(STD_ERROR_HANDLE, False);
  Size := 0; InitAttributes(nil, 1, 0, Size);
  if Size = 0 then RaiseSystemError('Could not size child handle list', GetLastError);
  GetMem(FInfo.Attributes, Size);
  if not InitAttributes(FInfo.Attributes, 1, 0, Size) then
    RaiseSystemError('Could not create child handle list', GetLastError);
  FInitialized := True;
  if not UpdateAttribute(FInfo.Attributes, 0, $20002, @FHandles, SizeOf(FHandles), nil, nil) then
    RaiseSystemError('Could not restrict child handle inheritance', GetLastError);
  FInfo.Startup.cb := SizeOf(FInfo);
  FInfo.Startup.dwFlags := STARTF_USESTDHANDLES;
  FInfo.Startup.hStdInput := FHandles[0]; FInfo.Startup.hStdOutput := FHandles[1]; FInfo.Startup.hStdError := FHandles[2];
end;
destructor TChildHandles.Destroy;
var Handle: THandle;
begin
  if FInitialized then DeleteAttributes(FInfo.Attributes);
  if FInfo.Attributes <> nil then FreeMem(FInfo.Attributes);
  for Handle in FHandles do if Handle <> 0 then CloseHandle(Handle);
  inherited Destroy;
end;
end.
