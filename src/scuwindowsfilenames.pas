unit ScuWindowsFileNames;
{$mode objfpc}{$H+}
interface
procedure ValidateWindowsUTF8(const Value, Context: RawByteString);
procedure ValidateWindowsFileName(const Name: RawByteString; const Kind: string);
procedure ValidateWindowsOutputPath(const Path: string);
procedure CheckWindowsOutputTarget(const Path: string);
implementation
uses Windows, SysUtils, Classes, ScuErrors, ScuPlatformPathsWindows;
function FinalPathName(Handle: THandle; Buffer: PWideChar; Capacity, Flags: DWORD): DWORD; stdcall;
  external 'kernel32.dll' name 'GetFinalPathNameByHandleW';
procedure ValidateWindowsUTF8(const Value, Context: RawByteString);
var Wide: UnicodeString; Index: SizeInt; Code: Word;
begin
  Wide := UTF8Decode(Value);
  if RawByteString(UTF8Encode(Wide)) <> Value then
    raise EScuError.Create('Invalid UTF-8 in Windows ' + Context + '.');
  Index := 1;
  while Index <= Length(Wide) do
  begin
    Code := Ord(Wide[Index]);
    if (Code >= $D800) and (Code <= $DBFF) then
    begin
      Inc(Index);
      if (Index > Length(Wide)) or ((Ord(Wide[Index]) < $DC00) or (Ord(Wide[Index]) > $DFFF)) then
        raise EScuError.Create('Invalid Unicode surrogate in Windows ' + Context + '.');
    end
    else if (Code >= $DC00) and (Code <= $DFFF) then
      raise EScuError.Create('Invalid Unicode surrogate in Windows ' + Context + '.');
    Inc(Index);
  end;
