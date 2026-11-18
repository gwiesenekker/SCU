unit ScuZstdWindows;
{$mode objfpc}{$H+}
interface
uses CTypes;
function ZSTD_compressBound(SourceSize: csize_t): csize_t;
function ZSTD_compress(Dest: Pointer; Capacity: csize_t; Source: Pointer; Size: csize_t; Level: cint): csize_t;
function ZSTD_decompress(Dest: Pointer; Capacity: csize_t; Source: Pointer; Size: csize_t): csize_t;
function ZSTD_findFrameCompressedSize(Source: Pointer; Size: csize_t): csize_t;
function ZSTD_getFrameContentSize(Source: Pointer; Size: csize_t): QWord;
function ZSTD_isError(Code: csize_t): cuint;
function ZSTD_getErrorName(Code: csize_t): PChar;
implementation
uses ScuWindowsDLL, ScuErrors;
type
  TVersion = function: cuint; cdecl;
  TZstdAPI = record
    ZSTD_compressBound: function(SourceSize: csize_t): csize_t; cdecl;
    ZSTD_compress: function(Dest: Pointer; Capacity: csize_t; Source: Pointer; Size: csize_t; Level: cint): csize_t; cdecl;
    ZSTD_decompress: function(Dest: Pointer; Capacity: csize_t; Source: Pointer; Size: csize_t): csize_t; cdecl;
    ZSTD_findFrameCompressedSize: function(Source: Pointer; Size: csize_t): csize_t; cdecl;
    ZSTD_getFrameContentSize: function(Source: Pointer; Size: csize_t): QWord; cdecl;
    ZSTD_isError: function(Code: csize_t): cuint; cdecl;
    ZSTD_getErrorName: function(Code: csize_t): PChar; cdecl;
  end;
var Guard: TRTLCriticalSection; Ready: LongInt; Module: TWindowsDLL; API: TZstdAPI;
procedure EnsureZstd;
var Candidate: TWindowsDLL; Loaded: TZstdAPI; Version: TVersion;
begin
  if System.InterlockedCompareExchange(Ready, 0, 0) = 1 then Exit;
  EnterCriticalSection(Guard);
  try
    if Ready = 1 then Exit;
    Candidate := TWindowsDLL.Create('zstd', ['libzstd.dll', 'zstd.dll']);
    try
      Pointer(Version) := Candidate.Require('ZSTD_versionNumber');
      if Version() < 10300 then
        raise EScuError.Create('zstd DLL "' + Candidate.Path + '" requires zstd 1.3 or newer.');
      Pointer(Loaded.ZSTD_compressBound) := Candidate.Require('ZSTD_compressBound');
      Pointer(Loaded.ZSTD_compress) := Candidate.Require('ZSTD_compress');
      Pointer(Loaded.ZSTD_decompress) := Candidate.Require('ZSTD_decompress');
      Pointer(Loaded.ZSTD_findFrameCompressedSize) := Candidate.Require('ZSTD_findFrameCompressedSize');
      Pointer(Loaded.ZSTD_getFrameContentSize) := Candidate.Require('ZSTD_getFrameContentSize');
      Pointer(Loaded.ZSTD_isError) := Candidate.Require('ZSTD_isError');
      Pointer(Loaded.ZSTD_getErrorName) := Candidate.Require('ZSTD_getErrorName');
      API := Loaded;
      Module := Candidate; Candidate := nil;
      System.InterlockedExchange(Ready, 1);
    finally Candidate.Free; end;
  finally LeaveCriticalSection(Guard); end;
end;
function ZSTD_compressBound(SourceSize: csize_t): csize_t;
begin
  EnsureZstd;
  Result := API.ZSTD_compressBound(SourceSize);
end;
function ZSTD_compress(Dest: Pointer; Capacity: csize_t; Source: Pointer; Size: csize_t; Level: cint): csize_t;
begin
  EnsureZstd;
  Result := API.ZSTD_compress(Dest, Capacity, Source, Size, Level);
end;
function ZSTD_decompress(Dest: Pointer; Capacity: csize_t; Source: Pointer; Size: csize_t): csize_t;
begin
  EnsureZstd;
  Result := API.ZSTD_decompress(Dest, Capacity, Source, Size);
end;
function ZSTD_findFrameCompressedSize(Source: Pointer; Size: csize_t): csize_t;
begin
  EnsureZstd;
  Result := API.ZSTD_findFrameCompressedSize(Source, Size);
end;
function ZSTD_getFrameContentSize(Source: Pointer; Size: csize_t): QWord;
begin
  EnsureZstd;
  Result := API.ZSTD_getFrameContentSize(Source, Size);
end;
function ZSTD_isError(Code: csize_t): cuint;
begin
  EnsureZstd;
  Result := API.ZSTD_isError(Code);
end;
function ZSTD_getErrorName(Code: csize_t): PChar;
begin
  EnsureZstd;
  Result := API.ZSTD_getErrorName(Code);
end;
initialization
  InitCriticalSection(Guard);
// Retain successful modules until process teardown (no late callback unloading).
finalization
  DoneCriticalSection(Guard);
end.
