unit ScuReleaseCleanup;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuCommandHandler, ScuExportManifest;

function PlanReleaseCleanup(const Context: TCommandContext; const Directory, Version: string;
  Selected: TStrings; Manifest: TExportManifest; Removed, Preserved: TStrings): Integer;
implementation

uses
  SysUtils, BaseUnix, ScuFiles, ScuFileScan, ScuLibraryPaths, ScuErrors, ScuSignals, ScuLockTypes;


function MatchesPatterns(const Context: TCommandContext; const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Context.LibraryFile.FilePatternCount - 1 do
    if MatchesFilePattern(Context.LibraryFile.FilePatterns[Index], Name) then Exit(True);
  Result := False;
end;

function PlanReleaseCleanup(const Context: TCommandContext; const Directory, Version: string;
  Selected: TStrings; Manifest: TExportManifest; Removed, Preserved: TStrings): Integer;
var
  Search: TSearchRec;
  Names: TStringList;
  Name, Path: string;
  Info: Stat;
  Index: Integer;
  Entry: TExportRecord;
begin
  Result := 0;
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    Names.CaseSensitive := True;
    Names.Duplicates := dupIgnore;
    if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*', faAnyFile, Search) = 0 then
    try
      repeat
        Name := Search.Name;
        if IsPlatformOutputLockName(Name) then Continue;
        if (Name = '.') or (Name = '..') or (Name = ExportManifestName) or
          (Selected.IndexOf(Name) >= 0) or not MatchesPatterns(Context, Name) then Continue;
        Path := IncludeTrailingPathDelimiter(Directory) + Name;
        if fpLStat(Path, Info) <> 0 then RaiseSystemError('Could not inspect release file "' + Path + '"', fpGetErrNo);
        // Cleanup never follows links, removes directories, or touches SQLite storage.
        if not FPS_ISREG(Info.st_mode) then Continue;
        if IsLibraryStoragePath(Path, Context.LibraryPath) or IsSQLiteFile(Path) or IsSQLiteCompanion(Path) then Continue;
        Names.Add(Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    // Remove obsolete manifest records even if the file was already removed.
    for Index := 0 to Manifest.Count - 1 do
    begin
      Entry := Manifest[Index];
      if IsPlatformOutputLockName(Entry.FileName) then Continue;
      if (Entry.LibraryPath = CanonicalFile(Context.LibraryPath)) and
        (Selected.IndexOf(Entry.FileName) < 0) and MatchesPatterns(Context, Entry.FileName) then
      begin
        Path := IncludeTrailingPathDelimiter(Directory) + Entry.FileName;
        if (fpLStat(Path, Info) = 0) and not FPS_ISREG(Info.st_mode) then Continue;
        Names.Add(Entry.FileName);
      end;
    end;
    for Name in Names do
    begin
      CheckSessionInterrupt;
      if not Manifest.TracksFile(Context.LibraryPath, Name) and
        not BooleanArgument(Context.Command, 'replace', 'no') then
      begin
        Preserved.Add(Name);
        Continue;
      end;
      Manifest.PlanDelete(Context.LibraryPath, IncludeTrailingPathDelimiter(Directory) + Name,
        Version, BooleanArgument(Context.Command, 'replace', 'no'));
      Removed.Add(Name);
      Inc(Result);
    end;
  finally
    Names.Free;
  end;
end;
end.