end;
procedure ValidateComponent(const Name: RawByteString; const Kind: string; ReserveControlNames: Boolean);
var Ch: AnsiChar; Base, Suffix, Lower: RawByteString; Wide: UnicodeString;
begin
  ValidateWindowsUTF8(Name, Kind + ' filename');
  if (Name = '') or (Name = '.') or (Name = '..') then
    raise EScuError.Create('Invalid Windows ' + Kind + ' filename: expected one nonempty file component.');
  for Ch in Name do
    if Ch in [#0..#31, '<', '>', ':', '"', '/', '\', '|', '?', '*'] then
      raise EScuError.Create('Invalid Windows ' + Kind + ' filename: forbidden character or directory component.');
  if (Name[1] = ' ') or (Name[Length(Name)] in [' ', '.']) then
    raise EScuError.Create('Windows ' + Kind + ' filenames cannot start with a space or end with a space or dot.');
  Wide := UTF8Decode(Name);
  if Length(Wide) > 255 then
    raise EScuError.Create('Windows ' + Kind + ' filename exceeds 255 UTF-16 code units.');
  Base := UpperCase(TrimRight(Copy(Name, 1, Pos('.', Name + '.') - 1)));
  Suffix := Copy(Base, 4, MaxInt);
  if (Base = 'CON') or (Base = 'PRN') or (Base = 'AUX') or (Base = 'NUL') or
    (Base = 'CONIN$') or (Base = 'CONOUT$') or
    (((Copy(Base, 1, 3) = 'COM') or (Copy(Base, 1, 3) = 'LPT')) and
      (((Length(Suffix) = 1) and (Suffix[1] in ['1'..'9'])) or
        (Suffix = '¹') or (Suffix = '²') or (Suffix = '³'))) then
    raise EScuError.Create('Windows ' + Kind + ' filename is a reserved device name.');
  Lower := LowerCase(Name);
  if ReserveControlNames and ((Lower = '.scu-exports.json') or (Lower = '.scu-output.lock') or
    (Lower = '.owner') or (Copy(Lower, 1, 9) = '.scu-tmp-') or
    (Copy(Lower, 1, 11) = '.scu-stage-')) then
    raise EScuError.Create('Windows ' + Kind + ' filename is reserved for SCU control files.');
end;
procedure ValidateWindowsFileName(const Name: RawByteString; const Kind: string);
begin ValidateComponent(Name, Kind, True); end;
procedure ValidateWindowsOutputPath(const Path: string);
var Value: string; Parts: TStringList; Ch: Char; Start, Index, Slash: Integer;
  Extended: Boolean;
begin
  ValidateWindowsUTF8(Path, 'output path');
  if Path = '' then raise EScuError.Create('Expected a Windows output filename.');
  for Ch in Path do if Ch in [#0..#31] then
    raise EScuError.Create('Invalid control character in Windows output path.');
  Value := StringReplace(Path, '/', '\', [rfReplaceAll]);
  Extended := Copy(Value, 1, 4) = '\\?\';
  if Extended then
  begin
    Delete(Value, 1, 4);
    if SameText(Copy(Value, 1, 4), 'UNC\') then Value := '\\' + Copy(Value, 5, MaxInt)
    else if (Length(Value) < 3) or not (Value[1] in ['a'..'z', 'A'..'Z']) or
      (Copy(Value, 2, 2) <> ':\') then
      raise EScuError.Create('Unsupported Windows output namespace. Use a DOS or UNC file path.');
  end;
  if (Copy(Value, 1, 4) = '\\.\') or (Copy(Value, 1, 4) = '\??\') then
    raise EScuError.Create('Windows device namespaces are not output file paths.');
  if Value[Length(Value)] = '\' then raise EScuError.Create('Expected a Windows output filename.');
  Start := 1;
  if Copy(Value, 1, 2) = '\\' then
  begin
    // Server/share are path roots, not DOS file components.
    Start := 3;
    for Index := 1 to 2 do
    begin
      Slash := Pos('\', Copy(Value, Start, MaxInt));
      if Slash <= 1 then raise EScuError.Create('Expected a UNC server, share and output filename.');
      Inc(Start, Slash);
    end;
  end
  else if (Length(Value) >= 2) and (Value[2] = ':') then
  begin
    if not (Value[1] in ['a'..'z', 'A'..'Z']) then
      raise EScuError.Create('Invalid Windows output drive.');
    Start := 3;
  end;
  Parts := TStringList.Create;
  try
    Value := Copy(Value, Start, MaxInt);
    ExtractStrings(['\'], [], PChar(Value), Parts);
    if Parts.Count = 0 then raise EScuError.Create('Expected a Windows output filename.');
    for Index := 0 to Parts.Count - 1 do
      if Index = Parts.Count - 1 then ValidateWindowsFileName(Parts[Index], 'export')
      else if (Parts[Index] <> '.') and (Parts[Index] <> '..') then
        ValidateComponent(Parts[Index], 'output directory', False);
  finally Parts.Free; end;
end;
function OpenExportTarget(const Path: string; out Info: TByHandleFileInformation): THandle;
var Handle: THandle; Error: DWORD;
begin
  Handle := CreateFileW(PWideChar(NativeFilePath(Path)), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    $00200000 {OPEN_REPARSE_POINT} or FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then
  begin
    Error := GetLastError;
    if Error in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND] then Exit(INVALID_HANDLE_VALUE);
    RaiseSystemError('Could not inspect export target "' + Path + '"', Error);
  end;
  try
    if not GetFileInformationByHandle(Handle, Info) then
      RaiseSystemError('Could not inspect export target "' + Path + '"', GetLastError);
    Result := Handle;
  except CloseHandle(Handle); raise; end;
end;
procedure CheckWindowsOutputTarget(const Path: string);
var Info: TByHandleFileInformation; Buffer: UnicodeString; Count, Capacity: DWORD; Handle: THandle;
begin
  ValidateWindowsOutputPath(Path);
  Handle := OpenExportTarget(Path, Info);
  if Handle = INVALID_HANDLE_VALUE then Exit;
  try
    if (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0 then
      raise EScuError.Create('Expected a regular export target without a reparse point: "' + Path + '".');
    Capacity := 256;
    repeat
      SetLength(Buffer, Capacity);
      Count := FinalPathName(Handle, PWideChar(Buffer), Capacity, 0);
      if Count = 0 then RaiseSystemError('Could not resolve export filename "' + Path + '"', GetLastError);
      if Count < Capacity then
      begin
        SetLength(Buffer, Count);
        if not PathsEqual(ExtractFileName(UTF8Encode(Buffer)), ExtractFileName(Path)) then
          raise EScuError.Create('Export target uses a short-name alias. Use its full filename: "' + Path + '".');
        Exit;
      end;
      Capacity := Count + 1;
    until Capacity > 32768;
    raise EScuError.Create('Export filename is too long.');
  finally CloseHandle(Handle); end;
end;
end.
