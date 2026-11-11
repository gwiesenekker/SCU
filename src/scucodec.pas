unit ScuCodec;

{$mode objfpc}{$H+}

interface

const
  MaxDeckSize = 64 * 1024 * 1024;

function DeckSHA1(const Data: RawByteString): string;
function AuditSHA256(const Data: RawByteString): string;
function IsHexDigest(const Digest: string; Size: SizeInt): Boolean;
function EncodeDeck(const Source: RawByteString): string;
function DecodeDeck(const Encoded, Digest: string; Size: Int64): RawByteString;

implementation

uses
  SysUtils, CTypes, Base64, Dynlibs, ScuErrors;

function ZSTD_compressBound(SourceSize: csize_t): csize_t; cdecl; external 'zstd';
function ZSTD_compress(Dest: Pointer; Capacity: csize_t; Source: Pointer;
  Size: csize_t; Level: cint): csize_t; cdecl; external 'zstd';
function ZSTD_decompress(Dest: Pointer; Capacity: csize_t; Source: Pointer;
  Size: csize_t): csize_t; cdecl; external 'zstd';
function ZSTD_findFrameCompressedSize(Source: Pointer; Size: csize_t): csize_t;
  cdecl; external 'zstd';
function ZSTD_getFrameContentSize(Source: Pointer; Size: csize_t): QWord;
  cdecl; external 'zstd';
function ZSTD_isError(Code: csize_t): cuint; cdecl; external 'zstd';
function ZSTD_getErrorName(Code: csize_t): PChar; cdecl; external 'zstd';

type
  TDigestFunction = function(Data: Pointer; Size: csize_t; Digest: PByte): PByte; cdecl;

var
  CryptoLibrary: TLibHandle = NilHandle;
  CryptoSHA1, CryptoSHA256: TDigestFunction;

function CryptoDigest(const Data: RawByteString; const Name: string; var DigestFunction: TDigestFunction;
  DigestSize: Integer): string;
const
  Digits = '0123456789abcdef';
var
  Digest: array[0..31] of Byte;
  Index: Integer;
begin
  if not Assigned(DigestFunction) then
  begin
    if CryptoLibrary = NilHandle then
      CryptoLibrary := LoadLibrary('libcrypto.so.3');
    if CryptoLibrary = NilHandle then
      raise EScuError.Create('Could not load OpenSSL libcrypto.so.3.');
    Pointer(DigestFunction) := GetProcedureAddress(CryptoLibrary, Name);
    if not Assigned(DigestFunction) then
      raise EScuError.CreateFmt('OpenSSL %s is unavailable.', [Name]);
  end;
  if DigestFunction(Pointer(Data), Length(Data), @Digest[0]) = nil then
    raise EScuError.CreateFmt('Could not compute %s.', [Name]);
  SetLength(Result, DigestSize * 2);
  for Index := 0 to DigestSize - 1 do
  begin
    Result[2 * Index + 1] := Digits[1 + (Digest[Index] shr 4)];
    Result[2 * Index + 2] := Digits[1 + (Digest[Index] and $0F)];
  end;
end;

function DeckSHA1(const Data: RawByteString): string;
begin
  Result := CryptoDigest(Data, 'SHA1', CryptoSHA1, 20);
end;

function AuditSHA256(const Data: RawByteString): string;
begin
  Result := CryptoDigest(Data, 'SHA256', CryptoSHA256, 32);
end;

function IsHexDigest(const Digest: string; Size: SizeInt): Boolean;
var
  Digit: Char;
begin
  if Length(Digest) <> Size then
    Exit(False);
  for Digit in Digest do
    if not (Digit in ['0'..'9', 'a'..'f']) then
      Exit(False);
  Result := True;
end;

function CheckZstd(Code: csize_t): csize_t;
begin
  if ZSTD_isError(Code) <> 0 then
    raise EScuError.Create('zstd: ' + StrPas(ZSTD_getErrorName(Code)));
  Result := Code;
end;

function EncodeDeck(const Source: RawByteString): string;
var
  Compressed: RawByteString;
