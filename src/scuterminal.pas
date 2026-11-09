unit ScuTerminal;

{$mode objfpc}{$H+}

interface

procedure UseTerminalLocale;
procedure TerminalSize(Handle: THandle; out Columns, Rows: Integer);
function TerminalColumns(Handle: THandle): Integer;
function CharacterSize(Lead: Char): Integer;
function NextCharacter(const Text: string; Offset: SizeInt): SizeInt;
function CellWidth(const Text: string; Start, Ending: SizeInt): Integer;
function TextWidth(const Text: string; Start, Ending: SizeInt): SizeInt;
function WrapTerminalText(const Text, BreakText: string; Width: SizeInt): string;
function FormatTerminalLines(const Text: string; Columns: SizeInt; Indentation: SizeInt = 0): string;

implementation

uses
  Classes, SysUtils, BaseUnix, Termio;

const
  LC_CTYPE = 0;

function setlocale(Category: cint; Locale: PChar): PChar; cdecl; external 'c';
function wcwidth(Character: cuint): cint; cdecl; external 'c';

procedure UseTerminalLocale;
begin
  setlocale(LC_CTYPE, '');
end;

procedure TerminalSize(Handle: THandle; out Columns, Rows: Integer);
var
  Window: TWinSize;
begin
  Columns := 0;
  Rows := 0;
  if fpIoCtl(Handle, TIOCGWINSZ, @Window) = 0 then
  begin
    Columns := Window.ws_col;
    Rows := Window.ws_row;
  end;
end;

function TerminalColumns(Handle: THandle): Integer;
var
  Rows: Integer;
begin
  TerminalSize(Handle, Result, Rows);
end;

function CharacterSize(Lead: Char): Integer;
begin
  case Lead of
    #$C2..#$DF: Result := 2;
    #$E0..#$EF: Result := 3;
    #$F0..#$F4: Result := 4;
    else Result := 1;
  end;
end;

// Positions are byte offsets between characters. Keep malformed bytes editable too.
function NextCharacter(const Text: string; Offset: SizeInt): SizeInt;
var
  Ending, Index: SizeInt;
begin
  if Offset >= Length(Text) then
    Exit(Offset);
  Ending := Offset + CharacterSize(Text[Offset + 1]);
  if Ending > Length(Text) then
    Exit(Offset + 1);
  for Index := Offset + 2 to Ending do
    if not (Text[Index] in [#$80..#$BF]) then
      Exit(Offset + 1);
  Result := Ending;
end;

function CellWidth(const Text: string; Start, Ending: SizeInt): Integer;
var
  Code: cuint;
  Index: SizeInt;
begin
  if Ending = Start + 1 then
    Exit(1);
  Code := Ord(Text[Start + 1]) and ($7F shr (Ending - Start));
  for Index := Start + 2 to Ending do
    Code := (Code shl 6) or (Ord(Text[Index]) and $3F);
  Result := wcwidth(Code);
  if Result < 0 then
    Result := 1;
end;

function TextWidth(const Text: string; Start, Ending: SizeInt): SizeInt;
var
  Next: SizeInt;
begin
  Result := 0;
  while Start < Ending do
  begin
    Next := NextCharacter(Text, Start);
    Inc(Result, CellWidth(Text, Start, Next));
    Start := Next;
  end;
end;

function WrapTerminalText(const Text, BreakText: string; Width: SizeInt): string;
var
  Plain: string;
  Start, Ending, Next, LastSpace, Used, Cells, Index: SizeInt;
begin
  Plain := Trim(Text);
  for Index := 1 to Length(Plain) do
    if Plain[Index] in [#9..#13] then
      Plain[Index] := ' ';
  Result := '';
  Start := 0;
  while Start < Length(Plain) do
  begin
    Ending := Start;
    LastSpace := Start;
    Used := 0;
    while Ending < Length(Plain) do
    begin
      if Plain[Ending + 1] = ' ' then
        LastSpace := Ending;
      Next := NextCharacter(Plain, Ending);
      Cells := CellWidth(Plain, Ending, Next);
      if (Used + Cells > Width) and (Ending > Start) then
        Break;
      Inc(Used, Cells);
      Ending := Next;
    end;
    if (Ending < Length(Plain)) and (LastSpace > Start) then
      Ending := LastSpace;
    Result := Result + TrimRight(Copy(Plain, Start + 1, Ending - Start));
    Start := Ending;
    while (Start < Length(Plain)) and (Plain[Start + 1] = ' ') do
      Inc(Start);
    if Start < Length(Plain) then
      Result := Result + BreakText;
  end;
end;

function FormatTerminalLines(const Text: string; Columns, Indentation: SizeInt): string;
var
  Lines: TStringList;
  Line, Prefix: string;
  Index, First, IndentColumns: SizeInt;
begin
  if Columns = 0 then
    Exit(StringOfChar(' ', Indentation) + Text);
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for Index := 0 to Lines.Count - 1 do
    begin
      if Index > 0 then
        Result := Result + LineEnding;
      Line := Lines[Index];
      First := 1;
      IndentColumns := Indentation;
      while (First <= Length(Line)) and (Line[First] in [' ', #9]) do
      begin
        if Line[First] = #9 then
          IndentColumns := (IndentColumns div 8 + 1) * 8
        else
          Inc(IndentColumns);
        Inc(First);
      end;
      if First > Length(Line) then
        Continue;
      if IndentColumns >= Columns then
        IndentColumns := Columns - 1;
      Prefix := StringOfChar(' ', IndentColumns);
      Result := Result + Prefix +
        WrapTerminalText(Copy(Line, First, MaxInt), LineEnding + Prefix, Columns - IndentColumns);
    end;
  finally
    Lines.Free;
  end;
end;

end.
