program scu_gui;
{$mode objfpc}{$H+}
{$IFDEF WINDOWS}{$APPTYPE GUI}{$ENDIF}
uses {$IFDEF UNIX}cthreads,{$ENDIF} Interfaces, Forms, Classes, SysUtils, ScuGuiMain, ScuPlatformPaths;
var Main: TScuMainForm; Arguments: TStringList;
begin
  InitializePlatformPaths;
  RequireDerivedFormResource := False;
  Application.Initialize;
  Application.CreateForm(TScuMainForm, Main);
  Arguments := TStringList.Create;
  try
    ReadInvocationArguments(Arguments);
    if Arguments.Count > 0 then Main.OpenInitialLibrary(Arguments[0]);
  finally Arguments.Free; end;
  Application.Run;
end.
