unit ScuDiff;

{$mode objfpc}{$H+}

interface

uses
  ScuOutput;

type
  TDiffFormat = (dfNormal, dfUnified);

function ParseDiffFormat(const Value: string): TDiffFormat;

procedure WriteDeckDiff(const OldSource, NewSource: RawByteString; const OldLabel, NewLabel: string;
  Output: TScuOutput; IgnoreSpaceChanges: Boolean = True; Format: TDiffFormat = dfNormal;
  ShowNormalLabels: Boolean = False; const OldMarker: string = ''; const NewMarker: string = '');

implementation

uses
  SysUtils, ScuDiffLines, ScuErrors, ScuSignals;

function ParseDiffFormat(const Value: string): TDiffFormat;
begin
  if SameText(Value, 'normal') then
    Exit(dfNormal);
  if SameText(Value, 'unified') then
    Exit(dfUnified);
  raise EScuError.Create('Expected normal or unified for output_format.');
end;

const
  ContextLines = 3;
  MaxEditDistance = 3072;
  MaxSearchBytes = 256 * 1024 * 1024;
  MaxIndexedLines = 2000000;

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
  TIndexedLine = record
    Ending: Integer;
    Hash: Cardinal;
  end;
  TLineIndex = array of TIndexedLine;

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

function IsHeader(const Source, Marker: RawByteString; Offset: Integer): Boolean;
begin
  Result := (Marker <> '') and (Length(Source) - Offset >= Length(Marker)) and
    CompareMem(@Source[Offset + 1], Pointer(Marker), Length(Marker));
end;

function LinesMatch(const OldSource, NewSource, OldMarker, NewMarker: RawByteString;
  OldOffset, NewOffset, OldEnd, NewEnd: Integer; IgnoreSpaceChanges: Boolean): Boolean;
var
  OldHeader, NewHeader: Boolean;
begin
  OldHeader := IsHeader(OldSource, OldMarker, OldOffset);
  NewHeader := IsHeader(NewSource, NewMarker, NewOffset);
  if OldHeader or NewHeader then Exit(OldHeader and NewHeader);
  Result := SameDiffLine(OldSource, NewSource, OldOffset, NewOffset, OldEnd, NewEnd, IgnoreSpaceChanges);
end;

function IndexLines(const Source, Marker: RawByteString; IgnoreSpaceChanges: Boolean): TLineIndex;
var
  Count, Offset, Index, Ending: Integer;
begin
  Result := nil;
  Count := 0;
  Offset := 0;
  while Offset < Length(Source) do
  begin
    Offset := LineEnd(Source, Offset);
    Inc(Count);
    if Count > MaxIndexedLines then
      Exit;
  end;
  SetLength(Result, Count);
  Offset := 0;
  for Index := 0 to Count - 1 do
  begin
    Ending := LineEnd(Source, Offset);
    Result[Index].Ending := Ending;
    if IsHeader(Source, Marker, Offset) then Result[Index].Hash := 0
    else Result[Index].Hash := DiffLineHash(Source, Offset, Ending, IgnoreSpaceChanges);
    Offset := Ending;
  end;
end;

function FindChanges(const OldSource, NewSource, OldMarker, NewMarker: RawByteString; out Changes: TChanges;
  out Prefix: TPosition; IgnoreSpaceChanges: Boolean): Boolean;
var
  Frontier: array[0..1] of array of TPosition;
  Trace: array of array of Boolean;
  EditPath: array of Boolean;
  Distance, Deletions, Back, Index, Count, Current, Previous: Integer;
  Budget: Int64;
  Position: TPosition;
  CanDelete, CanInsert, Deleted, Indexed: Boolean;
  OldLines, NewLines: TLineIndex;

  procedure MatchLines(var Position: TPosition);
  var
    OldEnd, NewEnd: Integer;
  begin
    while (Budget > 0) and (Position.OldLine.Offset < Length(OldSource)) and
      (Position.NewLine.Offset < Length(NewSource)) do
    begin
      if Indexed then
      begin
        Dec(Budget, SizeOf(TIndexedLine) * 2);
        if OldLines[Position.OldLine.Lines].Hash <> NewLines[Position.NewLine.Lines].Hash then
          Break;
        OldEnd := OldLines[Position.OldLine.Lines].Ending;
        NewEnd := NewLines[Position.NewLine.Lines].Ending;
      end
      else
      begin
        OldEnd := LineEnd(OldSource, Position.OldLine.Offset);
        NewEnd := LineEnd(NewSource, Position.NewLine.Offset);
        Dec(Budget, (OldEnd - Position.OldLine.Offset) + (NewEnd - Position.NewLine.Offset));
      end;
      if not LinesMatch(OldSource, NewSource, OldMarker, NewMarker, Position.OldLine.Offset, Position.NewLine.Offset,
        OldEnd, NewEnd, IgnoreSpaceChanges) then
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
      if Indexed then
      begin
        Position.OldLine.Offset := OldLines[Position.OldLine.Lines].Ending;
        Inc(Position.OldLine.Lines);
        Dec(Budget, SizeOf(TIndexedLine));
        Exit;
      end;
      Start := Position.OldLine.Offset;
      Advance(OldSource, Position.OldLine);
      Dec(Budget, Position.OldLine.Offset - Start);
    end
    else
    begin
      if Indexed then
      begin
        Position.NewLine.Offset := NewLines[Position.NewLine.Lines].Ending;
        Inc(Position.NewLine.Lines);
        Dec(Budget, SizeOf(TIndexedLine));
        Exit;
      end;
      Start := Position.NewLine.Offset;
      Advance(NewSource, Position.NewLine);
      Dec(Budget, Position.NewLine.Offset - Start);
    end;
  end;

