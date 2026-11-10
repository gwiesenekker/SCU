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

function DecodeDeck(const Encoded, Digest: string; Size: Int64): RawByteString;
var
  Compressed: RawByteString;
  Written: csize_t;
  EncodedSize: SizeInt;
begin
  if (Size < 0) or (Size > MaxDeckSize) then
    raise EScuError.Create('Deck size is out of range.');
  if not IsHexDigest(Digest, 40) then
    raise EScuError.Create('Invalid deck SHA-1 checksum.');
  EncodedSize := Length(Encoded);
  if (EncodedSize = 0) or (EncodedSize mod 4 <> 0) then
    raise EScuError.Create('Invalid deck base64 encoding.');
  // Strict decoding checks the alphabet and padding placement. Also require
  // the unused bits of the final sextet to be zero, as in the encoder.
  if Encoded[EncodedSize] = '=' then
    if Encoded[EncodedSize - 1] = '=' then
    begin
      if not (Encoded[EncodedSize - 2] in ['A', 'Q', 'g', 'w']) then
        raise EScuError.Create('Invalid deck base64 encoding.');
    end
    else if not (Encoded[EncodedSize - 1] in ['A', 'E', 'I', 'M', 'Q', 'U', 'Y',
      'c', 'g', 'k', 'o', 's', 'w', '0', '4', '8']) then
      raise EScuError.Create('Invalid deck base64 encoding.');
  try
    Compressed := DecodeStringBase64(Encoded, True);
  except
    on E: EBase64DecodingException do
      raise EScuError.Create('Invalid deck base64 encoding.');
  end;
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

finalization
  if CryptoLibrary <> NilHandle then
    UnloadLibrary(CryptoLibrary);

end.
