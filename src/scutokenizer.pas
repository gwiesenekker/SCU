unit ScuTokenizer;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TCommandToken = record
    Text: string;
    Quote: Char;
    Offset: SizeInt;
    Started: Boolean;
  end;

procedure TokenizeCommand(const Line: string; Tokens: TStrings);
function TokenizeCommandPrefix(const Line: string; Tokens: TStrings;
  out Current: TCommandToken): Boolean;
function CompletionStart(const Line: string; Ending: SizeInt): SizeInt;
function EscapeSuffix(const Suffix: string; Quote: Char): string;

implementation

uses
  ScuErrors;

function EscapesInDoubleQuote(Character: Char): Boolean;
begin
  Result := Character in ['\', '"'];
end;

function ScanCommand(const Line: string; Ending: SizeInt; Tokens: TStrings;
  Partial: Boolean; out Current: TCommandToken): Boolean;
var
  Index, Count: SizeInt;
  Character: Char;
  Buffer: string;

  procedure FinishToken;
  begin
    if Assigned(Tokens) and Current.Started then
      Tokens.Add(Copy(Buffer, 1, Count));
    Current.Started := False;
    Count := 0;
  end;

begin
  Current := Default(TCommandToken);
  if Assigned(Tokens) then
  begin
    Tokens.Clear;
    if Pos(#0, Line) > 0 then
      raise EScuError.Create('A command cannot contain a NUL byte.');
    SetLength(Buffer, Ending);
  end;
  Count := 0;
  Index := 1;
  while Index <= Ending do
  begin
    Character := Line[Index];
    if (Current.Quote = #0) and (Character in [' ', #9]) then
    begin
      FinishToken;
      Current.Offset := Index;
    end
    else
    begin
      Current.Started := True;
      if (Current.Quote = #0) and (Character in ['"', #39]) then
        Current.Quote := Character
      else if Character = Current.Quote then
        Current.Quote := #0
      else
      begin
        if (Character = '\') and ((Current.Quote = #0) or
          ((Current.Quote = '"') and (Index < Ending) and EscapesInDoubleQuote(Line[Index + 1]))) then
        begin
          Inc(Index);
          if Index > Ending then
          begin
            if Partial then
              Exit(False);
            raise EScuError.Create('Expected a character after the backslash.');
          end;
          Character := Line[Index];
        end;
        if Assigned(Tokens) then
        begin
          Inc(Count);
          Buffer[Count] := Character;
        end;
      end;
    end;
    Inc(Index);
  end;
  if Partial then
    Current.Text := Copy(Buffer, 1, Count)
  else
  begin
    if Current.Quote <> #0 then
      raise EScuError.Create('Unclosed quote.');
    FinishToken;
  end;
  Result := True;
end;

procedure TokenizeCommand(const Line: string; Tokens: TStrings);
var
  Current: TCommandToken;
begin
  ScanCommand(Line, Length(Line), Tokens, False, Current);
end;

function TokenizeCommandPrefix(const Line: string; Tokens: TStrings;
  out Current: TCommandToken): Boolean;
begin
  Result := ScanCommand(Line, Length(Line), Tokens, True, Current);
end;

function CompletionStart(const Line: string; Ending: SizeInt): SizeInt;
var
  Current: TCommandToken;
begin
  ScanCommand(Line, Ending, nil, True, Current);
  Result := Current.Offset;
end;

function EscapeSuffix(const Suffix: string; Quote: Char): string;
var
  Character: Char;
begin
  Result := '';
  for Character in Suffix do
    if (Quote = #39) and (Character = #39) then
      Result := Result + #39 + '\' + #39 + #39
    else
    begin
      if ((Quote = #0) and (Character in [' ', #9, '\', '"', #39])) or
        ((Quote = '"') and EscapesInDoubleQuote(Character)) then
        Result := Result + '\';
      Result := Result + Character;
    end;
end;

end.
