unit ScuPlatformCleanupLinux;
{$mode objfpc}{$H+}
interface
uses SysUtils;
type
  TReleaseDirectoryScan = class
  private
    FSearch: TSearchRec;
    FStarted, FOpen, FDone: Boolean;
    FDirectory: string;
  public
    constructor Create(const Directory: string);
    destructor Destroy; override;
    function Next(out Name: string): Boolean;
  end;
procedure EnsureRealReleaseDirectory(const Path: string);
function ReleaseFileEligible(const Path: string; AllowMissing: Boolean): Boolean;
procedure RemoveObsoleteReleaseFile(const Path: string);
procedure RemoveWorkingDirectory(const Path: string);
implementation
uses BaseUnix, ScuErrors, ScuFiles;
constructor TReleaseDirectoryScan.Create(const Directory: string);
begin
  inherited Create;
  FDirectory := IncludeTrailingPathDelimiter(Directory);
end;
destructor TReleaseDirectoryScan.Destroy;
begin
  if FOpen then FindClose(FSearch);
  inherited Destroy;
end;
function TReleaseDirectoryScan.Next(out Name: string): Boolean;
var Status: Integer;
begin
  if FDone then Exit(False);
  if not FStarted then
  begin
    FStarted := True;
    Status := FindFirst(FDirectory + '*', faAnyFile, FSearch);
    FOpen := Status = 0;
  end
  else Status := FindNext(FSearch);
  FDone := Status <> 0;
  Result := not FDone;
  if Result then Name := FSearch.Name;
end;
procedure EnsureRealReleaseDirectory(const Path: string);
var
  Info: Stat;
  Error: Integer;
  Parent: string;
begin
  if fpLStat(Path, Info) <> 0 then
  begin
    Error := fpGetErrNo;
    if Error <> ESysENOENT then
      RaiseSystemError('Could not inspect export directory "' + Path + '"', Error);
    Parent := ExtractFileDir(ExcludeTrailingPathDelimiter(Path));
    if (Parent <> '') and (Parent <> Path) and not DirectoryExists(Parent) then
      EnsureRealReleaseDirectory(Parent);
    if fpMkDir(Path, &777) = 0 then
    begin
      SyncParent(Path);
      Exit;
    end;
    Error := fpGetErrNo;
    if Error <> ESysEEXIST then
      RaiseSystemError('Could not create export directory "' + Path + '"', Error);
    // Another publisher created the entry. Validate it without following links.
    if fpLStat(Path, Info) <> 0 then
      RaiseSystemError('Could not inspect export directory "' + Path + '"', fpGetErrNo);
  end;
  if not FPS_ISDIR(Info.st_mode) then
    raise EScuError.Create('Expected a real export directory, not a file or symbolic link: "' + Path + '".');
end;
function ReleaseFileEligible(const Path: string; AllowMissing: Boolean): Boolean;
var Info: Stat;
begin
  if fpLStat(Path, Info) <> 0 then
  begin
    if AllowMissing then Exit(True);
    RaiseSystemError('Could not inspect release file "' + Path + '"', fpGetErrNo);
  end;
  Result := FPS_ISREG(Info.st_mode);
end;
procedure RemoveObsoleteReleaseFile(const Path: string);
begin
  if not DeleteFile(Path) then
    RaiseSystemError('Could not remove obsolete release file "' + Path + '"', GetLastOSError);
end;
procedure RemoveWorkingDirectory(const Path: string);
var Search: TSearchRec; Item: string; Info: Stat;
begin
  // Preserve the former ScuEdit implementation, including dangling links and
  // best-effort errors. Do not follow symlinks while removing children.
  {$push}{$warn SYMBOL_PLATFORM off}
  if FindFirst(Path + '/*', faAnyFile or faSymLink, Search) = 0 then
  {$pop}
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Item := Path + '/' + Search.Name;
      if (fpLStat(Item, Info) = 0) and FPS_ISDIR(Info.st_mode) then
        RemoveWorkingDirectory(Item)
      else fpUnlink(Item);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  RemoveDir(Path);
end;
end.
