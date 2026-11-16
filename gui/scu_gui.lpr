program scu_gui;
{$mode objfpc}{$H+}
uses cthreads, Interfaces, Forms, SysUtils, ScuGuiMain;
var Main: TScuMainForm;
begin
  RequireDerivedFormResource := False;
  Application.Initialize;
  Application.CreateForm(TScuMainForm, Main);
  if ParamCount > 0 then
    try Main.OpenLibrary(ParamStr(1));
    except on E: Exception do WriteLn(StdErr, E.Message); end;
  Application.Run;
end.
