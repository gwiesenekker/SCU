unit ScuPlatformAuditActorWindows;
{$mode objfpc}{$H+}
interface
uses FPJSON;
procedure AddAuditActor(Event: TJSONObject);
implementation
uses Windows, SysUtils, ScuErrors;
function SidText(Sid: PSID; out Text: PWideChar): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertSidToStringSidW';
function EffectiveToken(out Source: string): THandle;
var Error: DWORD;
begin
  // OpenAsSelf changes the access check, not the identity being queried.
  if OpenThreadToken(GetCurrentThread, TOKEN_QUERY, True, Result) then
  begin Source := 'thread'; Exit; end;
  Error := GetLastError;
  if Error <> ERROR_NO_TOKEN then
    RaiseSystemError('Could not read Windows audit thread token', Error);
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Result) then
    RaiseSystemError('Could not read Windows audit process token', GetLastError);
  Source := 'process';
end;
function EffectiveSID(out Source: string): string;
var Token: THandle; Buffer: TBytes; Needed, Error: DWORD; Text: PWideChar;
begin
  Token := EffectiveToken(Source);
  try
    Needed := 0;
    if not GetTokenInformation(Token, TokenUser, nil, 0, Needed) then
    begin
      Error := GetLastError;
      if Error <> ERROR_INSUFFICIENT_BUFFER then
        RaiseSystemError('Could not size Windows audit identity', Error);
    end;
    if Needed < SizeOf(TTokenUser) then
      raise EScuError.Create('Invalid Windows audit token-user size.');
    SetLength(Buffer, Needed);
    if not GetTokenInformation(Token, TokenUser, @Buffer[0], Length(Buffer), Needed) then
      RaiseSystemError('Could not read Windows audit identity', GetLastError);
    if not SidText(PTokenUser(@Buffer[0])^.User.Sid, Text) then
      RaiseSystemError('Could not format Windows audit SID', GetLastError);
    try Result := UTF8Encode(UnicodeString(Text));
    finally LocalFree(HLOCAL(Text)); end;
  finally CloseHandle(Token); end;
end;
procedure AddAuditActor(Event: TJSONObject);
var Source, SID: string; Actor: TJSONObject;
begin
  // Resolve at record time: impersonation may change between calls. SID queries
  // are local; do not introduce a domain lookup or cache a process-only user.
  SID := EffectiveSID(Source);
  Actor := TJSONObject.Create;
  Event.Add('actor', Actor);
  Actor.Add('platform', 'windows');
  Actor.Add('sid', SID);
  Actor.Add('token_source', Source);
end;
end.
