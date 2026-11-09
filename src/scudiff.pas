unit ScuDiff;

{$mode objfpc}{$H+}

interface

procedure WriteDeckDiff(const OldSource, NewSource: RawByteString; const OldLabel, NewLabel: string);

implementation

uses
  SysUtils;

const
  ContextLines = 3;
  MaxEditDistance = 1024;
  MaxSearchBytes = 256 * 1024 * 1024;

type
  TLinePosition = record
    Offset, Lines: Integer;
  end;
  TPosition = record
    OldLine, NewLine: TLinePosition;
  end;
  TChange = record
    First, After: TPosition;
  end;
  TChanges = array of TChange;
  TTraceStep = record
    After: TPosition;
    Deleted: Boolean;
  end;

// Offsets count consumed bytes. A line includes its LF if present.
function LineEnd(const Source: RawByteString; Offset: Integer): Integer;
begin
  Result := Pos(#10, Source, Offset + 1);
  if Result = 0 then
    Result := Length(Source);
end;

procedure Advance(const Source: RawByteString; var Position: TLinePosition);
begin
  Position.Offset := LineEnd(Source, Position.Offset);
  Inc(Position.Lines);
end;

procedure Retreat(const Source: RawByteString; var Position: TLinePosition);
begin
  Dec(Position.Lines);
  Dec(Position.Offset);
  while (Position.Offset > 0) and (Source[Position.Offset] <> #10) do
    Dec(Position.Offset);
end;

function SameLine(const OldSource, NewSource: RawByteString; OldStart, NewStart,
  OldEnd, NewEnd: Integer): Boolean;
begin
  Result := (OldEnd - OldStart = NewEnd - NewStart) and
    CompareMem(@OldSource[OldStart + 1], @NewSource[NewStart + 1], OldEnd - OldStart);
end;

function FindChanges(const OldSource, NewSource: RawByteString; out Changes: TChanges;
  out Prefix: TPosition): Boolean;
var
  Trace: array of array of TTraceStep;
  Distance, Deletions, Back, Index, Count: Integer;
  Budget: Int64;
  Step: TTraceStep;
  CanDelete, CanInsert: Boolean;

  procedure MatchLines(var Position: TPosition);
  var
    OldEnd, NewEnd: Integer;
  begin
    while (Budget > 0) and (Position.OldLine.Offset < Length(OldSource)) and
      (Position.NewLine.Offset < Length(NewSource)) do
    begin
      OldEnd := LineEnd(OldSource, Position.OldLine.Offset);
      NewEnd := LineEnd(NewSource, Position.NewLine.Offset);
      Dec(Budget, (OldEnd - Position.OldLine.Offset) + (NewEnd - Position.NewLine.Offset));
      if not SameLine(OldSource, NewSource, Position.OldLine.Offset, Position.NewLine.Offset,
        OldEnd, NewEnd) then
        Break;
      Position.OldLine.Offset := OldEnd;
      Position.NewLine.Offset := NewEnd;
      Inc(Position.OldLine.Lines);
      Inc(Position.NewLine.Lines);
    end;
  end;

  procedure ApplyEdit(var Position: TPosition; Deleted: Boolean);
  var
    Start: Integer;
  begin
    if Deleted then
    begin
      Start := Position.OldLine.Offset;
      Advance(OldSource, Position.OldLine);
      Dec(Budget, Position.OldLine.Offset - Start);
    end
    else
    begin
      Start := Position.NewLine.Offset;
      Advance(NewSource, Position.NewLine);
      Dec(Budget, Position.NewLine.Offset - Start);
    end;
  end;

begin
  Budget := MaxSearchBytes;
  Prefix := Default(TPosition);
  MatchLines(Prefix);
  SetLength(Trace, MaxEditDistance + 1);
  SetLength(Trace[0], 1);
  Trace[0][0].After := Prefix;

  // Myers search. Row d stores the furthest position on each reachable
  // diagonal after d edits. The row index counts deletions.
  for Distance := 1 to MaxEditDistance do
  begin
    SetLength(Trace[Distance], Distance + 1);
    for Deletions := 0 to Distance do
    begin
      if Budget <= 0 then
        Exit(False);
      CanDelete := (Deletions > 0) and
        (Trace[Distance - 1][Deletions - 1].After.OldLine.Offset >= 0) and
        (Trace[Distance - 1][Deletions - 1].After.OldLine.Offset < Length(OldSource));
      CanInsert := (Deletions < Distance) and
        (Trace[Distance - 1][Deletions].After.OldLine.Offset >= 0) and
        (Trace[Distance - 1][Deletions].After.NewLine.Offset < Length(NewSource));
      if not (CanDelete or CanInsert) then
      begin
        Trace[Distance][Deletions].After.OldLine.Offset := -1;
        Continue;
      end;
      Step.Deleted := CanDelete and (not CanInsert or
        (Trace[Distance - 1][Deletions - 1].After.OldLine.Offset >=
         Trace[Distance - 1][Deletions].After.OldLine.Offset));
      Step.After := Trace[Distance - 1][Deletions - Ord(Step.Deleted)].After;
      ApplyEdit(Step.After, Step.Deleted);
      MatchLines(Step.After);
      Trace[Distance][Deletions] := Step;
      if (Step.After.OldLine.Offset <> Length(OldSource)) or
        (Step.After.NewLine.Offset <> Length(NewSource)) then
        Continue;

      SetLength(Changes, Distance);
      Back := Deletions;
      for Index := Distance downto 1 do
      begin
        Step := Trace[Index][Back];
        Dec(Back, Ord(Step.Deleted));
        Changes[Index - 1].First := Trace[Index - 1][Back].After;
        Changes[Index - 1].After := Changes[Index - 1].First;
        ApplyEdit(Changes[Index - 1].After, Step.Deleted);
      end;
      // Combine adjacent edits so each replacement lists removals first.
      Count := 1;
      for Index := 1 to High(Changes) do
        if Changes[Count - 1].After.OldLine.Offset = Changes[Index].First.OldLine.Offset then
          Changes[Count - 1].After := Changes[Index].After
        else
        begin
          Changes[Count] := Changes[Index];
          Inc(Count);
        end;
      SetLength(Changes, Count);
      Exit(True);
    end;
  end;
  Result := False;
end;

function Replacement(const OldSource, NewSource: RawByteString; const Prefix: TPosition): TChange;
var
  Tail: TPosition;
begin
  // Bound the search on very different decks. Keep the shared ends and
  // represent the remaining region as a single valid replacement.
  Result.First := Prefix;
  Result.After := Prefix;
  while Result.After.OldLine.Offset < Length(OldSource) do
    Advance(OldSource, Result.After.OldLine);
  while Result.After.NewLine.Offset < Length(NewSource) do
    Advance(NewSource, Result.After.NewLine);
  while (Result.After.OldLine.Offset > Prefix.OldLine.Offset) and
    (Result.After.NewLine.Offset > Prefix.NewLine.Offset) do
  begin
    Tail := Result.After;
    Retreat(OldSource, Tail.OldLine);
    Retreat(NewSource, Tail.NewLine);
    if not SameLine(OldSource, NewSource, Tail.OldLine.Offset, Tail.NewLine.Offset,
      Result.After.OldLine.Offset, Result.After.NewLine.Offset) then
      Break;
    Result.After := Tail;
  end;
end;

function HunkRange(First, After: Integer): string;
begin
  if First = After then
    Exit(IntToStr(First) + ',0');
  Result := IntToStr(First + 1);
  if After > First + 1 then
    Result := Result + ',' + IntToStr(After - First);
end;

procedure WriteLines(Marker: Char; const Source: RawByteString; First, After: Integer);
var
  Ending: Integer;
  Line: RawByteString;
begin
  while First < After do
  begin
    Ending := LineEnd(Source, First);
    Line := Copy(Source, First + 1, Ending - First);
    // Emit the stored bytes without text output transcoding them.
    SetCodePage(Line, TextRec(Output).CodePage, False);
    Write(Marker, Line);
    if Source[Ending] <> #10 then
    begin
      WriteLn;
      WriteLn('\ No newline at end of file');
    end;
    First := Ending;
  end;
end;

procedure WriteHunk(const OldSource, NewSource: RawByteString; const Changes: TChanges;
  First, Last: Integer);
var
  Start, Finish: TPosition;
  Index, Previous: Integer;
begin
  Start := Changes[First].First;
  Finish := Changes[Last].After;
  for Index := 1 to ContextLines do
  begin
    if Start.OldLine.Lines > 0 then
    begin
      Retreat(OldSource, Start.OldLine);
      Retreat(NewSource, Start.NewLine);
    end;
    if (Finish.OldLine.Offset < Length(OldSource)) and (Finish.NewLine.Offset < Length(NewSource)) then
    begin
      Advance(OldSource, Finish.OldLine);
      Advance(NewSource, Finish.NewLine);
    end;
  end;
  WriteLn('@@ -', HunkRange(Start.OldLine.Lines, Finish.OldLine.Lines),
    ' +', HunkRange(Start.NewLine.Lines, Finish.NewLine.Lines), ' @@');
  Previous := Start.OldLine.Offset;
  for Index := First to Last do
  begin
    WriteLines(' ', OldSource, Previous, Changes[Index].First.OldLine.Offset);
    WriteLines('-', OldSource, Changes[Index].First.OldLine.Offset, Changes[Index].After.OldLine.Offset);
    WriteLines('+', NewSource, Changes[Index].First.NewLine.Offset, Changes[Index].After.NewLine.Offset);
    Previous := Changes[Index].After.OldLine.Offset;
  end;
  WriteLines(' ', OldSource, Previous, Finish.OldLine.Offset);
end;

procedure WriteDeckDiff(const OldSource, NewSource: RawByteString; const OldLabel, NewLabel: string);
var
  Changes: TChanges;
  Prefix: TPosition;
  First, Last: Integer;
begin
  if OldSource = NewSource then
    Exit;
  if (Pos(#0, OldSource) > 0) or (Pos(#0, NewSource) > 0) then
  begin
    WriteLn('Binary files ', OldLabel, ' and ', NewLabel, ' differ');
    Exit;
  end;

  if not FindChanges(OldSource, NewSource, Changes, Prefix) then
  begin
    SetLength(Changes, 1);
    Changes[0] := Replacement(OldSource, NewSource, Prefix);
  end;
  WriteLn('--- ', OldLabel);
  WriteLn('+++ ', NewLabel);
  First := 0;
  while First < Length(Changes) do
  begin
    Last := First;
    while (Last < High(Changes)) and
      (Changes[Last + 1].First.OldLine.Lines - Changes[Last].After.OldLine.Lines <= 2 * ContextLines) do
      Inc(Last);
    WriteHunk(OldSource, NewSource, Changes, First, Last);
    First := Last + 1;
  end;
end;

end.
