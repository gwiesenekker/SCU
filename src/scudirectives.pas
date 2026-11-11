unit ScuDirectives;

{$mode objfpc}{$H+}

interface

uses
  Classes;

const
  CopyDirective = 'SCU_COPY';

function IsIdentifierChar(Value: Char): Boolean;
function HasToken(const Line: RawByteString; Index, LineEnd: SizeInt; const Token: string): Boolean;
procedure ReadSourceLine(const Source: RawByteString; var Index: SizeInt; out EndingStart: SizeInt);
function DirectiveStart(const Line: RawByteString; const Prefix: string; LineStart, LineEnd: SizeInt; out First: SizeInt): SizeInt;
function TryCopyTarget(const Line: RawByteString; Directive, LineEnd: SizeInt; out Target: string): Boolean;
procedure CollectCopyTargets(const Source: RawByteString; const Prefix: string; Targets: TStrings);

implementation

uses
  SysUtils, ScuSignals;

function IsIdentifierChar(Value: Char): Boolean;
begin
  Result := Value in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

function HasToken(const Line: RawByteString; Index, LineEnd: SizeInt; const Token: string): Boolean;
var
  Last, TokenLength: SizeInt;
begin
  TokenLength := Length(Token);
  Last := Index + TokenLength - 1;
  Result := (Index >= 1) and (TokenLength > 0) and (Last <= LineEnd) and
    ((Last = LineEnd) or not IsIdentifierChar(Line[Last + 1])) and
    (CompareByte(Line[Index], Token[1], TokenLength) = 0);
end;

procedure ReadSourceLine(const Source: RawByteString; var Index: SizeInt;
  out EndingStart: SizeInt);
begin
  while (Index <= Length(Source)) and not (Source[Index] in [#10, #13]) do
    Inc(Index);
  EndingStart := Index;
  if (Index <= Length(Source)) and (Source[Index] = #13) then
    Inc(Index);
  if (Index <= Length(Source)) and (Source[Index] = #10) then
    Inc(Index);
end;

function DirectiveStart(const Line: RawByteString; const Prefix: string; LineStart, LineEnd: SizeInt; out First: SizeInt): SizeInt;
begin
  First := LineStart;
  while (First <= LineEnd) and (Line[First] in [' ', #9]) do
    Inc(First);
  if (Prefix = '') or ((First + Length(Prefix) - 1 <= LineEnd) and
    (CompareByte(Line[First], Prefix[1], Length(Prefix)) = 0)) then
    Exit(First + Length(Prefix));
  Result := 0;
end;

function TryCopyTarget(const Line: RawByteString; Directive, LineEnd: SizeInt; out Target: string): Boolean;
var
  Separator: SizeInt;
begin
  Separator := Directive + Length(CopyDirective);
  Result := (Separator <= LineEnd) and (Line[Separator] in [' ', #9]);
  if Result then
    Target := Trim(Copy(Line, Separator, LineEnd - Separator + 1));
end;

procedure CollectCopyTargets(const Source: RawByteString; const Prefix: string; Targets: TStrings);
var
  Index, LineStart, EndingStart, First, Directive, Lines: SizeInt;
  Target: string;
begin
  Index := 1;
  Lines := 0;
  while Index <= Length(Source) do
  begin
    if (Lines and 255) = 0 then
      CheckSessionInterrupt;
    Inc(Lines);
    LineStart := Index;
    ReadSourceLine(Source, Index, EndingStart);
    Directive := DirectiveStart(Source, Prefix, LineStart, EndingStart - 1, First);
    if (Directive <> 0) and HasToken(Source, Directive, EndingStart - 1, CopyDirective) and
      TryCopyTarget(Source, Directive, EndingStart - 1, Target) and (Target <> '') and (Length(Target) <= 128) then
      Targets.Add(LowerCase(Target));
  end;
end;

end.
