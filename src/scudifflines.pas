unit ScuDiffLines;

{$mode objfpc}{$H+}

interface

function SameDiffLine(const OldSource, NewSource: RawByteString; OldStart, NewStart,
  OldEnd, NewEnd: Integer; IgnoreSpaceChanges: Boolean): Boolean;
function DiffLineHash(const Source: RawByteString; First, After: Integer;
  IgnoreSpaceChanges: Boolean): Cardinal;

implementation

uses
  SysUtils;

function ContentEnd(const Source: RawByteString; First, After: Integer): Integer;
begin
  Result := After;
  if (After > First) and (Source[After] = #10) then
    Dec(Result);
end;

function NextComparedByte(const Source: RawByteString; var Position: Integer;
  Ending: Integer; out Character: Char): Boolean;
begin
  if Position > Ending then
    Exit(False);
  Character := Source[Position];
  Inc(Position);
  if Character in [#9, #11, #12, #13, ' '] then
  begin
    while (Position <= Ending) and (Source[Position] in [#9, #11, #12, #13, ' ']) do
      Inc(Position);
    // Discard trailing whitespace; retain one space for an interior run.
    if Position > Ending then
      Exit(False);
    Character := ' ';
  end;
  Result := True;
end;

function SameDiffLine(const OldSource, NewSource: RawByteString; OldStart, NewStart,
  OldEnd, NewEnd: Integer; IgnoreSpaceChanges: Boolean): Boolean;
var
  OldPosition, NewPosition: Integer;
  OldByte, NewByte: Char;
  HasOld, HasNew: Boolean;
begin
  if not IgnoreSpaceChanges then
    Exit((OldEnd - OldStart = NewEnd - NewStart) and
      CompareMem(@OldSource[OldStart + 1], @NewSource[NewStart + 1], OldEnd - OldStart));
  OldPosition := OldStart + 1;
  NewPosition := NewStart + 1;
  OldEnd := ContentEnd(OldSource, OldStart, OldEnd);
  NewEnd := ContentEnd(NewSource, NewStart, NewEnd);
  repeat
    HasOld := NextComparedByte(OldSource, OldPosition, OldEnd, OldByte);
    HasNew := NextComparedByte(NewSource, NewPosition, NewEnd, NewByte);
    if HasOld <> HasNew then
      Exit(False);
    if not HasOld then
      Exit(True);
    if OldByte <> NewByte then
      Exit(False);
  until False;
end;

function DiffLineHash(const Source: RawByteString; First, After: Integer;
  IgnoreSpaceChanges: Boolean): Cardinal;
var
  Position: Integer;
  Character: Char;
begin
  Result := 2166136261;
  Position := First + 1;
  if IgnoreSpaceChanges then
  begin
    After := ContentEnd(Source, First, After);
    while NextComparedByte(Source, Position, After, Character) do
      Result := (Result xor Ord(Character)) * 16777619;
  end
  else
    while Position <= After do
    begin
      Result := (Result xor Ord(Source[Position])) * 16777619;
      Inc(Position);
    end;
end;

end.
