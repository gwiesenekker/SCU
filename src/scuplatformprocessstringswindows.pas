unit ScuPlatformProcessStringsWindows;
{$mode objfpc}{$H+}
interface
uses Classes;
function QuoteWindowsArgument(const Value: string): UnicodeString;
function WindowsCommandLine(const Executable: string; Arguments: TStrings): UnicodeString;
function WindowsEnvironment(Overrides: TStrings): UnicodeString;
function WindowsEnvironmentValue(const Name: string): string;
function ResolveWindowsExecutable(const Name: string): string;
implementation
uses Windows, SysUtils, ScuErrors, ScuPlatformPathsWindows;
function CompareOrdinal(Left: PWideChar; LeftLength: Integer; Right: PWideChar;
  RightLength: Integer; IgnoreCase: BOOL): Integer; stdcall;
  external 'kernel32.dll' name 'CompareStringOrdinal';
function QuoteWindowsArgument(const Value: string): UnicodeString;
var Text: UnicodeString; Index, Slashes: Integer;
begin
  if Pos(#0, Value) <> 0 then raise EScuError.Create('NUL is not allowed in a child argument.');
  Text := UTF8Decode(Value);
  Result := '"'; Slashes := 0;
  for Index := 1 to Length(Text) do
    if Text[Index] = '\' then Inc(Slashes)
    else
    begin
      if Text[Index] = '"' then Result := Result + UnicodeString(StringOfChar('\', Slashes * 2 + 1))
      else Result := Result + UnicodeString(StringOfChar('\', Slashes));
      Result := Result + Text[Index]; Slashes := 0;
    end;
  Result := Result + UnicodeString(StringOfChar('\', Slashes * 2)) + '"';
end;
function WindowsCommandLine(const Executable: string; Arguments: TStrings): UnicodeString;
var Item: string;
begin
  Result := QuoteWindowsArgument(Executable);
  for Item in Arguments do Result := Result + ' ' + QuoteWindowsArgument(Item);
  if Length(Result) >= 32767 then raise EScuError.Create('Windows child command line exceeds 32766 characters.');
end;
function EntryName(const Value: string): string;
var Index: Integer;
begin
  Index := 1;
  if Copy(Value, 1, 1) = '=' then Inc(Index);
  while (Index <= Length(Value)) and (Value[Index] <> '=') do Inc(Index);
  if Index > Length(Value) then raise EScuError.Create('Expected child environment name=value.');
  Result := Copy(Value, 1, Index - 1);
end;
function SameName(const Left, Right: string): Boolean;
var A, B: UnicodeString;
begin
  A := UTF8Decode(Left); B := UTF8Decode(Right);
  Result := CompareOrdinal(PWideChar(A), Length(A), PWideChar(B), Length(B), True) = 2;
end;
function CompareEntries(List: TStringList; Left, Right: Integer): Integer;
var A, B: UnicodeString;
begin
  A := UTF8Decode(EntryName(List[Left])); B := UTF8Decode(EntryName(List[Right]));
  Result := CompareOrdinal(PWideChar(A), Length(A), PWideChar(B), Length(B), True);
  if Result = 0 then RaiseSystemError('Could not sort child environment', GetLastError);
  Dec(Result, 2);
end;
function WindowsEnvironment(Overrides: TStrings): UnicodeString;
var Entries: TStringList; Block, Cursor: PWideChar; Item, Key: string; Index, Found: Integer;
begin
  Entries := TStringList.Create;
  try
    Block := GetEnvironmentStringsW;
    if Block = nil then RaiseSystemError('Could not read parent environment', GetLastError);
    try
      Cursor := Block;
      while Cursor^ <> #0 do
      begin Entries.Add(UTF8Encode(UnicodeString(Cursor))); Inc(Cursor, Length(UnicodeString(Cursor)) + 1); end;
    finally FreeEnvironmentStringsW(Block); end;
    for Item in Overrides do
    begin
      if Pos(#0, Item) <> 0 then raise EScuError.Create('NUL is not allowed in a child environment entry.');
      Key := EntryName(Item); Found := -1;
      for Index := 0 to Entries.Count - 1 do
        if SameName(EntryName(Entries[Index]), Key) then begin Found := Index; Break; end;
      if Found >= 0 then Entries[Found] := Item else Entries.Add(Item);
    end;
    Entries.CustomSort(@CompareEntries);
    Result := '';
    for Item in Entries do Result := Result + UTF8Decode(Item) + #0;
    if Result = '' then Result := #0;
    Result := Result + #0;
  finally Entries.Free; end;
end;
function WindowsEnvironmentValue(const Name: string): string;
var Buffer, WideName: UnicodeString; Size, Count: DWORD;
begin
  WideName := UTF8Decode(Name); Size := 256;
  repeat
    SetLength(Buffer, Size);
    Count := GetEnvironmentVariableW(PWideChar(WideName), PWideChar(Buffer), Size);
    if Count = 0 then Exit('');
    if Count < Size then begin SetLength(Buffer, Count); Exit(UTF8Encode(Buffer)); end;
    Size := Count + 1;
  until Size > 32768;
  raise EScuError.Create('Child environment value is too long: ' + Name);
end;
function ResolveWindowsExecutable(const Name: string): string;
var Buffer, WideName: UnicodeString; Count: DWORD;
begin
  if (Name = '') or (Pos(#0, Name) <> 0) then raise EScuError.Create('Expected a child executable name.');
  WideName := UTF8Decode(Name); SetLength(Buffer, 32768);
  Count := SearchPathW(nil, PWideChar(WideName), '.exe', Length(Buffer), PWideChar(Buffer), nil);
  if (Count = 0) or (Count >= DWORD(Length(Buffer))) then
    RaiseSystemError('Could not find executable "' + Name + '"', GetLastError);
  SetLength(Buffer, Count); Result := UTF8Encode(Buffer);
end;
end.
