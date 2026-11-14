unit ScuLibraryPaths;

{$mode objfpc}{$H+}

interface

function NormalizeLibraryName(const Path: string): string;
function LibraryLockPath(const Path: string): string;
function LibraryRecoveryPath(const Path: string; ProcessID: Integer): string;
function IsLibraryStoragePath(const Candidate, LibraryPath: string): Boolean;

implementation

uses
  SysUtils, ScuErrors;

function NormalizeLibraryName(const Path: string): string;
var
  Extension: string;
begin
  if (Path = '') or (Path[Length(Path)] = DirectorySeparator) then
    raise EScuError.Create('Expected a library filename.');
  Extension := ExtractFileExt(Path);
  if Extension = '' then
    Exit(Path + '.sqlite');
  if not SameText(Extension, '.sqlite') then
    raise EScuError.Create('Library filename must have the .sqlite extension: "' + Path + '".');
  Result := Path;
end;

function LibraryLockPath(const Path: string): string;
begin
  Result := Path + '.lock';
end;

function LibraryRecoveryPath(const Path: string; ProcessID: Integer): string;
begin
  Result := Path + '.recovery-' + IntToStr(ProcessID) + '.json';
end;

function IsLibraryStoragePath(const Candidate, LibraryPath: string): Boolean;
begin
  Result := (Candidate = LibraryPath) or (Candidate = LibraryLockPath(LibraryPath)) or
    (Candidate = LibraryPath + '-journal') or (Candidate = LibraryPath + '-wal') or
    (Candidate = LibraryPath + '-shm');
end;

end.
