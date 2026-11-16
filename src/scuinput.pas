unit ScuInput;

{$mode objfpc}{$H+}

interface

uses
  ScuHistory, ScuLineEditor;

type
  TCommandCompletion = ScuLineEditor.TCommandCompletion;

function ReadCommandLine(const Prompt: string; out Line: string;
  Completion: TCommandCompletion = nil; History: TCommandHistory = nil): Boolean;

implementation

uses ScuTerminal
  {$IFDEF WINDOWS}, ScuPlatformTerminalSessionWindows{$ENDIF};

function ReadCommandLine(const Prompt: string; out Line: string; Completion: TCommandCompletion;
  History: TCommandHistory): Boolean;
begin
  {$IFDEF WINDOWS}UseTerminalLocale;{$ENDIF}
  Line := '';
  if IsTerminalInput then
  begin
    if not Assigned(History) then
      Exit(ReadTerminalLine(Prompt, nil, Completion, Line));
    History.Load;
    Exit(ReadTerminalLine(Prompt, History.Entries, Completion, Line));
  end;
  Write(StdErr, Prompt);
  Flush(StdErr);
  {$IFDEF WINDOWS}
  Exit(ReadRedirectedCommandLine(Line));
  {$ELSE}
  if EOF(Input) then
    Exit(False);
  ReadLn(Input, Line);
  Result := True;
  {$ENDIF}
end;

end.