begin
  Budget := MaxSearchBytes;
  OldLines := IndexLines(OldSource, OldMarker, IgnoreSpaceChanges);
  NewLines := IndexLines(NewSource, NewMarker, IgnoreSpaceChanges);
  Indexed := ((Length(OldLines) > 0) or (OldSource = '')) and
    ((Length(NewLines) > 0) or (NewSource = ''));
  Prefix := Default(TPosition);
  MatchLines(Prefix);
  if (Prefix.OldLine.Offset = Length(OldSource)) and (Prefix.NewLine.Offset = Length(NewSource)) then
  begin
    Changes := nil;
    Exit(True);
  end;
  SetLength(Trace, MaxEditDistance + 1);
  SetLength(Frontier[0], MaxEditDistance + 1);
  SetLength(Frontier[1], MaxEditDistance + 1);
  Frontier[0][0] := Prefix;

  // Myers search only needs the previous frontier. Keep the edit decisions
  // for backtracking and replay the winning path to recover byte offsets.
  for Distance := 1 to MaxEditDistance do
  begin
    CheckSessionInterrupt;
    Current := Distance mod 2;
    Previous := 1 - Current;
    SetLength(Trace[Distance], Distance + 1);
    for Deletions := 0 to Distance do
    begin
      if Budget <= 0 then
        Exit(False);
      CanDelete := (Deletions > 0) and
        (Frontier[Previous][Deletions - 1].OldLine.Offset >= 0) and
        (Frontier[Previous][Deletions - 1].OldLine.Offset < Length(OldSource));
      CanInsert := (Deletions < Distance) and
        (Frontier[Previous][Deletions].OldLine.Offset >= 0) and
        (Frontier[Previous][Deletions].NewLine.Offset < Length(NewSource));
      if not (CanDelete or CanInsert) then
      begin
        Frontier[Current][Deletions].OldLine.Offset := -1;
        Continue;
      end;
      Deleted := CanDelete and (not CanInsert or
        (Frontier[Previous][Deletions - 1].OldLine.Offset >=
         Frontier[Previous][Deletions].OldLine.Offset));
      Position := Frontier[Previous][Deletions - Ord(Deleted)];
      ApplyEdit(Position, Deleted);
      MatchLines(Position);
      Frontier[Current][Deletions] := Position;
      Trace[Distance][Deletions] := Deleted;
      if (Position.OldLine.Offset <> Length(OldSource)) or
        (Position.NewLine.Offset <> Length(NewSource)) then
        Continue;

      SetLength(EditPath, Distance);
      Back := Deletions;
      for Index := Distance downto 1 do
      begin
        Deleted := Trace[Index][Back];
        EditPath[Index - 1] := Deleted;
        Dec(Back, Ord(Deleted));
      end;
      SetLength(Changes, Distance);
      Budget := MaxSearchBytes;
      Position := Prefix;
      for Index := 0 to High(EditPath) do
      begin
        CheckSessionInterrupt;
        Changes[Index].First := Position;
        ApplyEdit(Position, EditPath[Index]);
        Changes[Index].After := Position;
        MatchLines(Position);
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

function Replacement(const OldSource, NewSource, OldMarker, NewMarker: RawByteString; const Prefix: TPosition;
  IgnoreSpaceChanges: Boolean): TChange;
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
    if not LinesMatch(OldSource, NewSource, OldMarker, NewMarker, Tail.OldLine.Offset, Tail.NewLine.Offset,
      Result.After.OldLine.Offset, Result.After.NewLine.Offset, IgnoreSpaceChanges) then
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

procedure WriteLines(Output: TScuOutput; const Marker: string; const Source: RawByteString; First, After: Integer);
var
  Ending: Integer;
begin
  while First < After do
  begin
    Ending := LineEnd(Source, First);
    Output.Write(Marker);
    Output.Write(Copy(Source, First + 1, Ending - First));
    if Source[Ending] <> #10 then
    begin
      Output.WriteLine('');
      Output.WriteLine('\ No newline at end of file');
    end;
    First := Ending;
  end;
end;

