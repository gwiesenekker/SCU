program Scu;

{$mode objfpc}{$H+}

uses
  SysUtils, BaseUnix, ScuCLI, ScuOutput;

var
  CLI: TScuCLI;

procedure HandleBrokenPipe(Signal: cint); cdecl;
begin
  // Let the failed write return to the command's audit error handler.
end;

begin
  AllowDirectorySeparators := ['/'];
  fpSignal(SIGPIPE, @HandleBrokenPipe);
  try
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
