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
procedure TokenizeCommand(const Line: string; Tokens: TStrings);
function TokenizeCommandPrefix(const Line: string; Tokens: TStrings;
  out CurrentToken: string; out Quote: Char): Boolean;

implementation

uses
  SysUtils, Termio, FPJSON, ScuHistory, ScuIO;

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

function SplitCommand(const Line: string; Tokens: TStrings; Partial: Boolean;
  out CurrentToken: string; out Quote: Char): Boolean;
var
  Index, Count: SizeInt;
  Current: Char;
  Token: string;
  Started: Boolean;

  procedure FinishToken;
  begin
    if Started then
      Tokens.Add(Copy(Token, 1, Count));
    Started := False;
    Count := 0;
  end;

begin
  Tokens.Clear;
  if Pos(#0, Line) > 0 then
    raise EScuError.Create('A command cannot contain a NUL byte.');
  SetLength(Token, Length(Line));
  Count := 0;
  Quote := #0;
  Started := False;
  Index := 1;
  while Index <= Length(Line) do
  begin
    Current := Line[Index];
    if (Quote = #0) and (Current in [' ', #9]) then
      FinishToken
    else
    begin
      Started := True;
      if (Quote = #0) and (Current in ['"', '''']) then
        Quote := Current
      else if Current = Quote then
        Quote := #0
      else
      begin
        if (Current = '\') and
          ((Quote = #0) or ((Quote = '"') and (Index < Length(Line)) and
            (Line[Index + 1] in ['\', '"']))) then
        begin
          Inc(Index);
          if Index > Length(Line) then
          begin
            if Partial then
              Exit(False);
            raise EScuError.Create('Expected a character after the backslash.');
          end;
          Current := Line[Index];
        end;
        Inc(Count);
        Token[Count] := Current;
      end;
    end;
    Inc(Index);
  end;
  if Partial then
    CurrentToken := Copy(Token, 1, Count)
  else
  begin
    if Quote <> #0 then
      raise EScuError.Create('Unclosed quote.');
    FinishToken;
  end;
  Result := True;
end;

procedure TokenizeCommand(const Line: string; Tokens: TStrings);
var
  CurrentToken: string;
  Quote: Char;
begin
  SplitCommand(Line, Tokens, False, CurrentToken, Quote);
end;

function TokenizeCommandPrefix(const Line: string; Tokens: TStrings;
  out CurrentToken: string; out Quote: Char): Boolean;
begin
  Result := SplitCommand(Line, Tokens, True, CurrentToken, Quote);
end;

finalization
  CommandHistory.Free;

end.
