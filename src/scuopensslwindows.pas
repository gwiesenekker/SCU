unit ScuOpenSSLWindows;
{$mode objfpc}{$H+}
interface
function WindowsDigest(const Data: RawByteString; SHA256: Boolean): string;
implementation
uses CTypes, ScuWindowsDLL, ScuErrors;
type
  TDigest = function(Data: Pointer; Size: csize_t; Digest: PByte): PByte; cdecl;
  TVersion = function: culong; cdecl;
  TInitialize = function(Options: QWord; Settings: Pointer): cint; cdecl;
  TCryptoAPI = record SHA1, SHA256: TDigest; end;
var Guard: TRTLCriticalSection; Ready: LongInt; Module: TWindowsDLL; API: TCryptoAPI;
procedure EnsureOpenSSL;
var Candidate: TWindowsDLL; Loaded: TCryptoAPI; Version: TVersion;
  Initialize: TInitialize; Number: culong;
begin
  if System.InterlockedCompareExchange(Ready, 0, 0) = 1 then Exit;
  EnterCriticalSection(Guard);
  try
    if Ready = 1 then Exit;
    Candidate := TWindowsDLL.Create('OpenSSL 3',
      [{$IFDEF CPUX86_64}'libcrypto-3-x64.dll',{$ENDIF}'libcrypto-3.dll']);
    try
      Pointer(Version) := Candidate.Require('OpenSSL_version_num');
      Number := Version();
      if (Number < $30000000) or (Number >= $40000000) then
        raise EScuError.Create('OpenSSL DLL "' + Candidate.Path + '" requires OpenSSL major version 3.');
      Pointer(Initialize) := Candidate.Require('OPENSSL_init_crypto');
      Pointer(Loaded.SHA1) := Candidate.Require('SHA1');
      Pointer(Loaded.SHA256) := Candidate.Require('SHA256');
      // Checksums require only the built-in default provider. Do not load an
      // external openssl.cnf/provider from OPENSSL_CONF/OPENSSL_MODULES.
      if Initialize($80 {OPENSSL_INIT_NO_LOAD_CONFIG}, nil) <> 1 then
        raise EScuError.Create('Could not initialize OpenSSL DLL "' + Candidate.Path + '".');
      API := Loaded;
      Module := Candidate; Candidate := nil;
      System.InterlockedExchange(Ready, 1);
    finally Candidate.Free; end;
  finally LeaveCriticalSection(Guard); end;
end;
function WindowsDigest(const Data: RawByteString; SHA256: Boolean): string;
const Digits = '0123456789abcdef';
var Digest: array[0..31] of Byte; Size, Index: Integer; Hash: TDigest;
begin
  EnsureOpenSSL;
  if SHA256 then begin Hash := API.SHA256; Size := 32; end
  else begin Hash := API.SHA1; Size := 20; end;
  if Hash(Pointer(Data), Length(Data), @Digest[0]) = nil then
    raise EScuError.Create('Could not compute the OpenSSL checksum.');
  SetLength(Result, Size * 2);
  for Index := 0 to Size - 1 do
  begin
    Result[2 * Index + 1] := Digits[1 + (Digest[Index] shr 4)];
    Result[2 * Index + 2] := Digits[1 + (Digest[Index] and 15)];
  end;
end;
initialization
  InitCriticalSection(Guard);
// Keep the initialized provider and its callback addresses valid until exit.
finalization
  DoneCriticalSection(Guard);
end.
