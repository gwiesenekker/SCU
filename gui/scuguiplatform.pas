unit ScuGuiPlatform;
{$mode objfpc}{$H+}
interface
function DefaultGuiFont: string;
procedure EnsureGuiPreferencesDirectory(const Path: string);
implementation
uses SysUtils, ScuCleanupFiles;
function DefaultGuiFont: string;
begin
  {$IFDEF WINDOWS}Result := 'Consolas';{$ELSE}Result := 'monospace';{$ENDIF}
end;
procedure EnsureGuiPreferencesDirectory(const Path: string);
begin
  {$IFDEF WINDOWS}EnsureRealReleaseDirectory(Path);{$ELSE}
  if not ForceDirectories(Path) then
    raise Exception.Create('Could not create preferences directory: ' + Path);
  {$ENDIF}
end;
end.
