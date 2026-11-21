unit ScuReleaseFiles;
{$mode objfpc}{$H+}
interface
uses Classes;
function NewCleanupFileList: TStringList;
procedure CollectReleaseCleanupFiles(const Directory, LibraryPath: string;
  Patterns, Selected, Tracked, Names: TStrings);
implementation
uses SysUtils, ScuCleanupFiles, ScuDirectoryScan, ScuFiles, ScuLibraryPaths,
  ScuLockTypes, ScuLibraryNames, ScuPlatformPaths{$IFDEF WINDOWS}, ScuPlatformScanWindows{$ENDIF};
{$IFDEF WINDOWS}
type TCleanupFileList = class(TStringList)
  protected function DoCompareText(const Left, Right: string): PtrInt; override;
end;
function TCleanupFileList.DoCompareText(const Left, Right: string): PtrInt;
begin Result := CompareFileNames(Left, Right); end;
{$ENDIF}
function NewCleanupFileList: TStringList;
begin
  Result := {$IFDEF WINDOWS}TCleanupFileList{$ELSE}TStringList{$ENDIF}.Create;
  Result.CaseSensitive := True;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
end;
function MatchesPatterns(Patterns: TStrings; const Name: string): Boolean;
var Pattern: string;
begin
  for Pattern in Patterns do
    if MatchesFilePattern(Pattern, Name) then Exit(True);
  Result := False;
end;
function SelectedFile(Selected: TStrings; const Name: string): Boolean;
begin Result := Selected.IndexOf(Name) >= 0; end;
function ProtectedFile(const Path, Name, LibraryPath: string): Boolean;
begin
  Result := IsPlatformOutputLockName(Name) or SameStoragePath(Name, '.scu-exports.json') or
    IsLibraryStoragePath(Path, LibraryPath) or IsSQLiteFile(Path) or IsSQLiteCompanion(Path);
end;
procedure CollectCandidates(const Directory, LibraryPath: string;
  Patterns, Selected, Tracked, Names: TStrings);
var Scan: TReleaseDirectoryScan; Name, Path: string;
begin
  Scan := TReleaseDirectoryScan.Create(Directory);
  try
    while Scan.Next(Name) do
    begin
      if (Name = '.') or (Name = '..') or IsPlatformOutputLockName(Name) or
        SameStoragePath(Name, '.scu-exports.json') or SelectedFile(Selected, Name) or
        not MatchesPatterns(Patterns, Name) then Continue;
      Path := IncludeTrailingPathDelimiter(Directory) + Name;
      if not ReleaseFileEligible(Path, False) then Continue;
      if ProtectedFile(Path, Name, LibraryPath) then Continue;
      Names.Add(Name);
    end;
  finally Scan.Free; end;
  for Name in Tracked do
  begin
    if IsPlatformOutputLockName(Name) {$IFDEF WINDOWS}or SameStoragePath(Name, '.scu-exports.json'){$ENDIF} then Continue;
    {$IFDEF WINDOWS}ValidateSourceFileName(Name);{$ENDIF}
    if SelectedFile(Selected, Name) or not MatchesPatterns(Patterns, Name) then Continue;
    Path := IncludeTrailingPathDelimiter(Directory) + Name;
    if not ReleaseFileEligible(Path, True) then Continue;
    // Legacy Linux manifest candidates retain their original eligibility;
    // Windows also protects case aliases and foreign SQLite/control files.
    {$IFDEF WINDOWS}if ProtectedFile(Path, Name, LibraryPath) then Continue;{$ENDIF}
    Names.Add(Name);
  end;
end;
procedure CollectReleaseCleanupFiles(const Directory, LibraryPath: string;
  Patterns, Selected, Tracked, Names: TStrings);
{$IFDEF WINDOWS}
var Selection: TStringList; Pattern: string;
begin
  for Pattern in Patterns do ValidateFilePattern(Pattern);
  Selection := NewCleanupFileList;
  try
    Selection.Sorted := False;
    Selection.Assign(Selected);
    Selection.Sorted := True;
    CollectCandidates(Directory, LibraryPath, Patterns, Selection, Tracked, Names);
  finally Selection.Free; end;
end;
{$ELSE}
begin CollectCandidates(Directory, LibraryPath, Patterns, Selected, Tracked, Names); end;
{$ENDIF}
end.
