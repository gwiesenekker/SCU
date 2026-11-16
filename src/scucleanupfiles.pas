unit ScuCleanupFiles;
{$mode objfpc}{$H+}{$macro on}
interface
uses {$IFDEF WINDOWS}ScuPlatformCleanupWindows{$ELSE}
  {$IFDEF LINUX}ScuPlatformCleanupLinux{$ELSE}{$FATAL No SCU cleanup backend}{$ENDIF}{$ENDIF};
type TReleaseDirectoryScan = {$IFDEF WINDOWS}ScuPlatformCleanupWindows{$ELSE}ScuPlatformCleanupLinux{$ENDIF}.TReleaseDirectoryScan;
procedure EnsureRealReleaseDirectory(const Path: string);
function ReleaseFileEligible(const Path: string; AllowMissing: Boolean): Boolean;
procedure RemoveObsoleteReleaseFile(const Path: string);
procedure RemoveWorkingDirectory(const Path: string);
implementation
{$IFDEF WINDOWS}{$DEFINE Backend := ScuPlatformCleanupWindows}
{$ELSE}{$DEFINE Backend := ScuPlatformCleanupLinux}{$ENDIF}
procedure EnsureRealReleaseDirectory(const Path: string);
begin Backend.EnsureRealReleaseDirectory(Path); end;
function ReleaseFileEligible(const Path: string; AllowMissing: Boolean): Boolean;
begin Result := Backend.ReleaseFileEligible(Path, AllowMissing); end;
procedure RemoveObsoleteReleaseFile(const Path: string);
begin Backend.RemoveObsoleteReleaseFile(Path); end;
procedure RemoveWorkingDirectory(const Path: string);
begin Backend.RemoveWorkingDirectory(Path); end;
end.
