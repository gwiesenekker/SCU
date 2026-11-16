unit ScuPlatformFileSecurityWindows;

{$mode objfpc}{$H+}

interface

uses Windows;

const
  FileReadControl = DWORD($00020000);
  FileDeleteAccess = DWORD($00010000);
  OpenReparsePoint = DWORD($00200000);

// Private control files/directories grant access to the current user and SYSTEM.
procedure PrivateSecurity(out Attributes: TSecurityAttributes; out Descriptor: PSecurityDescriptor);
procedure CopyFileAccess(Source, Destination: THandle; const Path: string);
function IsPrivateOwnedDirectory(Handle: THandle): Boolean;
function IsCurrentUserOwned(Handle: THandle): Boolean;

implementation

uses SysUtils, ScuErrors;

function ConvertDescriptor(Text: PWideChar; Revision: DWORD;
  out Descriptor: PSecurityDescriptor; Size: Pointer): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

function SidText(Sid: PSID; out Text: PWideChar): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertSidToStringSidW';

function CurrentUser: TBytes;
var Token: THandle; Needed: DWORD;
begin
  Result := nil;
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Token) then
    RaiseSystemError('Could not inspect the current user', GetLastError);
  try
    Needed := 0;
    GetTokenInformation(Token, TokenUser, nil, 0, Needed);
    if Needed = 0 then RaiseSystemError('Could not inspect the current user', GetLastError);
    SetLength(Result, Needed);
    if not GetTokenInformation(Token, TokenUser, @Result[0], Needed, Needed) then
      RaiseSystemError('Could not inspect the current user', GetLastError);
  finally
    CloseHandle(Token);
  end;
end;

procedure PrivateSecurity(out Attributes: TSecurityAttributes; out Descriptor: PSecurityDescriptor);
var User: TBytes; Sid: PWideChar; Text: UnicodeString;
begin
  Descriptor := nil;
  User := CurrentUser;
  if not SidText(PTokenUser(@User[0])^.User.Sid, Sid) then
    RaiseSystemError('Could not identify the current user', GetLastError);
  try
    Text := 'O:' + UnicodeString(Sid) + 'D:P(A;;FA;;;' + UnicodeString(Sid) + ')(A;;FA;;;SY)';
    if not ConvertDescriptor(PWideChar(Text), 1, Descriptor, nil) then
      RaiseSystemError('Could not create private file permissions', GetLastError);
  finally
    LocalFree(HLOCAL(Sid));
  end;
  FillChar(Attributes, SizeOf(Attributes), 0);
  Attributes.nLength := SizeOf(Attributes);
  Attributes.lpSecurityDescriptor := Descriptor;
end;

function ObjectSecurity(Handle: THandle; Information: DWORD; const Action: string): TBytes;
var Needed: DWORD;
begin
  Result := nil;
  Needed := 0;
  if not GetKernelObjectSecurity(Handle, Information, nil, 0, @Needed) and
    (GetLastError <> ERROR_INSUFFICIENT_BUFFER) then
    RaiseSystemError(Action, GetLastError);
  SetLength(Result, Needed);
  if not GetKernelObjectSecurity(Handle, Information, PSecurityDescriptor(@Result[0]),
    Needed, @Needed) then
    RaiseSystemError(Action, GetLastError);
end;

procedure CopyFileAccess(Source, Destination: THandle; const Path: string);
var Descriptor: TBytes; Control: SECURITY_DESCRIPTOR_CONTROL; Revision, Information: DWORD;
begin
  Descriptor := ObjectSecurity(Source, DACL_SECURITY_INFORMATION,
    'Could not read permissions for "' + Path + '"');
  if not GetSecurityDescriptorControl(PSecurityDescriptor(@Descriptor[0]), @Control, @Revision) then
    RaiseSystemError('Could not inspect permission inheritance for "' + Path + '"', GetLastError);
  Information := DACL_SECURITY_INFORMATION;
  if (Control and $1000 {SE_DACL_PROTECTED}) <> 0 then
    Information := Information or DWORD($80000000) {PROTECTED_DACL_SECURITY_INFORMATION}
  else Information := Information or DWORD($20000000) {UNPROTECTED_DACL_SECURITY_INFORMATION};
  if not SetKernelObjectSecurity(Destination, Information,
    PSecurityDescriptor(@Descriptor[0])) then
    RaiseSystemError('Could not preserve permissions for "' + Path + '"', GetLastError);
end;

function StringSid(Text: PWideChar; out Sid: PSID): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertStringSidToSidW';
function IsPrivateOwnedDirectory(Handle: THandle): Boolean;
const WriteRights = DWORD($500D0156); // generic all/write, mutation/delete/DACL/owner rights.
var Descriptor: TBytes; Owner, SystemSid, AdminSid: PSID;
  Present, Defaulted: BOOL; ACL: PACL; Ace: Pointer; Index: Integer;
begin
  Result := False; SystemSid := nil; AdminSid := nil;
  if not IsCurrentUserOwned(Handle) then Exit;
  Descriptor := ObjectSecurity(Handle, OWNER_SECURITY_INFORMATION or DACL_SECURITY_INFORMATION,
    'Could not inspect state directory permissions');
  if not GetSecurityDescriptorOwner(PSecurityDescriptor(@Descriptor[0]), Owner, @Defaulted) or
    not GetSecurityDescriptorDacl(PSecurityDescriptor(@Descriptor[0]), @Present, ACL, @Defaulted) or
    not Present or (ACL = nil) then Exit;
  if not StringSid('S-1-5-18', SystemSid) then RaiseSystemError('Could not identify SYSTEM', GetLastError);
  try
    if not StringSid('S-1-5-32-544', AdminSid) then RaiseSystemError('Could not identify Administrators', GetLastError);
    for Index := 0 to ACL^.AceCount - 1 do
    begin
      if not GetAce(ACL, Index, Ace) then Exit;
      // Refuse unfamiliar grant types rather than overlooking object/callback ACEs.
      if PACCESS_ALLOWED_ACE(Ace)^.Header.AceType = 1 {ACCESS_DENIED_ACE_TYPE} then Continue;
      if PACCESS_ALLOWED_ACE(Ace)^.Header.AceType <> 0 {ACCESS_ALLOWED_ACE_TYPE} then Exit;
      if (PACCESS_ALLOWED_ACE(Ace)^.Mask and WriteRights) <> 0 then
        if not EqualSid(PSID(@PACCESS_ALLOWED_ACE(Ace)^.SidStart), Owner) and
          not EqualSid(PSID(@PACCESS_ALLOWED_ACE(Ace)^.SidStart), SystemSid) and
          not EqualSid(PSID(@PACCESS_ALLOWED_ACE(Ace)^.SidStart), AdminSid) then Exit;
    end;
    Result := True;
  finally
    if AdminSid <> nil then LocalFree(HLOCAL(AdminSid));
    LocalFree(HLOCAL(SystemSid));
  end;
end;

function IsCurrentUserOwned(Handle: THandle): Boolean;
var
  Descriptor, User: TBytes;
  Owner: PSID;
  Defaulted: BOOL;
begin
  Result := False;
  // Cleanup is deliberately conservative when ownership cannot be established.
  try
    Descriptor := ObjectSecurity(Handle, OWNER_SECURITY_INFORMATION, 'Could not read file ownership');
    if not GetSecurityDescriptorOwner(PSecurityDescriptor(@Descriptor[0]), Owner, @Defaulted) then Exit;
    User := CurrentUser;
    Result := EqualSid(Owner, PTokenUser(@User[0])^.User.Sid);
  except
    on E: EScuSystemError do Result := False;
  end;
end;

end.
