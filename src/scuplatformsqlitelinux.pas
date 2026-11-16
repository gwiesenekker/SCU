unit ScuPlatformSQLiteLinux;

{$mode objfpc}{$H+}

interface

function CanRecoverSQLite(const Path: string): Boolean;
procedure CreateSQLiteFile(const Path: string);
function SQLiteFilename(const Path: string): RawByteString;

implementation

uses BaseUnix, Linux, ScuErrors, ScuFiles;

function CanRecoverSQLite(const Path: string): Boolean;
begin
  Result := fpAccess(Path, W_OK) = 0;
end;

procedure CreateSQLiteFile(const Path: string);
var Handle: cint;
begin
  if RegularFileExists(Path) then Exit;
  Handle := fpOpen(Path, O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC, &600);
  if Handle < 0 then
    RaiseSystemError('Could not create SQLite library "' + Path + '"', fpGetErrNo);
  fpClose(Handle);
  SyncParent(Path);
end;

function SQLiteFilename(const Path: string): RawByteString;
begin
  Result := Path;
end;

end.
