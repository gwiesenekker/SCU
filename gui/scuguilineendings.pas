unit ScuGuiLineEndings;
{$mode objfpc}{$H+}
interface
function UniformLineEnding(const Text: RawByteString; out Ending: string): Boolean;
implementation
function UniformLineEnding(const Text: RawByteString; out Ending: string): Boolean;
var I: SizeInt; Found: string;
begin
  Ending := '';
  I := 1;
  while I <= Length(Text) do
  begin
    if Text[I] in [#10,#13] then
    begin
      Found := Text[I];
      if (Found = #13) and (I < Length(Text)) and (Text[I+1] = #10) then
      begin Found := #13#10; Inc(I); end;
      if Ending = '' then Ending := Found else if Ending <> Found then Exit(False);
    end;
    Inc(I);
  end;
  if Ending = '' then Ending := #10;
  Result := True;
end;
end.
