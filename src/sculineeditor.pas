unit ScuLineEditor;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TCommandCompletion = procedure(const Before, Prefix, After: string; Candidates: TStrings;
    out AppendCharacter: Char) of object;

function ReadTerminalLine(const Prompt: string; History: TStrings; Completion: TCommandCompletion;
  out Line: string): Boolean;

implementation

uses
  SysUtils, BaseUnix, Math, ScuErrors, ScuOutput, ScuTerminal, ScuTerminalSession, ScuTokenizer;

const
  CSI = #27'[';
  EscapeDelay = 250;
  EscapeSequenceDelay = 1000;

type
  TCompletionState = (csIdle, csPending, csListed);

  TLineEditor = class
  private
    FPrompt, FLine, FDraft, FShown: string;
    FHistory: TStrings;
    FCompletion: TCommandCompletion;
    FSession: TRawTerminalSession;
    FCursor, FDraftCursor, FViewStart, FShownCursor, FShownWidth: SizeInt;
    FHistoryIndex: Integer;
    FPending: Char;
    FHasPending, FShowingCompletion: Boolean;
    FCompletionState: TCompletionState;
    function ReadByte(out Key: Char; Timeout: Integer = -1): Boolean;
    function ReadCharacter(Lead: Char): string;
    procedure ChangePrompt(const Prompt: string);
    procedure Redraw;
    procedure Suspend;
    procedure ReplaceText(Start, Count: SizeInt; const Text: string);
    procedure Recall(Index: Integer);
    function SearchHistory: Boolean;
    procedure ReadEscape(ApplyKey: Boolean = True; HistoryMatch: Integer = -1);
    procedure ShowCompletionCandidates(Candidates: TStrings);
    procedure Complete;
  public
    constructor Create(const Prompt: string; History: TStrings; Completion: TCommandCompletion;
      Session: TRawTerminalSession);
    function ReadLine(out Line: string): Boolean;
  end;

procedure WritePrompt(const Prompt: string);
begin
  Write(StdErr, Prompt);
  Flush(StdErr);
end;