procedure WriteHunk(Output: TScuOutput; const OldSource, NewSource: RawByteString; const Changes: TChanges;
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
  Output.WriteLine('@@ -' + HunkRange(Start.OldLine.Lines, Finish.OldLine.Lines) +
    ' +' + HunkRange(Start.NewLine.Lines, Finish.NewLine.Lines) + ' @@');
  Previous := Start.OldLine.Offset;
  for Index := First to Last do
  begin
    WriteLines(Output, ' ', OldSource, Previous, Changes[Index].First.OldLine.Offset);
    WriteLines(Output, '-', OldSource, Changes[Index].First.OldLine.Offset, Changes[Index].After.OldLine.Offset);
    WriteLines(Output, '+', NewSource, Changes[Index].First.NewLine.Offset, Changes[Index].After.NewLine.Offset);
    Previous := Changes[Index].After.OldLine.Offset;
  end;
  WriteLines(Output, ' ', OldSource, Previous, Finish.OldLine.Offset);
end;

function NormalRange(First, After: Integer): string;
begin
  if First = After then
    Exit(IntToStr(First));
  Result := IntToStr(First + 1);
  if After > First + 1 then
    Result := Result + ',' + IntToStr(After);
end;

procedure WriteNormalChange(Output: TScuOutput; const OldSource, NewSource: RawByteString;
  const Change: TChange);
var
  Operation: Char;
  HasOld, HasNew: Boolean;
begin
  HasOld := Change.After.OldLine.Lines > Change.First.OldLine.Lines;
  HasNew := Change.After.NewLine.Lines > Change.First.NewLine.Lines;
  Operation := 'c';
  if not HasOld then
    Operation := 'a'
  else if not HasNew then
    Operation := 'd';
  Output.WriteLine(NormalRange(Change.First.OldLine.Lines, Change.After.OldLine.Lines) +
    Operation + NormalRange(Change.First.NewLine.Lines, Change.After.NewLine.Lines));
  WriteLines(Output, '< ', OldSource, Change.First.OldLine.Offset, Change.After.OldLine.Offset);
  if HasOld and HasNew then
    Output.WriteLine('---');
  WriteLines(Output, '> ', NewSource, Change.First.NewLine.Offset, Change.After.NewLine.Offset);
end;

function OnlyHeaders(const Source, Marker: RawByteString; First, After: Integer): Boolean;
begin
  while First < After do
  begin
    if not IsHeader(Source, Marker, First) then Exit(False);
    First := LineEnd(Source, First);
  end;
  Result := True;
end;

procedure WriteDeckDiff(const OldSource, NewSource: RawByteString; const OldLabel, NewLabel: string;
  Output: TScuOutput; IgnoreSpaceChanges: Boolean; Format: TDiffFormat;
  ShowNormalLabels: Boolean; const OldMarker, NewMarker: string);
var
  Changes: TChanges;
  Prefix: TPosition;
  First, Last, Index: Integer;
  Printed, Visible: Boolean;

  function VisibleChange(const Change: TChange): Boolean;
  begin
    Result := not (OnlyHeaders(OldSource, OldMarker, Change.First.OldLine.Offset, Change.After.OldLine.Offset)
      and OnlyHeaders(NewSource, NewMarker, Change.First.NewLine.Offset, Change.After.NewLine.Offset));
  end;

begin
  if OldSource = NewSource then
    Exit;
  if (Pos(#0, OldSource) > 0) or (Pos(#0, NewSource) > 0) then
  begin
    Output.WriteLine('Binary files ' + OldLabel + ' and ' + NewLabel + ' differ');
    Exit;
  end;

  if not FindChanges(OldSource, NewSource, OldMarker, NewMarker, Changes, Prefix, IgnoreSpaceChanges) then
  begin
    SetLength(Changes, 1);
    Changes[0] := Replacement(OldSource, NewSource, OldMarker, NewMarker, Prefix, IgnoreSpaceChanges);
  end;
  if Length(Changes) = 0 then
    Exit;
  Printed := False;
  if Format = dfNormal then
  begin
    for First := 0 to High(Changes) do
    begin
      CheckSessionInterrupt;
      if not VisibleChange(Changes[First]) then Continue;
      if ShowNormalLabels and not Printed then Output.WriteLine('diff ' + OldLabel + ' ' + NewLabel);
      Printed := True;
      WriteNormalChange(Output, OldSource, NewSource, Changes[First]);
    end;
    Exit;
  end;
  First := 0;
  while First < Length(Changes) do
  begin
    Last := First;
    while (Last < High(Changes)) and
      (Changes[Last + 1].First.OldLine.Lines - Changes[Last].After.OldLine.Lines <= 2 * ContextLines) do
      Inc(Last);
    Visible := False;
    for Index := First to Last do
      if VisibleChange(Changes[Index]) then Visible := True;
    if Visible then
    begin
      if not Printed then
      begin
        Output.WriteLine('--- ' + OldLabel);
        Output.WriteLine('+++ ' + NewLabel);
        Printed := True;
      end;
      WriteHunk(Output, OldSource, NewSource, Changes, First, Last);
    end;
    First := Last + 1;
  end;
end;

end.
