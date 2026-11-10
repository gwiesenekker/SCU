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
  SysUtils, CTypes, Base64, SHA1, Dynlibs, ScuErrors;

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
  TSHA256Function = function(Data: Pointer; Size: csize_t; Digest: PByte): PByte; cdecl;

var
  CryptoLibrary: TLibHandle = NilHandle;
  CryptoSHA256: TSHA256Function = nil;

function DeckSHA1(const Data: RawByteString): string;
begin
  Result := SHA1Print(SHA1String(Data));
end;

function AuditSHA256(const Data: RawByteString): string;
var
  Digest: array[0..31] of Byte;
  Index: Integer;
  Hex: string;
begin
  if not Assigned(CryptoSHA256) then
  begin
    CryptoLibrary := LoadLibrary('libcrypto.so.3');
    if CryptoLibrary = NilHandle then
      raise EScuError.Create('Could not load OpenSSL libcrypto.so.3.');
    Pointer(CryptoSHA256) := GetProcedureAddress(CryptoLibrary, 'SHA256');
    if not Assigned(CryptoSHA256) then
      raise EScuError.Create('OpenSSL SHA256 is unavailable.');
  end;
  if CryptoSHA256(Pointer(Data), Length(Data), @Digest[0]) = nil then
    raise EScuError.Create('Could not compute SHA-256.');
  SetLength(Result, 64);
  for Index := Low(Digest) to High(Digest) do
  begin
    Hex := LowerCase(IntToHex(Digest[Index], 2));
    Result[2 * Index + 1] := Hex[1];
    Result[2 * Index + 2] := Hex[2];
  end;
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
begin
  if (Size < 0) or (Size > MaxDeckSize) then
    raise EScuError.Create('Deck size is out of range.');
  if not IsHexDigest(Digest, 40) then
    raise EScuError.Create('Invalid deck SHA-1 checksum.');
  Compressed := DecodeStringBase64(Encoded, True);
  if EncodeStringBase64(Compressed) <> Encoded then
    raise EScuError.Create('Invalid deck base64 encoding.');
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
