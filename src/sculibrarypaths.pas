unit ScuLibraryPaths;

{$mode objfpc}{$H+}

interface

function NormalizeLibraryName(const Path: string): string;
function LibraryLockPath(const Path: string): string;
function LibraryRecoveryPath(const Path: string; ProcessID: Integer): string;
function IsLibraryStoragePath(const Candidate, LibraryPath: string): Boolean;

implementation

uses
  SysUtils, ScuErrors, ScuFiles, ScuPlatformPaths;

function NormalizeLibraryName(const Path: string): string;
var
  Extension: string;
begin
  if (Path = '') or PathEndsInSeparator(Path) then
    raise EScuError.Create('Expected a library filename.');
  Extension := ExtractFileExt(Path);
  if Extension = '' then
    Exit(Path + '.sqlite');
  if not SameText(Extension, '.sqlite') then
    raise EScuError.Create('Library filename must have the .sqlite extension: "' + Path + '".');
  Result := Path;
end;

function HiddenLockPath(const Path: string): string;
begin
  Result := ExtractFilePath(Path) + '.' + ExtractFileName(Path) + '.lock';
end;

function LibraryLockPath(const Path: string): string;
begin
  Result := Path + '.lock';
  if not FileEntryExists(Result) then Result := HiddenLockPath(Path);
end;

function LibraryRecoveryPath(const Path: string; ProcessID: Integer): string;
begin
  Result := Path + '.recovery-' + IntToStr(ProcessID) + '.json';
end;

function IsLibraryStoragePath(const Candidate, LibraryPath: string): Boolean;
begin
  Result := SameStoragePath(Candidate, LibraryPath) or SameStoragePath(Candidate, LibraryPath + '.lock') or
    SameStoragePath(Candidate, HiddenLockPath(LibraryPath)) or
    SameStoragePath(Candidate, LibraryPath + '-journal') or SameStoragePath(Candidate, LibraryPath + '-wal') or
    SameStoragePath(Candidate, LibraryPath + '-shm');
end;

end.
