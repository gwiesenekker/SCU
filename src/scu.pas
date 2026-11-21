program Scu;

{$mode objfpc}{$H+}

uses
  SysUtils, {$IFDEF LINUX}BaseUnix,{$ENDIF} ScuBuildInfo, ScuCLI, ScuOutput, ScuPlatformPaths;

var
  CLI: TScuCLI;

{$IFDEF LINUX}
procedure HandleBrokenPipe(Signal: cint); cdecl;
begin
  // Let the failed write return to the command's audit error handler.
end;
{$ENDIF}

begin
  InitializePlatformPaths;
  {$IFDEF LINUX}fpSignal(SIGPIPE, @HandleBrokenPipe);{$ENDIF}
  try
    if (ParamCount = 1) and (ParamStr(1) = '--version') then
    begin
      WriteLn(ScuBuildVersion);
      Exit;
    end;
    CLI := TScuCLI.Create;
    try
      CLI.Run;
    finally
      CLI.Free;
    end;
  except
    on E: Exception do
    begin
      WriteDiagnostic('scu: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
