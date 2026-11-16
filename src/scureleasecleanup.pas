unit ScuReleaseCleanup;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuCommandHandler, ScuExportManifest;

function PlanReleaseCleanup(const Context: TCommandContext; const Directory, Version: string;
  Selected: TStrings; Manifest: TExportManifest; Removed, Preserved: TStrings): Integer;
implementation

uses
  SysUtils, ScuFiles, ScuReleaseFiles, ScuSignals, ScuPlatformPaths;


function PlanReleaseCleanup(const Context: TCommandContext; const Directory, Version: string;
  Selected: TStrings; Manifest: TExportManifest; Removed, Preserved: TStrings): Integer;
var
  Names, Patterns, Tracked: TStringList;
  Name: string;
  Index: Integer;
  Entry: TExportRecord;
begin
  Result := 0;
  Names := NewCleanupFileList;
  Patterns := TStringList.Create;
  Tracked := TStringList.Create;
  try
    for Index := 0 to Context.LibraryFile.FilePatternCount - 1 do
      Patterns.Add(Context.LibraryFile.FilePatterns[Index]);
    for Index := 0 to Manifest.Count - 1 do
    begin
      Entry := Manifest[Index];
      if SameStoragePath(Entry.LibraryPath, CanonicalFile(Context.LibraryPath)) then
        Tracked.Add(Entry.FileName);
    end;
    CollectReleaseCleanupFiles(Directory, Context.LibraryPath, Patterns, Selected, Tracked, Names);
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
    Tracked.Free;
    Patterns.Free;
    Names.Free;
  end;
end;
end.
