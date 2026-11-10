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

uses
  Termio;

function ReadCommandLine(const Prompt: string; out Line: string; Completion: TCommandCompletion;
  History: TCommandHistory): Boolean;
begin
  Line := '';
  if IsATTY(Input) = 1 then
  begin
    if not Assigned(History) then
      Exit(ReadTerminalLine(Prompt, nil, Completion, Line));
    History.Load;
    Exit(ReadTerminalLine(Prompt, History.Entries, Completion, Line));
  end;
  Write(StdErr, Prompt);
  Flush(StdErr);
  if EOF(Input) then
    Exit(False);
  ReadLn(Input, Line);
  Result := True;
end;

end.
