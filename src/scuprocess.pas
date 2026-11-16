unit ScuProcess;
{$mode objfpc}{$H+}{$macro on}
interface
uses Process, ScuProcessTypes;
type TChildProcessOptions = ScuProcessTypes.TChildProcessOptions;
const
  cpOwnProcessGroup = ScuProcessTypes.cpOwnProcessGroup;
  cpHandlesInterrupt = ScuProcessTypes.cpHandlesInterrupt;
procedure StartBuildProcessGroup;
function ResolveEditorExecutable(const Name: string): string;
function WaitForChild(Child: TProcess; Options: TChildProcessOptions = []): Integer;
implementation
uses
  {$IFDEF WINDOWS}ScuPlatformProcessAdapterWindows{$ELSE}ScuPlatformProcessLinux{$ENDIF};
{$IFDEF WINDOWS}{$DEFINE Backend := ScuPlatformProcessAdapterWindows}
{$ELSE}{$DEFINE Backend := ScuPlatformProcessLinux}{$ENDIF}
procedure StartBuildProcessGroup;
begin Backend.StartBuildProcessGroup; end;
function ResolveEditorExecutable(const Name: string): string;
begin Result := Backend.ResolveEditorExecutable(Name); end;
function WaitForChild(Child: TProcess; Options: TChildProcessOptions): Integer;
begin Result := Backend.WaitForChild(Child, Options); end;
end.
