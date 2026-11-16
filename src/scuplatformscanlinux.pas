unit ScuPlatformScanLinux;
{$mode objfpc}{$H+}
interface
uses BaseUnix;
type
  TPlatformDirectoryScan = class
  private
    FDirectory: string;
    FHandle: pDir;
  public
    constructor Create(const Directory: string);
    destructor Destroy; override;
    function Next(out Name: string): Boolean;
    function SelectedRegularFile(const Name: string): Boolean;
  end;
function FileNameDigest(const Name: string): string;
function MatchesPattern(const Pattern, Name: string): Boolean;
implementation
uses SysUtils, ScuErrors, ScuCodec;
function FileNameDigest(const Name: string): string;
begin
  Result := AuditSHA256(Name);
end;
function fnmatch(Pattern, Name: PChar; Flags: LongInt): LongInt; cdecl; external 'c';
function MatchesPattern(const Pattern, Name: string): Boolean;
begin
  Result := fnmatch(PChar(Pattern), PChar(Name), 2 or 4) = 0;
end;
constructor TPlatformDirectoryScan.Create(const Directory: string);
begin
  inherited Create;
  FDirectory := IncludeTrailingPathDelimiter(Directory);
  FHandle := fpOpenDir(PChar(FDirectory));
  if FHandle = nil then
    RaiseSystemError('Could not scan directory "' + FDirectory + '"', fpGetErrNo);
end;
destructor TPlatformDirectoryScan.Destroy;
begin
  if FHandle <> nil then fpCloseDir(FHandle^);
  inherited Destroy;
end;
function TPlatformDirectoryScan.Next(out Name: string): Boolean;
var Entry: pDirent;
begin
  fpSetErrNo(0);
  Entry := fpReadDir(FHandle^);
  if Entry = nil then
  begin
    if fpGetErrNo <> 0 then
      RaiseSystemError('Could not read directory "' + FDirectory + '"', fpGetErrNo);
    Exit(False);
  end;
  Name := StrPas(@Entry^.d_name[0]);
  Result := True;
end;
function TPlatformDirectoryScan.SelectedRegularFile(const Name: string): Boolean;
var Info: Stat; Path: string;
begin
  Path := FDirectory + Name;
  if fpLStat(Path, Info) <> 0 then
    RaiseSystemError('Could not inspect selected file "' + Path + '"', fpGetErrNo);
  if FPS_ISLNK(Info.st_mode) then
    raise EScuError.Create('Cannot snapshot a symbolic link: "' + Path + '".');
  Result := not FPS_ISDIR(Info.st_mode);
  if Result and not FPS_ISREG(Info.st_mode) then
    raise EScuError.Create('Expected a regular file: "' + Path + '".');
end;
end.