begin
  SetLength(Compressed, CheckZstd(ZSTD_compressBound(Length(Source))));
  SetLength(Compressed, CheckZstd(ZSTD_compress(Pointer(Compressed), Length(Compressed),
    Pointer(Source), Length(Source), 3)));
  Result := EncodeStringBase64(Compressed);
end;

const
  Base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

var
  Base64Values: array[Char] of ShortInt;

procedure InitializeBase64;
var
  Index: Integer;
begin
  FillChar(Base64Values, SizeOf(Base64Values), $FF);
  for Index := 1 to Length(Base64Alphabet) do
    Base64Values[Base64Alphabet[Index]] := Index - 1;
end;

function DecodeBase64(const Encoded: string): RawByteString;
var
  Source, Dest, Last, Padding: SizeInt;
  First, Second, Third, Fourth: Integer;

  procedure InvalidEncoding;
  begin
    raise EScuError.Create('Invalid deck base64 encoding.');
  end;

begin
  Last := Length(Encoded);
  if (Last = 0) or (Last mod 4 <> 0) then
    InvalidEncoding;
  Padding := 0;
  if Encoded[Last] = '=' then
  begin
    Padding := 1;
    if Encoded[Last - 1] = '=' then
      Padding := 2;
  end;
  SetLength(Result, (Last div 4) * 3 - Padding);
  Source := 1;
  Dest := 1;
  while Source <= Last - Padding - 3 do
  begin
    First := Base64Values[Encoded[Source]];
    Second := Base64Values[Encoded[Source + 1]];
    Third := Base64Values[Encoded[Source + 2]];
    Fourth := Base64Values[Encoded[Source + 3]];
    if (First or Second or Third or Fourth) < 0 then
      InvalidEncoding;
    Result[Dest] := Chr((First shl 2) or (Second shr 4));
    Result[Dest + 1] := Chr(((Second and $F) shl 4) or (Third shr 2));
    Result[Dest + 2] := Chr(((Third and 3) shl 6) or Fourth);
    Inc(Source, 4);
    Inc(Dest, 3);
  end;
  if Padding = 0 then
    Exit;
  First := Base64Values[Encoded[Source]];
  Second := Base64Values[Encoded[Source + 1]];
  if ((First or Second) < 0) or ((Padding = 2) and ((Second and $F) <> 0)) then
    InvalidEncoding;
  Result[Dest] := Chr((First shl 2) or (Second shr 4));
  if Padding = 1 then
  begin
    Third := Base64Values[Encoded[Source + 2]];
    if (Third < 0) or ((Third and 3) <> 0) then
      InvalidEncoding;
    Result[Dest + 1] := Chr(((Second and $F) shl 4) or (Third shr 2));
  end;
end;

function DecodeDeck(const Encoded, Digest: string; Size: Int64): RawByteString;
var
  Compressed: RawByteString;
  Written: csize_t;
begin
  if (Size < 0) or (Size > MaxDeckSize) then
    raise EScuError.Create('Deck size is out of range.');
  if not IsHexDigest(Digest, 40) then
    raise EScuError.Create('Invalid deck SHA-1 checksum.');
  Compressed := DecodeBase64(Encoded);
  if CheckZstd(ZSTD_findFrameCompressedSize(Pointer(Compressed), Length(Compressed))) <>
    csize_t(Length(Compressed)) then
    raise EScuError.Create('Expected one zstd frame.');
  if ZSTD_getFrameContentSize(Pointer(Compressed), Length(Compressed)) <> QWord(Size) then
    raise EScuError.Create('Deck size does not match the zstd frame.');
  SetLength(Result, Size);
  Written := CheckZstd(ZSTD_decompress(Pointer(Result), Size,
    Pointer(Compressed), Length(Compressed)));
  if (Written <> csize_t(Size)) or (DeckSHA1(Result) <> Digest) then
    raise EScuError.Create('Deck SHA-1 or size verification failed.');
end;

initialization
  InitializeBase64;

finalization
  if CryptoLibrary <> NilHandle then
    UnloadLibrary(CryptoLibrary);

end.
