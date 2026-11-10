unit ScuDirectives;

{$mode objfpc}{$H+}

interface

uses
  Classes;

const
  CopyDirective = 'SCU_COPY';

function IsIdentifierChar(Value: Char): Boolean;
function HasToken(const Line: RawByteString; Index: SizeInt; const Token: string): Boolean;
procedure ReadSourceLine(const Source: RawByteString; var Index: SizeInt; out Line, Ending: RawByteString);
function DirectiveStart(const Line: RawByteString; const Prefix: string; out First: SizeInt): SizeInt;
function TryCopyTarget(const Line: RawByteString; Directive: SizeInt; out Target: string): Boolean;
procedure CollectCopyTargets(const Source: RawByteString; const Prefix: string; Targets: TStrings);

implementation

uses
  SysUtils, ScuSignals;

function IsIdentifierChar(Value: Char): Boolean;
begin
  Result := Value in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

function HasToken(const Line: RawByteString; Index: SizeInt; const Token: string): Boolean;
var
  Last, TokenLength: SizeInt;
begin
  TokenLength := Length(Token);
  Last := Index + TokenLength - 1;
  Result := (Index >= 1) and (TokenLength > 0) and (Last <= Length(Line)) and
    ((Last = Length(Line)) or not IsIdentifierChar(Line[Last + 1])) and
    (CompareByte(Line[Index], Token[1], TokenLength) = 0);
end;

procedure ReadSourceLine(const Source: RawByteString; var Index: SizeInt;
  out Line, Ending: RawByteString);
var
  Start: SizeInt;
begin
  Start := Index;
  while (Index <= Length(Source)) and not (Source[Index] in [#10, #13]) do
    Inc(Index);
  Line := Copy(Source, Start, Index - Start);
  Start := Index;
  if (Index <= Length(Source)) and (Source[Index] = #13) then
    Inc(Index);
  if (Index <= Length(Source)) and (Source[Index] = #10) then
    Inc(Index);
  Ending := Copy(Source, Start, Index - Start);
end;

function DirectiveStart(const Line: RawByteString; const Prefix: string; out First: SizeInt): SizeInt;
begin
  First := 1;
  while (First <= Length(Line)) and (Line[First] in [' ', #9]) do
    Inc(First);
  if Copy(Line, First, Length(Prefix)) = Prefix then
    Exit(First + Length(Prefix));
  Result := 0;
end;

function TryCopyTarget(const Line: RawByteString; Directive: SizeInt; out Target: string): Boolean;
var
  Separator: SizeInt;
begin
  Separator := Directive + Length(CopyDirective);
  Result := (Separator <= Length(Line)) and (Line[Separator] in [' ', #9]);
  if Result then
    Target := Trim(Copy(Line, Separator, MaxInt));
end;

procedure CollectCopyTargets(const Source: RawByteString; const Prefix: string; Targets: TStrings);
var
  Index, First, Directive, Lines: SizeInt;
  Line, Ending: RawByteString;
  Target: string;
begin
  Index := 1;
  Lines := 0;
  while Index <= Length(Source) do
  begin
    if (Lines and 255) = 0 then
      CheckSessionInterrupt;
    Inc(Lines);
    ReadSourceLine(Source, Index, Line, Ending);
    Directive := DirectiveStart(Line, Prefix, First);
    if (Directive <> 0) and HasToken(Line, Directive, CopyDirective) and
      TryCopyTarget(Line, Directive, Target) and (Target <> '') and (Length(Target) <= 128) then
      Targets.Add(LowerCase(Target));
  end;
end;

end.
