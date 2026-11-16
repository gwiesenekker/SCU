unit ScuPlatformHistoryLinux;
{$mode objfpc}{$H+}
interface
function CommandHistoryPath: string;
implementation
uses SysUtils, BaseUnix, ScuErrors, ScuPlatformPaths;
function EnsureDirectory(const Path: string): Boolean;
var
  Parent: string;
begin
  if DirectoryExists(Path) then
    Exit(True);
  Parent := ExtractFileDir(ExcludeTrailingPathDelimiter(Path));
  Result := (Parent <> '') and (Parent <> Path) and EnsureDirectory(Parent) and
    (CreateDir(Path) or DirectoryExists(Path));
end;

function CommandHistoryPath: string;
var
  StateDir, Directory: string;
  Info: Stat;
begin
  StateDir := HistoryStateRoot;
  if StateDir = '' then Exit('');
  if not EnsureDirectory(StateDir) then
    raise EScuError.CreateFmt('Could not create state directory %s.', [StateDir]);
  Directory := IncludeTrailingPathDelimiter(StateDir) + 'scu';
  if (fpMkDir(Directory, &700) <> 0) and (fpGetErrNo <> ESysEEXIST) then
    RaiseSystemError('Could not create SCU state directory "' + Directory + '"', fpGetErrNo);
  if fpLStat(Directory, Info) <> 0 then
    RaiseSystemError('Could not inspect SCU state directory "' + Directory + '"', fpGetErrNo);
  if not FPS_ISDIR(Info.st_mode) or (Info.st_uid <> fpGetEUID) or
    ((Info.st_mode and &022) <> 0) then
    raise EScuError.CreateFmt('Expected a user-owned SCU state directory at %s.', [Directory]);
  Result := IncludeTrailingPathDelimiter(Directory) + 'history.json';
end;

end.
