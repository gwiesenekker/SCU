unit ScuInput;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuLineEditor;

type
  ECommandCancelled = ScuLineEditor.ECommandCancelled;
  TCommandCompletion = ScuLineEditor.TCommandCompletion;

function ReadCommandLine(const Prompt: string; out Line: string;
  Completion: TCommandCompletion = nil; UseHistory: Boolean = True): Boolean;
procedure RememberCommand(const Line: string);

implementation

uses
  SysUtils, Termio, FPJSON, ScuHistory;

var
  CommandHistory: TStringList;
  HistoryPath: string;

procedure LoadHistory;
var
  History: TJSONArray;
  Index: Integer;
begin
  CommandHistory := TStringList.Create;
  try
    HistoryPath := CommandHistoryPath;
    if HistoryPath = '' then
      Exit;
    History := ReadCommandHistory(HistoryPath);
    try
      for Index := 0 to History.Count - 1 do
        CommandHistory.Add(History.Strings[Index]);
    finally
      History.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'scu: Could not load command history. ', E.Message);
      HistoryPath := '';
    end;
  end;
end;

procedure RememberCommand(const Line: string);
begin
  if not Assigned(CommandHistory) or (Trim(Line) = '') then
    Exit;
  if CommandHistory.Count = MaxHistoryEntries then
    CommandHistory.Delete(0);
  CommandHistory.Add(Line);
  if HistoryPath = '' then
    Exit;
  try
    SaveHistoryCommand(HistoryPath, Line);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'scu: Could not save command history. ', E.Message);
      HistoryPath := '';
    end;
  end;
end;

function ReadCommandLine(const Prompt: string; out Line: string; Completion: TCommandCompletion;
  UseHistory: Boolean): Boolean;
begin
  Line := '';
  if IsATTY(Input) = 1 then
  begin
    if not UseHistory then
      Exit(ReadTerminalLine(Prompt, nil, Completion, Line));
    if not Assigned(CommandHistory) then
      LoadHistory;
    Exit(ReadTerminalLine(Prompt, CommandHistory, Completion, Line));
  end;
  Write(StdErr, Prompt);
  Flush(StdErr);
  if EOF(Input) then
    Exit(False);
  ReadLn(Input, Line);
  Result := True;
end;

finalization
  CommandHistory.Free;

end.
