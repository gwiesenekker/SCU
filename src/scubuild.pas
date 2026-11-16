unit ScuBuild;
{$mode objfpc}{$H+}
interface
uses ScuBuildTypes;
function RunBuildProcess(const Build: TBuildRequest; Interactive: Boolean; OutputLock: THandle): string;
implementation
uses {$IFDEF WINDOWS}ScuPlatformBuildWindows{$ELSE}ScuPlatformBuildLinux{$ENDIF};
function RunBuildProcess(const Build: TBuildRequest; Interactive: Boolean; OutputLock: THandle): string;
begin
  Result := {$IFDEF WINDOWS}ScuPlatformBuildWindows{$ELSE}ScuPlatformBuildLinux{$ENDIF}.RunBuildProcess(Build, Interactive, OutputLock);
end;
end.
