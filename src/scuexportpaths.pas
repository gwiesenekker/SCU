unit ScuExportPaths;

{$mode objfpc}{$H+}

interface

const ExportDirectorySelector = 'scu$release_directory';
function ResolveReleaseDirectory(const LibraryPath, Directory: string): string;
function DefaultExportDirectory(const LibraryPath: string): string;
function EnsureExportDirectory(const LibraryPath: string): string;
implementation

uses
  SysUtils, BaseUnix, FPJSON, ScuJSON, ScuSQLite, ScuErrors, ScuFiles;

function DefaultExportDirectory(const LibraryPath: string): string;
var
  Path, Directory: string;
  Reader: TSQLiteLibrary;
  Metadata, Header: TJSONObject;
begin
  Path := CanonicalFile(LibraryPath);
  Directory := 'release';
  if RegularFileExists(Path) then
  begin
    Reader := TSQLiteLibrary.OpenRead(Path);
    try
      Metadata := Reader.Revisions.ReadMetadata;
      try
        Header := TJSONObject(Field(Metadata, 'header', jtObject, 'Library configuration'));
        if Assigned(Header.Find('release_directory')) then
          Directory := Field(Header, 'release_directory', jtString, 'Library configuration').AsString;
      finally
        Metadata.Free;
      end;
    finally
      Reader.Free;
    end;
  end;
  Result := ResolveReleaseDirectory(Path, Directory);
end;

function ResolveReleaseDirectory(const LibraryPath, Directory: string): string;
var
  Value, Path: string;
begin
  Path := CanonicalFile(LibraryPath);
  Value := Directory;
  if (Trim(Value) = '') or (Pos(#0, Value) > 0) then
    raise EScuError.Create('Expected a nonempty release_directory.');
  if Value[1] <> DirectorySeparator then
    Value := IncludeTrailingPathDelimiter(ExtractFileDir(Path)) + Value;
  Result := ExpandFileName(Value);
  if Result = ExtractFileDir(Path) then
    raise EScuError.Create('release_directory must be separate from the library working-source directory.');
end;
function EnsureExportDirectory(const LibraryPath: string): string;
var
  Info: Stat;
begin
  if not RegularFileExists(LibraryPath) then
    raise EScuError.Create('Library "' + ExpandFileName(LibraryPath) + '" does not exist. Use initialize_library to create it.');
  Result := DefaultExportDirectory(LibraryPath);
  if fpLStat(Result, Info) = 0 then
  begin
    if not FPS_ISDIR(Info.st_mode) then
      raise EScuError.Create('Expected a real export directory, not a file or symbolic link: "' + Result + '".');
    Exit;
  end;
  if fpGetErrNo <> ESysENOENT then
    RaiseSystemError('Could not inspect export directory "' + Result + '"', fpGetErrNo);
  if not ForceDirectories(Result) then
    RaiseSystemError('Could not create export directory "' + Result + '"', fpGetErrNo);
  SyncParent(Result);
end;
end.
