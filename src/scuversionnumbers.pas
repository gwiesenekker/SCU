unit ScuVersionNumbers;

{$mode objfpc}{$H+}

interface

function TryParseFixed(const Text: string; Places: Integer; out Units: Int64): Boolean;
function FormatFixed(Units: Int64; Places: Integer): string;

implementation

uses
  SysUtils;

function TryParseFixed(const Text: string; Places: Integer; out Units: Int64): Boolean;
var
  Index, Fraction, Digit: Integer;
begin
  Units := 0;
  if (Text = '') or not (Text[1] in ['0'..'9']) then
    Exit(False);
  Fraction := -1;
  for Index := 1 to Length(Text) do
    if (Text[Index] = '.') and (Fraction < 0) and (Index < Length(Text)) then
      Fraction := 0
    else
    begin
      if not (Text[Index] in ['0'..'9']) or (Fraction = Places) then
        Exit(False);
      Digit := Ord(Text[Index]) - Ord('0');
      if Units > (High(Int64) - Digit) div 10 then
        Exit(False);
      Units := Units * 10 + Digit;
      if Fraction >= 0 then
        Inc(Fraction);
    end;
  if Fraction < 0 then
    Fraction := 0;
  while Fraction < Places do
  begin
    if Units > High(Int64) div 10 then
      Exit(False);
    Units := Units * 10;
    Inc(Fraction);
  end;
  Result := True;
end;

function FormatFixed(Units: Int64; Places: Integer): string;
begin
  Result := IntToStr(Units);
  if Length(Result) <= Places then
    Result := StringOfChar('0', Places + 1 - Length(Result)) + Result;
  Insert('.', Result, Length(Result) - Places + 1);
end;

end.
