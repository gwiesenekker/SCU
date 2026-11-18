unit ScuFiles;

{$mode objfpc}{$H+}{$macro on}

interface

uses
  Classes, SysUtils, ScuFileTypes;

type
  TAtomicWriteOptions = ScuFileTypes.TAtomicWriteOptions;
  TReadBytesOptions = ScuFileTypes.TReadBytesOptions;

// Retain the public option names for callers that use only ScuFiles.
const
  awNoReplace = ScuFileTypes.awNoReplace;
  awSourceOutput = ScuFileTypes.awSourceOutput;
  rbNoFollow = ScuFileTypes.rbNoFollow;

function CanonicalFile(const Path: string): string;
function CanonicalDirectory(const Path: string): string;
function RegularFileExists(const Path: string): Boolean;
function IsSQLiteFile(const Path: string): Boolean;
function IsSQLiteCompanion(const Path: string): Boolean;
procedure CleanupStaleAtomicFiles(const Directory: string);
function OpenReadFile(const Path: string): TStream;
function ReadBytes(const Path: string; Limit: Int64; Options: TReadBytesOptions = []): RawByteString;
procedure AtomicWrite(const Path: string; const Data: RawByteString; Options: TAtomicWriteOptions = []); overload;
procedure AtomicWrite(const Path: string; Data: TStream; Options: TAtomicWriteOptions = []); overload;
function MakeTempDirectory(const Prefix: string): string;
function MakeStagingDirectory(const Directory: string): string;
procedure SyncFile(Handle: THandle; const Path: string);
procedure SyncParent(const Path: string);

implementation

{$IFDEF WINDOWS}
  {$DEFINE FileBackend := ScuPlatformFilesWindows}
{$ELSE}
  {$DEFINE FileBackend := ScuPlatformFilesLinux}
{$ENDIF}

uses ScuPlatformPaths,
  {$IFDEF WINDOWS}ScuPlatformFilesWindows{$ELSE}
  {$IFDEF LINUX}ScuPlatformFilesLinux{$ELSE}
    {$FATAL No SCU file backend for this platform}
  {$ENDIF}{$ENDIF};

function CanonicalFile(const Path: string): string;
begin
  Result := PlatformCanonicalFile(Path);
end;

function CanonicalDirectory(const Path: string): string;
begin
  Result := PlatformCanonicalDirectory(Path);
end;

function RegularFileExists(const Path: string): Boolean;
begin
  Result := FileBackend.RegularFileExists(Path);
end;

function IsSQLiteFile(const Path: string): Boolean;
begin
  Result := FileBackend.IsSQLiteFile(Path);
end;

function OpenReadFile(const Path: string): TStream;
begin
  Result := FileBackend.OpenReadFile(Path);
end;

function ReadBytes(const Path: string; Limit: Int64; Options: TReadBytesOptions): RawByteString;
begin
  Result := FileBackend.ReadBytes(Path, Limit, Options);
end;

procedure AtomicWrite(const Path: string; Data: TStream; Options: TAtomicWriteOptions);
begin
  FileBackend.AtomicWrite(Path, Data, Options);
end;

procedure CleanupStaleAtomicFiles(const Directory: string);
begin
  FileBackend.CleanupStaleAtomicFiles(Directory);
end;

function MakeTempDirectory(const Prefix: string): string;
begin
  Result := FileBackend.MakeTempDirectory(Prefix);
end;

function MakeStagingDirectory(const Directory: string): string;
begin
  Result := FileBackend.MakeStagingDirectory(Directory);
end;

procedure SyncFile(Handle: THandle; const Path: string);
begin
  FileBackend.SyncFile(Handle, Path);
end;

procedure SyncParent(const Path: string);
begin
  FileBackend.SyncParent(Path);
end;

function IsSQLiteCompanion(const Path: string): Boolean;
const Suffixes: array[0..3] of string = ('.lock', '-journal', '-wal', '-shm');
var Suffix: string;
begin
  for Suffix in Suffixes do
    if SameStoragePath(Copy(Path, Length(Path) - Length(Suffix) + 1, MaxInt), Suffix) and
      IsSQLiteFile(Copy(Path, 1, Length(Path) - Length(Suffix))) then Exit(True);
  Result := False;
end;

procedure AtomicWrite(const Path: string; const Data: RawByteString; Options: TAtomicWriteOptions);
var
  Stream: TRawByteStringStream;
begin
  Stream := TRawByteStringStream.Create(Data);
  try
    AtomicWrite(Path, Stream, Options);
  finally
    Stream.Free;
  end;
end;

end.
