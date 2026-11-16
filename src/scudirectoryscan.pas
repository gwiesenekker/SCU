unit ScuDirectoryScan;
{$mode objfpc}{$H+}
interface
uses {$IFDEF WINDOWS}ScuPlatformScanWindows{$ELSE}
  {$IFDEF LINUX}ScuPlatformScanLinux{$ELSE}{$FATAL No SCU scan backend}{$ENDIF}{$ENDIF};
type
  TDirectoryScan = TPlatformDirectoryScan;
function FileNameDigest(const Name: string): string;
function MatchesFilePattern(const Pattern, Name: string): Boolean;
implementation
function FileNameDigest(const Name: string): string;
begin
  Result := {$IFDEF WINDOWS}ScuPlatformScanWindows{$ELSE}ScuPlatformScanLinux{$ENDIF}.FileNameDigest(Name);
end;
function MatchesFilePattern(const Pattern, Name: string): Boolean;
begin
  Result := MatchesPattern(Pattern, Name);
end;
end.
