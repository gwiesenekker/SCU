unit ScuExportCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommand, ScuCommandHandler;

function SingleDeckDirectory(const Context: TCommandContext): string;
function VersionOutputDirectory(const Context: TCommandContext): string;
function ExtractDeck(var Context: TCommandContext): string;
function ExtractVersion(var Context: TCommandContext): string;
function ReleaseVersion(var Context: TCommandContext): string;

implementation

uses
  ScuWorkingExports, FPJSON, ScuClock, ScuReleaseCleanup, ScuExportManifest, ScuExportPaths, ScuExportTypes, ScuDeckExport, ScuLibraryDisplay, ScuTable, Classes, SysUtils, ScuCommands, ScuErrors, ScuFiles, ScuLibrary,
  ScuLibraryPaths, ScuSignals, ScuVersions;

const
  LibraryDirectorySelector = 'scu$library_directory';
  DeckNameSelector = 'scu$deck_name';

function OutputFileArgument(Command: TScuCommand): string;
begin
  // Older command catalogs use output as the argument name.
  if not Command.HasArgument('output_file') and Command.HasArgument('output') then
    Exit(Command['output']);
  Result := Command.Argument('output_file');
end;

function OutputPath(const Context: TCommandContext; const Path: string): string;
begin
  Result := CanonicalFile(Path);
  if RegularFileExists(Result) and IsSQLiteFile(Result) then
    raise EScuError.Create('The output path would overwrite another SQLite library: "' + Result + '".');
  if IsLibraryStoragePath(Result, Context.LibraryPath) then
    raise EScuError.Create('The output path would overwrite a library or audit file.');
  if ExtractFileName(Result) = ExportManifestName then
    raise EScuError.Create('The output path is reserved for the SCU export manifest.');
  if (Context.Command.Name <> 'extract_deck') and
    (Context.Command.Name <> 'extract_version') and Assigned(Context.LibraryFile) and
    (ExtractFileDir(Result) = ExtractFileDir(CanonicalFile(Context.LibraryPath))) then
  begin
      if Context.LibraryFile.IsWorkingSourceFile(Context.Database, ExtractFileName(Result)) then
        raise EScuError.Create('The output path is a working source file: "' + Result + '". Select a separate output directory.');
  end;
end;

function SingleDeckDirectory(const Context: TCommandContext): string;
var
  Path: string;
begin
  Path := OutputFileArgument(Context.Command);
  if not Context.Command.Provided['output_file'] and not Context.Command.Provided['output'] then
    Exit(ExtractFileDir(CanonicalFile(Context.LibraryPath)));
  if (Path = '') or SameText(Path, DeckNameSelector) or SameText(Path, LastModifiedDeckSelector) then
    Result := GetCurrentDir
  else
    Result := ExtractFileDir(ExpandFileName(Path));
end;

function VersionOutputDirectory(const Context: TCommandContext): string;
begin
  Result := Context.Command['output_directory'];
  if SameText(Result, ExportDirectorySelector) then
    Exit(EnsureExportDirectory(Context.LibraryPath));
  if SameText(Result, LibraryDirectorySelector) then
    Result := ExtractFileDir(CanonicalFile(Context.LibraryPath));
end;

procedure ScheduleBuild(var Context: TCommandContext; const Target: string);
var
  Enabled: Boolean;
begin
  if not TryParseYesNo(Context.Command.Argument('build', 'no'), Enabled) then
    raise EScuError.Create('Expected yes/y or no/n for build.');
  if Enabled and (Context.LibraryFile.BuildCommand <> '') then
  begin
    Context.Build.Command := Context.LibraryFile.BuildCommand;
    Context.Build.LibraryPath := CanonicalFile(Context.LibraryPath);
    Context.Build.OutputPath := Target;
    Context.Build.WorkingDirectory := ExtractFileDir(CanonicalFile(Context.LibraryPath));
  end;
end;

function ExtractDeck(var Context: TCommandContext): string;
var
  Deck, Path, ResolvedDeckVersion: string;
  Bytes: RawByteString;
  Selection: TDeckSelection;
  Manifest: TExportManifest;
  Rendered: TRenderedDeck;
begin
  Deck := DeckName(ResolveDeck(Context));
  if Context.Command.HasArgument('revision') and (Context.Command.Argument('revision') = '') then
    raise EScuError.Create('Expected a deck revision from 0.000 to 0.999.');
  if Context.Command.HasArgument('version') and (Context.Command.Argument('version') = '') then
    raise EScuError.Create('Expected a library version.');
  Selection := Context.LibraryFile.SelectDeck(Deck, Context.Command.Argument('version'),
    Context.Command.Argument('revision'));
  Context.Snapshots.Selected := Selection.Snapshot;
  Context.Snapshots.ResolvedDeck := Deck;
  Rendered := RenderDeck(Context.LibraryFile, Context.Database, Deck, Selection, emExtract);
  Path := OutputFileArgument(Context.Command);
  if SameText(Path, DeckNameSelector + '.scu') then
    Path := DeckName(Deck) + '.scu'
  else if SameText(Path, DeckNameSelector) then
    Path := Rendered.FileName
  else if SameText(Path, LastModifiedDeckSelector) then
    Path := ResolveLastModifiedDeck(Context.LibraryFile);
  if not Context.Command.Provided['output_file'] and not Context.Command.Provided['output'] then
    Path := IncludeTrailingPathDelimiter(Context.OutputDirectory) + ExtractFileName(Path);
  Path := OutputPath(Context, Path);
  Context.Snapshots.OutputPath := Path;
  Bytes := Rendered.Bytes;
  ResolvedDeckVersion := Rendered.DeckVersion;
  CheckSessionInterrupt;
  if ExtractFileDir(Path) = ExtractFileDir(CanonicalFile(Context.LibraryPath)) then
    RefreshWorkingExports(Context.Database, Context.LibraryPath);
  Manifest := TExportManifest.Create(ExtractFileDir(Path));
  try
    Manifest.Recover;
    Manifest.WriteExport(Context.LibraryPath, Path, Deck, Selection.Snapshot.Version,
      ResolvedDeckVersion, emExtract, '', '', Bytes, BooleanArgument(Context.Command, 'replace', 'no'));
    Context.FilesPublished := True;
  finally
    Manifest.Free;
  end;
  ScheduleBuild(Context, Path);
  Context.Snapshots.DeckVersion := ResolvedDeckVersion;
  ReportSnapshot(Context, ResolvedDeckVersion, Deck);
  Result := '';