function PreviousCharacter(const Text: string; Offset: SizeInt): SizeInt;
begin
  if Offset = 0 then
    Exit(0);
  Result := Offset - 1;
  while (Result > 0) and (Offset - Result < 4) and (Text[Result + 1] in [#$80..#$BF]) do
    Dec(Result);
  if NextCharacter(Text, Result) <> Offset then
    Result := Offset - 1;
end;

function NextCursorCharacter(const Text: string; Offset: SizeInt): SizeInt;
var
  Next: SizeInt;
begin
  Result := NextCharacter(Text, Offset);
  while Result < Length(Text) do
  begin
    Next := NextCharacter(Text, Result);
    if CellWidth(Text, Result, Next) <> 0 then
      Break;
    Result := Next;
  end;
end;

function PreviousCursorCharacter(const Text: string; Offset: SizeInt): SizeInt;
begin
  Result := PreviousCharacter(Text, Offset);
  while (Result > 0) and (CellWidth(Text, Result, Offset) = 0) do
  begin
    Offset := Result;
    Result := PreviousCharacter(Text, Offset);
  end;
end;

function VisibleText(const Text: string): string;
var
  Index: SizeInt;
begin
  Result := Text;
  for Index := Length(Result) downto 1 do
    if Result[Index] in [#0..#31, #127] then
      Result[Index] := '?'
    else if (Result[Index] = #$C2) and (Index < Length(Result)) and
      (Result[Index + 1] in [#$80..#$9F]) then
    begin
      Result[Index] := '?';
      Delete(Result, Index + 1, 1);
    end;
end;

function EditorColumns: SizeInt;
begin
  Result := TerminalColumns(StdErrorHandle);
  if Result = 0 then
    Result := 80;
end;

procedure TLineEditor.ShowCompletionCandidates(Candidates: TStrings);
const
  Gap = 2;
var
  Columns, Height, PageRows, RowsLeft: Integer;
  Widest, PerRow, Index, Width: SizeInt;
  Candidate, Row: string;

  function MoreRows: Boolean;
  var
    Hint: string;
    Key: Char;
  begin
    Hint := '--More-- Space: page  Enter: line  q: quit';
    if Length(Hint) > Columns then
      Hint := Copy('--More--', 1, Columns);
    Write(StdErr, Hint);
    Flush(StdErr);
    try
      while ReadByte(Key) do
        case Key of
          ' ', #9:
            begin
              RowsLeft := PageRows;
              Exit(True);
            end;
          #10, #13:
            begin
              RowsLeft := 1;
              Exit(True);
            end;
          #3: raise ECommandCancelled.Create('Command cancelled.');
          'q', 'Q', #7: Break;
          #27:
            begin
              ReadEscape(False);
              Break;
            end;
        end;
      Result := False;
    finally
      Write(StdErr, #13, CSI, '2K');
    end;
  end;

  function WriteRow(const Text: string): Boolean;
  begin
    if Height > 0 then
    begin
      if (RowsLeft = 0) and not MoreRows then
        Exit(False);
      Dec(RowsLeft);
    end;
    WriteLn(StdErr, Text);
    Result := True;
  end;

  function WriteLongCandidate(const Text: string): Boolean;
  var
    Start, Offset, Next, Cells, Used: SizeInt;
  begin
    Start := 0;
    Offset := 0;
    Used := 0;
    while Offset < Length(Text) do
    begin
      Next := NextCharacter(Text, Offset);
      Cells := CellWidth(Text, Offset, Next);
      if (Used + Cells > Columns) and (Offset > Start) then
      begin
        if not WriteRow(Copy(Text, Start + 1, Offset - Start)) then
          Exit(False);
        Start := Offset;
        Used := 0;
      end;
      Inc(Used, Cells);
      Offset := Next;
    end;
    Result := WriteRow(Copy(Text, Start + 1, MaxInt));
  end;

begin
  TerminalSize(StdErrorHandle, Columns, Height);
  if Columns = 0 then
    Columns := 80;
  PageRows := Max(1, Height - 1);
  RowsLeft := PageRows;
  Widest := 0;
  for Candidate in Candidates do
    Widest := Max(Widest, TextWidth(Candidate, 0, Length(Candidate)));
  PerRow := Max(1, (Columns + Gap) div (Widest + Gap));
  Row := '';
  for Index := 0 to Candidates.Count - 1 do
  begin
    Candidate := VisibleText(Candidates[Index]);
    Width := TextWidth(Candidate, 0, Length(Candidate));
    if Width > Columns then
    begin
      if not WriteLongCandidate(Candidate) then
        Exit;
    end
    else if ((Index + 1) mod PerRow = 0) or (Index = Candidates.Count - 1) then
    begin
      if not WriteRow(Row + Candidate) then
        Exit;
      Row := '';
    end
    else
      Row := Row + Candidate + StringOfChar(' ', Widest - Width + Gap);
  end;
end;

procedure MoveCursor(Columns: SizeInt);
begin
  if Columns < 0 then
    Write(StdErr, CSI, -Columns, 'D')
  else if Columns > 0 then
    Write(StdErr, CSI, Columns, 'C');
end;

constructor TLineEditor.Create(const Prompt: string; History: TStrings; Completion: TCommandCompletion;
  Session: TRawTerminalSession);
begin
  inherited Create;
  FPrompt := Copy(Prompt, LastDelimiter(#10, Prompt) + 1, MaxInt);
  FHistory := History;
  if Assigned(History) then
    FHistoryIndex := History.Count;
  FCompletion := Completion;
  FSession := Session;
end;

function TLineEditor.ReadByte(out Key: Char; Timeout: Integer): Boolean;
var
  Count: ssize_t;
begin
  if FHasPending then
  begin
    Key := FPending;
    FHasPending := False;
    Exit(True);
  end;
  repeat
    Count := FSession.ReadInput(Key, SizeOf(Key), Timeout);
    case Count of
      TerminalSuspended: Suspend;
      TerminalResumed:
        begin
          FSession.ResumeEditing;
          if not FShowingCompletion then
          begin
            ChangePrompt(FPrompt);
            Redraw;
          end;
        end;
      TerminalResized:
        if not FShowingCompletion then
        begin
          ChangePrompt(FPrompt);
          Redraw;
        end;
      else Exit(Count > 0);
    end;
  until False;
end;

function TLineEditor.ReadCharacter(Lead: Char): string;
var
  Index: Integer;
  Key: Char;
begin
  Result := Lead;
  for Index := 2 to CharacterSize(Lead) do
  begin
    if not ReadByte(Key, EscapeDelay) then
      Break;
    if not (Key in [#$80..#$BF]) then
    begin
      FPending := Key;
      FHasPending := True;
      Break;
    end;
    Result := Result + Key;
  end;
end;

procedure TLineEditor.ChangePrompt(const Prompt: string);
begin
  FPrompt := Prompt;
  Write(StdErr, #13, CSI, '2K', FPrompt);
  FShown := '';
  FShownCursor := 0;
  FShownWidth := 0;
end;

procedure TLineEditor.Suspend;
begin
  FSession.Suspend;
  if not FShowingCompletion then
  begin
    ChangePrompt(FPrompt);
    Redraw;
  end;
end;

procedure TLineEditor.Redraw;
var
  Columns, Available, CursorColumn, Width, Ending, Next, Cells: SizeInt;
  Shown: string;
begin
  Columns := EditorColumns;
  Available := Max(1, Columns - TextWidth(FPrompt, 0, Length(FPrompt)) - 1);
  if FCursor < FViewStart then
    FViewStart := FCursor;
  CursorColumn := TextWidth(FLine, FViewStart, FCursor);
  while CursorColumn > Available do
  begin
    Next := NextCharacter(FLine, FViewStart);
    Dec(CursorColumn, CellWidth(FLine, FViewStart, Next));
    FViewStart := Next;
  end;

  Ending := FCursor;
  Width := CursorColumn;
  while Ending < Length(FLine) do
  begin
    Next := NextCharacter(FLine, Ending);
    Cells := CellWidth(FLine, Ending, Next);
    if Width + Cells > Available then
      Break;
    Inc(Width, Cells);
    Ending := Next;
  end;
  Shown := VisibleText(Copy(FLine, FViewStart + 1, Ending - FViewStart));
  if Shown = FShown then
    MoveCursor(CursorColumn - FShownCursor)
  else
  begin
    if (FShownCursor = FShownWidth) and (Copy(Shown, 1, Length(FShown)) = FShown) then
      Write(StdErr, Copy(Shown, Length(FShown) + 1, MaxInt))
    else
    begin
      MoveCursor(-FShownCursor);
      Write(StdErr, Shown, CSI, 'K');
    end;
    MoveCursor(CursorColumn - Width);
  end;
  FShown := Shown;
  FShownWidth := Width;
  FShownCursor := CursorColumn;
  Flush(StdErr);
end;

procedure TLineEditor.ReplaceText(Start, Count: SizeInt; const Text: string);
begin
  Delete(FLine, Start + 1, Count);
  Insert(Text, FLine, Start + 1);
  FCursor := Start + Length(Text);
  if Start < FViewStart then
    FViewStart := Start;
end;

procedure TLineEditor.Recall(Index: Integer);
begin
  if not Assigned(FHistory) or (Index < 0) or (Index > FHistory.Count) then
    Exit;
  if FHistoryIndex = FHistory.Count then
  begin
    FDraft := FLine;
    FDraftCursor := FCursor;
  end;
  FHistoryIndex := Index;
  if FHistoryIndex = FHistory.Count then
  begin
    FLine := FDraft;
    FCursor := FDraftCursor;
  end
  else
  begin
    FLine := FHistory[FHistoryIndex];
    FCursor := Length(FLine);
  end;
  FViewStart := 0;
end;

function TLineEditor.SearchHistory: Boolean;
var
  Prompt, Original, Query, Preview: string;
  Cursor, ViewStart: SizeInt;
  SearchFrom, Match, Older: Integer;
  Key: Char;

  function FindMatch(Start: Integer): Integer;
  begin
    for Result := Start downto 0 do
      if (Query = '') or (Pos(LowerCase(Query), LowerCase(FHistory[Result])) > 0) then
        Exit;
    Result := -1;
  end;

begin
  Prompt := FPrompt;
  Original := FLine;
  Cursor := FCursor;
  ViewStart := FViewStart;
  Query := '';
  SearchFrom := -1;
  if Assigned(FHistory) then
    SearchFrom := FHistory.Count - 1;
  Match := FindMatch(SearchFrom);
  ChangePrompt('(reverse-search) ');
  FViewStart := 0;
  repeat
    Preview := '(no match)';
    if Match >= 0 then
      Preview := FHistory[Match];
    FLine := Query + ' => ' + Preview;
    FCursor := Length(Query);
    Redraw;
    if not ReadByte(Key) then
      Exit(False);
    case Key of
      #3: raise ECommandCancelled.Create('Command cancelled.');
      #7, #10, #13: Break;
      #8, #127:
        begin
          SetLength(Query, PreviousCursorCharacter(Query, Length(Query)));
          Match := FindMatch(SearchFrom);
        end;
      #18:
        if Match > 0 then
        begin
          Older := FindMatch(Match - 1);
          if Older >= 0 then
          begin
            SearchFrom := Older;
            Match := Older;
          end;
        end;
      #27: Break;
      ' '..#126, #128..#255:
        begin
          Query := Query + ReadCharacter(Key);
          Match := FindMatch(SearchFrom);
        end;
    end;
  until False;
  FLine := Original;
  FCursor := Cursor;
  FViewStart := ViewStart;
  if (Key in [#10, #13]) and (Match >= 0) then
    Recall(Match);
  ChangePrompt(Prompt);
  if Key = #27 then
    ReadEscape(True, Match);
  Result := True;
end;

procedure TLineEditor.ReadEscape(ApplyKey: Boolean; HistoryMatch: Integer);
var
  Key: Char;
  Parameters: string;
begin
  if not ReadByte(Key, EscapeDelay) then
    Exit;
  if not (Key in ['[', 'O']) then
  begin
    if ApplyKey and (Key = 'b') then
    begin
      while (FCursor > 0) and (FLine[FCursor] in [' ', #9]) do
        Dec(FCursor);
      while (FCursor > 0) and not (FLine[FCursor] in [' ', #9]) do
        FCursor := PreviousCursorCharacter(FLine, FCursor);
    end
    else if ApplyKey and (Key = 'f') then
    begin
      while (FCursor < Length(FLine)) and (FLine[FCursor + 1] in [' ', #9]) do
        Inc(FCursor);
      while (FCursor < Length(FLine)) and not (FLine[FCursor + 1] in [' ', #9]) do
        FCursor := NextCursorCharacter(FLine, FCursor);
    end
    else
    begin
      FPending := Key;
      FHasPending := True;
    end;
    Exit;
  end;
  Parameters := '';
  while ReadByte(Key, EscapeSequenceDelay) do
  begin
    if Key in ['@'..'~'] then
    begin
      if not ApplyKey then
        Exit;
      if (HistoryMatch >= 0) and (Key in ['A', 'B', 'C', 'D', 'H', 'F', '~']) then
        Recall(HistoryMatch);
      case Key of
        'A': Recall(FHistoryIndex - 1);
        'B': Recall(FHistoryIndex + 1);
        'C': FCursor := NextCursorCharacter(FLine, FCursor);
        'D': FCursor := PreviousCursorCharacter(FLine, FCursor);
        'H': FCursor := 0;
        'F': FCursor := Length(FLine);
        '~': case Parameters of
          '1', '7': FCursor := 0;
          '4', '8': FCursor := Length(FLine);
          '3': ReplaceText(FCursor, NextCursorCharacter(FLine, FCursor) - FCursor, '');
        end;
      end;
      Exit;
    end;
    if not (Key in [' '..'?']) then
    begin
      FPending := Key;
      FHasPending := True;
      Exit;
    end;
    if Length(Parameters) < 16 then
      Parameters := Parameters + Key;
  end;
end;

procedure TLineEditor.Complete;
var
  Candidates: TStringList;
  Start, Shared, Index, Next: SizeInt;
  AppendCharacter: Char;
  Text, Candidate: string;
begin
  if not Assigned(FCompletion) or ((FCursor < Length(FLine)) and
    not (FLine[FCursor + 1] in [' ', #9])) then
    Exit;
  Start := CompletionStart(FLine, FCursor);
  Candidates := TStringList.Create;
  try
    try
      FCompletion(Copy(FLine, 1, Start), Copy(FLine, Start + 1, FCursor - Start),
        Copy(FLine, FCursor + 1, MaxInt), Candidates, AppendCharacter);
    except
      // A partial command or inaccessible completion source must remain editable.
      on E: ECommandCancelled do raise;
      on E: Exception do Exit;
    end;
    if Candidates.Count = 0 then
      Exit;
    Text := Candidates[0];
    if Candidates.Count = 1 then
    begin
      if (AppendCharacter <> #0) and ((AppendCharacter <> ' ') or (FCursor = Length(FLine))) then
        Text := Text + AppendCharacter;
      ReplaceText(Start, FCursor - Start, Text);
      FCompletionState := csIdle;
    end
    else if FCompletionState = csPending then
    begin
      WriteLn(StdErr);
      FShowingCompletion := True;
      try
        ShowCompletionCandidates(Candidates);
      finally
        FShowingCompletion := False;
      end;
      Write(StdErr, FPrompt);
      FShown := '';
      FShownCursor := 0;
      FShownWidth := 0;
      FCompletionState := csListed;
    end
    else if FCompletionState = csIdle then
    begin
      Shared := Length(Text);
      for Candidate in Candidates do
      begin
        Shared := Min(Shared, Length(Candidate));
        Index := 1;
        while (Index <= Shared) and (Text[Index] = Candidate[Index]) do
          Inc(Index);
        Shared := Index - 1;
      end;
      while (Shared > 0) and (Shared < Length(Text)) and (Text[Shared + 1] in [#$80..#$BF]) do
        Dec(Shared);
      // Leave a trailing escape for the user to disambiguate before inserting it.
      Next := Shared;
      while (Next > 0) and (Text[Next] = '\') do
        Dec(Next);
      if Odd(Shared - Next) then
        Dec(Shared);
      if Shared > FCursor - Start then
        ReplaceText(Start, FCursor - Start, Copy(Text, 1, Shared));
      FCompletionState := csPending;
    end;
  finally
    Candidates.Free;
  end;
end;

function TLineEditor.ReadLine(out Line: string): Boolean;
var
  Key: Char;
  Start: SizeInt;
begin
  try
    while ReadByte(Key) do
    begin
      case Key of
        #1: FCursor := 0;
        #2: FCursor := PreviousCursorCharacter(FLine, FCursor);
        #3: raise ECommandCancelled.Create('Command cancelled.');
        #4: if FLine = '' then Exit(False)
            else ReplaceText(FCursor, NextCursorCharacter(FLine, FCursor) - FCursor, '');
        #5: FCursor := Length(FLine);
        #6: FCursor := NextCursorCharacter(FLine, FCursor);
        #8, #127:
          begin
            Start := PreviousCursorCharacter(FLine, FCursor);
            ReplaceText(Start, FCursor - Start, '');
          end;
        #9: Complete;
        #10, #13:
          begin
            Line := FLine;
            Exit(True);
          end;
        #11: ReplaceText(FCursor, Length(FLine) - FCursor, '');
        #14: Recall(FHistoryIndex + 1);
        #16: Recall(FHistoryIndex - 1);
        #18: if not SearchHistory then Exit(False);
        #21: ReplaceText(0, FCursor, '');
        #26: Suspend;
        #27: ReadEscape;
        ' '..#126, #128..#255: ReplaceText(FCursor, 0, ReadCharacter(Key));
      end;
      if Key <> #9 then
        FCompletionState := csIdle;
      Redraw;
    end;
    Result := False;
  finally
    WriteDiagnostic('');
  end;
end;

function ReadTerminalLine(const Prompt: string; History: TStrings; Completion: TCommandCompletion;
  out Line: string): Boolean;
var
  Session: TRawTerminalSession;
  Editor: TLineEditor;
  Buffer: array[0..4095] of Char;
  Count: ssize_t;
begin
  Session := TRawTerminalSession.Create;
  try
    if not Session.Ready then
      Exit(False);
    if not Session.RawMode then
    begin
      WritePrompt(Prompt);
      Count := Session.ReadInput(Buffer, SizeOf(Buffer), -1);
      if Count = 0 then
        Exit(False);
      if Buffer[Count - 1] = #10 then
        Dec(Count);
      SetString(Line, PChar(@Buffer[0]), Count);
      Exit(True);
    end;

    UseTerminalLocale;
    Editor := TLineEditor.Create(Prompt, History, Completion, Session);
    try
      WritePrompt(Prompt);
      Result := Editor.ReadLine(Line);
    finally
      Editor.Free;
    end;
  finally
    Session.Free;
  end;
end;

end.
