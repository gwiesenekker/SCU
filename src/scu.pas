program Scu;

{$mode objfpc}{$H+}

uses
  SysUtils, ScuCLI;

var
  CLI: TScuCLI;
begin
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
      WriteLn(StdErr, 'scu: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