end;

function TransferVersion(var Context: TCommandContext; Mode: TExportMode): string;
var
  Version, Directory, ExpansionUTC: string;
  Revision, Base, Index, DeletedCount: Integer;
  Snapshot: TLibrarySnapshot;
  Selection: TDeckSelection;
  Names, FileNames, Removed, Preserved: TStringList;
  Manifest: TExportManifest;
  Rendered: TRenderedDeck;
  Expand: Boolean;
  Written: TDeckListEntries;
  LegacyCopy: Boolean;
begin
  Expand := Mode = emExpand;
  if SameText(Context.Command['version'], LatestVersionSelector) then
    Snapshot := Context.LibraryFile.CurrentSnapshot
  else Snapshot := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['version']);
  Version := Snapshot.Version;
  Context.LibraryFile.VersionBounds(Version, Base, Revision);
  Directory := CanonicalDirectory(Context.OutputDirectory);
  if Expand and (Directory = ExtractFileDir(CanonicalFile(Context.LibraryPath))) then
    raise EScuError.Create('Release output must be separate from the library working-source directory.');
  Context.Snapshots.OutputDirectory := Directory;
  Context.Snapshots.Selected := Snapshot;
  Names := TStringList.Create;
  FileNames := TStringList.Create;
  FileNames.Sorted := True;
  FileNames.CaseSensitive := True;
  Removed := TStringList.Create;
  Preserved := TStringList.Create;
  Manifest := nil;
  try
    Names.Sorted := True;
    Names.CaseSensitive := True;
    Names.Duplicates := dupIgnore;
    Context.LibraryFile.ChangedDecks(0, Revision, Names);
    for Index := Names.Count - 1 downto 0 do
      if not Context.LibraryFile.TryDeckSnapshot(Names[Index], Revision, Snapshot) then
        Names.Delete(Index);
    if Directory = ExtractFileDir(CanonicalFile(Context.LibraryPath)) then
      RefreshWorkingExports(Context.Database, Context.LibraryPath);
    Manifest := TExportManifest.Create(Directory);
    Manifest.Recover;
    ExpansionUTC := UtcTimestamp(UtcNow);
    LegacyCopy := False;
    SetLength(Written, Names.Count);
    for Index := 0 to Names.Count - 1 do
    begin
      Selection := Default(TDeckSelection);
      Selection.Snapshot := Context.Snapshots.Selected;
      Rendered := RenderDeck(Context.LibraryFile, Context.Database, Names[Index], Selection, Mode, ExpansionUTC);
      LegacyCopy := LegacyCopy or Rendered.LegacyCopy;
      if FileNames.IndexOf(Rendered.FileName) >= 0 then
        raise EScuError.Create('Several decks export to source filename "' + Rendered.FileName + '". Choose unique source associations before exporting.');
      FileNames.Add(Rendered.FileName);
      Manifest.PlanExport(Context.LibraryPath, OutputPath(Context, IncludeTrailingPathDelimiter(Directory) + Rendered.FileName),
        Names[Index], Version, Rendered.DeckVersion, Mode, Rendered.ExpansionUTC, '', Rendered.Bytes,
        BooleanArgument(Context.Command, 'replace', 'no'));
      Written[Index].Name := Names[Index];
      Written[Index].DeckVersion := Rendered.DeckVersion;
    end;
    DeletedCount := 0;
    if Expand then DeletedCount := PlanReleaseCleanup(Context, Directory, Version, FileNames, Manifest, Removed, Preserved);
    Manifest.Publish;
    Context.FilesPublished := (Names.Count > 0) or (DeletedCount > 0);
    if LegacyCopy then Context.Output.Report('Warning: COPY is no longer expanded; COPY directives are released as literal source.');
    if Names.Count > 0 then WriteDeckList(Written, Context.Output);
    for Index := 0 to Removed.Count - 1 do Context.Output.WriteLine('Removed obsolete release file "' + StringToJSONString(Removed[Index]) + '".');
    for Index := 0 to Preserved.Count - 1 do Context.Output.WriteLine('Kept untracked release file "' + StringToJSONString(Preserved[Index]) + '"; use replace=yes to remove it.');
    if not Expand then ScheduleBuild(Context, Directory);
    Result := Format('Wrote %d deck(s) for version %s', [Names.Count, Version]);
    if DeletedCount > 0 then Result := Result + Format('; removed %d obsolete file(s).', [DeletedCount]);
  finally
    Manifest.Free;
    Preserved.Free;
    Removed.Free;
    FileNames.Free;
    Names.Free;
  end;
end;

function ExtractVersion(var Context: TCommandContext): string;
begin
  Result := TransferVersion(Context, emExtract);
end;

function ReleaseVersion(var Context: TCommandContext): string;
begin
  Result := TransferVersion(Context, emExpand);
end;

end.
