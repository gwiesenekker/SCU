unit ScuLibraryNames;

{$mode objfpc}{$H+}

interface

const MaxDeckRevision = 999;

function DeckName(const Name: string): string;
procedure ValidateRelativeSourcePath(const Pattern: string);
procedure ValidateSourceFileName(const Name: string);
procedure ValidateFilePattern(const Pattern: string);

implementation

uses Classes, SysUtils, ScuErrors, ScuLockTypes, ScuPlatformPaths{$IFDEF WINDOWS}, ScuWindowsFileNames{$ENDIF};

function DeckName(const Name: string): string;
var
  Index: Integer;
begin
  if (Name = '') or (Length(Name) > 128) or
    not (Name[1] in ['a'..'z', 'A'..'Z', '0'..'9']) then
    raise EScuError.CreateFmt('Invalid deck name "%s".', [Name]);
  for Index := 2 to Length(Name) do
    if not (Name[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.']) then
      raise EScuError.CreateFmt('Invalid deck name "%s".', [Name]);
  Result := LowerCase(Name);
end;

procedure ValidateRelativeSourcePath(const Pattern: string);
var
  Parts: TStringList;
  Part: string;
begin
  if (Trim(Pattern) = '') or (Pos(#0, Pattern) > 0) or
    (Pos(#10, Pattern) > 0) or (Pos(#13, Pattern) > 0) then
    raise EScuError.Create('A file pattern must be a nonempty single line without NUL bytes.');
  if (Pattern[1] in ['/', '\']) or ((Length(Pattern) > 1) and (Pattern[2] = ':')) then
    raise EScuError.Create('File patterns must be relative to the library directory.');
  Parts := TStringList.Create;
  try
    ExtractStrings(['/', '\'], [], PChar(Pattern), Parts);
    for Part in Parts do
      if Part = '..' then
        raise EScuError.Create('File patterns cannot contain parent-directory (..) components.');
  finally
    Parts.Free;
  end;
end;

procedure ValidateSourceFileName(const Name: string);
begin
  {$IFDEF WINDOWS}ValidateWindowsFileName(Name, 'source');{$ENDIF}
  // POSIX filenames are bytes. Backslash, colon and newline are ordinary bytes.
  if (Name = '') or (Name = '.') or (Name = '..') or
    (Pos('/', Name) > 0) or (Pos(#0, Name) > 0) then
    raise EScuError.CreateFmt('Invalid source filename "%s": expected a nonempty filename without a directory component or NUL.',
      [StringReplace(StringReplace(Name, #10, '\n', [rfReplaceAll]), #13, '\r', [rfReplaceAll])]);
  if IsPlatformOutputLockName(Name) then
    raise EScuError.Create('Source filename is reserved for the Windows output lock: "' + Name + '".');
  if SameStoragePath(Name, '.scu-exports.json') then
    raise EScuError.CreateFmt('Source filename "%s" is reserved for the export manifest.', [Name]);
end;

procedure ValidateFilePattern(const Pattern: string);
begin
  ValidateRelativeSourcePath(Pattern);
  if (Pos('/', Pattern) > 0) or (Pos('\', Pattern) > 0) then
    raise EScuError.Create('File patterns must select files directly in the library directory; subdirectories are not supported yet.');
end;

end.
