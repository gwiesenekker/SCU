unit ScuPlatformOutputWindows;
{$mode objfpc}{$H+}
interface
procedure WriteWindowsOutput(Handle: THandle; const Data: RawByteString);
implementation
uses Windows, SysUtils, ScuErrors;
procedure WriteWindowsOutput(Handle: THandle; const Data: RawByteString);
var Mode, Count, Amount: DWORD; Offset, Index, Used: SizeInt; Wide, Original: UnicodeString;
begin
  Offset := 0;
  if GetConsoleMode(Handle, Mode) then
  begin
    Original := UTF8Decode(Data); SetLength(Wide, Length(Original) * 2); Used := 0;
    for Index := 1 to Length(Original) do
    begin
      if (Original[Index] = #10) and ((Index = 1) or (Original[Index - 1] <> #13)) then
      begin Inc(Used); Wide[Used] := #13; end;
      Inc(Used); Wide[Used] := Original[Index];
    end;
    SetLength(Wide, Used);
    while Offset < Length(Wide) do
    begin
      Amount := Length(Wide) - Offset; if Amount > 16384 then Amount := 16384;
      if (Amount > 1) and (Ord(Wide[Offset + Amount]) >= $D800) and (Ord(Wide[Offset + Amount]) <= $DBFF) then Dec(Amount);
      if not WriteConsoleW(Handle, @Wide[Offset + 1], Amount, @Count, nil) then RaiseSystemError('Could not write command output', GetLastError);
      if Count = 0 then raise EScuError.Create('Could not write command output: no progress.');
      Inc(Offset, Count);
    end;
  end
  else
    while Offset < Length(Data) do
    begin
      Amount := Length(Data) - Offset; if Amount > 65536 then Amount := 65536;
      if not Windows.WriteFile(Handle, Data[Offset + 1], Amount, Count, nil) then RaiseSystemError('Could not write command output', GetLastError);
      if Count = 0 then raise EScuError.Create('Could not write command output: no progress.');
      Inc(Offset, Count);
    end;
end;
end.
