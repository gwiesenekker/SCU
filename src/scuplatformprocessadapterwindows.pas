unit ScuPlatformProcessAdapterWindows;
{$mode objfpc}{$H+}
interface
uses Process, ScuProcessTypes;
procedure StartBuildProcessGroup;
function ResolveEditorExecutable(const Name: string): string;
function WaitForChild(Child: TProcess; Options: TChildProcessOptions): Integer;
implementation
uses ScuErrors, ScuPlatformProcessWindows, ScuPlatformProcessStringsWindows;
procedure StartBuildProcessGroup;
begin
  // CreateProcess creates the group before execution; no post-fork hook exists.
end;
function ResolveEditorExecutable(const Name: string): string;
begin Result := ResolveWindowsExecutable(Name); end;
function WaitForChild(Child: TProcess; Options: TChildProcessOptions): Integer;
var Request: TChildProcessRequest;
begin
  if poUsePipes in Child.Options then
    raise EScuError.Create('WaitForChild does not support TProcess-owned pipes on Windows.');
  Request := TChildProcessRequest.Create;
  try
    Request.Executable := Child.Executable;
    Request.Arguments.Assign(Child.Parameters);
    Request.Environment.Assign(Child.Environment);
    Request.WorkingDirectory := Child.CurrentDirectory;
    Result := RunWindowsChild(Request, Options);
  finally Request.Free; end;
end;
end.
