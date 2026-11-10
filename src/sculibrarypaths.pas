unit ScuLibraryPaths;

{$mode objfpc}{$H+}

interface

function LibraryLockPath(const Path: string): string;
function LibraryRecoveryPath(const Path: string; ProcessID: Integer): string;
function IsLibraryStoragePath(const Candidate, LibraryPath: string): Boolean;

implementation

uses
  SysUtils;

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
