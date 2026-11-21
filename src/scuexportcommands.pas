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
  ScuArchiveCompatibility, ScuWorkingExports, FPJSON, ScuClock, ScuReleaseCleanup, ScuExportManifest, ScuExportPaths, ScuExportTypes, ScuDeckExport, ScuLibraryDisplay, ScuTable, Classes, SysUtils, ScuCommands, ScuErrors, ScuFiles, ScuLibrary,
  ScuLibraryPaths, ScuSignals, ScuVersions, ScuLockTypes, ScuExportNames, Contnrs, ScuPlatformPaths;

const
  LibraryDirectorySelector = 'scu$library_directory';
  DeckNameSelector = 'scu$deck_name';

function OutputFileArgument(Command: TScuCommand): string;
begin
  Result := Command.Argument('output_file');
end;

function OutputPath(const Context: TCommandContext; const Path: string): string;
begin
  ValidateExportPath(Path);
  CheckExportTarget(Path);
  Result := CanonicalFile(Path);
  CheckExportTarget(Result);
  if RegularFileExists(Result) and IsSQLiteFile(Result) then
    raise EScuError.Create('The output path would overwrite another SQLite library: "' + Result + '".');
  {$IFDEF WINDOWS}
  if IsSQLiteCompanion(Result) then
    raise EScuError.Create('The output path would overwrite SQLite companion storage.');
  {$ENDIF}
  if IsLibraryStoragePath(Result, Context.LibraryPath) then
    raise EScuError.Create('The output path would overwrite a library or audit file.');
  if IsPlatformOutputLockName(ExtractFileName(Result)) then
    raise EScuError.Create('The output path is reserved for the Windows output lock.');
  if SameExportLibrary(ExtractFileName(Result), ExportManifestName) then
    raise EScuError.Create('The output path is reserved for the SCU export manifest.');
  if (Context.Command.Name <> 'extract_deck') and
    (Context.Command.Name <> 'extract_version') and Assigned(Context.LibraryFile) and
    SameExportLibrary(ExtractFileDir(Result), ExtractFileDir(CanonicalFile(Context.LibraryPath))) then
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
  if not Context.Command.Provided['output_file'] then
    Exit(ExtractFileDir(CanonicalFile(Context.LibraryPath)));
  if (Path = '') or SameText(Path, DeckNameSelector) or SameText(Path, LastModifiedDeckSelector) then
    Result := GetCurrentDir
  else
  begin
    ValidateExportPath(Path);
    Result := ExtractFileDir(ExpandFileName(Path));
  end;
end;

function VersionOutputDirectory(const Context: TCommandContext): string;
begin
  Result := Context.Command['output_directory'];
  if SameText(Result, ExportDirectorySelector) then
    Exit(EnsureExportDirectory(Context.LibraryPath));
  if SameText(Result, LibraryDirectorySelector) then
    Result := ExtractFileDir(CanonicalFile(Context.LibraryPath));
  ValidateExportDirectory(Result);
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

procedure PlanTracker(const Context: TCommandContext; Manifest: TExportManifest; const Path: string);
var Version: string;
begin
  Version := Context.Snapshots.Selected.Version;
  Manifest.PlanExport(Context.LibraryPath, OutputPath(Context, Path), '', Version, '', emTracker,
    '', '', RenderTracker(Context.LibraryFile, Version), BooleanArgument(Context.Command, 'overwrite', 'no'));
end;

procedure ReportTracker(const Context: TCommandContext);
begin
  Context.Output.WriteLine(Context.LibraryFile.VersionTracker + ' has been expanded');
end;

function ExtractDeck(var Context: TCommandContext): string;
var
  Deck, Path, ResolvedDeckVersion: string;
  Tracker, TrackerPath: string;
  TrackerOnly: Boolean;
  Rows: TExportResults;
  Selection: TDeckSelection;
  Manifest: TExportManifest;
  Rendered: TRenderedDeck;
  Written: Boolean;
begin
  Tracker := Context.LibraryFile.VersionTracker;
  if (Tracker <> '') and (Context.LibraryFile.LastModifiedDeck = '') and
    SameText(Context.Command['deck_name'], LastModifiedDeckSelector) then Deck := Tracker
  else Deck := ResolveDeck(Context);
  TrackerOnly := (Tracker <> '') and SameStoragePath(Deck, Tracker);
  if Context.Command.HasArgument('revision') and (Context.Command.Argument('revision') = '') then
    raise EScuError.Create('Expected a deck revision from 0.000 to 0.999.');
  if Context.Command.HasArgument('version') and (Context.Command.Argument('version') = '') then
    raise EScuError.Create('Expected a library version.');
  Path := OutputFileArgument(Context.Command);
  if TrackerOnly then
  begin
    if Context.Command.HasArgument('revision') then
      raise EScuError.Create('A version tracker has no deck revision.');
    Context.Snapshots.Selected := ResolveSnapshot(Context);
    Rendered.FileName := Tracker;
  end
  else
  begin
    Selection := Context.LibraryFile.SelectDeck(Deck, Context.Command.Argument('version'),
      Context.Command.Argument('revision'));
    Context.Snapshots.Selected := Selection.Snapshot;
    Context.Snapshots.ResolvedDeck := Deck;
    if not Context.Command.Provided['output_file'] or SameText(Path, DeckNameSelector) or
      SameText(Path, LastModifiedDeckSelector) then RequireArchiveSourceNames(Context.LibraryFile, Context.Database);
    Rendered := RenderDeck(Context.LibraryFile, Context.Database, Deck, Selection, emExtract);
  end;
  if SameText(Path, DeckNameSelector + '.scu') then
    Path := DeckName(Deck) + '.scu'
  else if SameText(Path, DeckNameSelector) then
    Path := Rendered.FileName
  else if SameText(Path, LastModifiedDeckSelector) then
    Path := Context.LibraryFile.DeckSourcePath(Context.Database, ResolveLastModifiedDeck(Context.LibraryFile));
  if not Context.Command.Provided['output_file'] then
    Path := IncludeTrailingPathDelimiter(Context.OutputDirectory) + ExtractFileName(Path);
  Path := OutputPath(Context, Path);
  Context.Snapshots.OutputPath := Path;
  ResolvedDeckVersion := Rendered.DeckVersion;
  CheckSessionInterrupt;
  if SameExportLibrary(ExtractFileDir(Path), ExtractFileDir(CanonicalFile(Context.LibraryPath))) then
    RefreshWorkingExports(Context.Database, Context.LibraryPath);
  Manifest := TExportManifest.Create(ExtractFileDir(Path));
  try
    Manifest.Recover;
    if TrackerOnly then PlanTracker(Context, Manifest, Path)
    else
      Manifest.PlanExport(Context.LibraryPath, Path, Deck, Selection.Snapshot.Version, ResolvedDeckVersion,
        emExtract, '', '', Rendered.Bytes, BooleanArgument(Context.Command, 'overwrite', 'no'));
    if Tracker <> '' then
    begin
      TrackerPath := IncludeTrailingPathDelimiter(ExtractFileDir(Path)) + Tracker;
      if not TrackerOnly or not SameStoragePath(Path, TrackerPath) then
        PlanTracker(Context, Manifest, TrackerPath);
    end;
    Manifest.Publish(Rows);
    Written := (Length(Rows) > 0) and (Rows[0].Status <> esUnchanged);
    Context.FilesPublished := True;
  finally
    Manifest.Free;
  end;
  ScheduleBuild(Context, Path);
  if TrackerOnly then
  begin
    ReportTracker(Context);
    Exit('');
  end;
  Context.Snapshots.DeckVersion := ResolvedDeckVersion;
  ReportSnapshot(Context, ResolvedDeckVersion, Deck);
  if Tracker <> '' then ReportTracker(Context);
  if Written then
    Result := 'Wrote "' + StringToJSONString(Path) + '".'
  else
    Result := 'Unchanged: "' + StringToJSONString(Path) + '" already matches deck version ' +
      ResolvedDeckVersion + '.';
end;

{$IFDEF WINDOWS}
procedure PreflightVersionNames(const Context: TCommandContext; Names: TStrings;
  const Directory: string);
var Keys: TExportFileKeys; Seen: TFPHashList; Name, Key: string; Source: TDeckSource;
begin
  Keys := TExportFileKeys.Create;
  Seen := TFPHashList.Create;
  try
    for Name in Names do
    begin
      CheckSessionInterrupt;
      Source := Context.LibraryFile.ReadDeckMetadata(Context.Database, Name,
        Context.Snapshots.Selected.LibraryRevision, Context.Snapshots.Selected.Version);
      ValidateExportFileName(Source.SourcePath);
      Key := Keys.Key(Source.SourcePath);
      if Seen.Find(Key) <> nil then
        raise EScuError.Create('Several decks export to source filename "' + Source.SourcePath +
          '" (Windows case-insensitive collision). Choose unique source associations before exporting.');
      Seen.Add(Key, Pointer(1));
      OutputPath(Context, IncludeTrailingPathDelimiter(Directory) + Source.SourcePath);
    end;
  finally Seen.Free; Keys.Free; end;
end;
{$ENDIF}

function TransferVersion(var Context: TCommandContext; Mode: TExportMode): string;
var
  Version, Directory, ExpansionUTC: string;
  Revision, Base, Index, DeletedCount, WrittenCount, ConflictCount: Integer;
  Conflicts: TScuTable;
  Snapshot: TLibrarySnapshot;
  Selection: TDeckSelection;
  Names, FileNames, Removed, Preserved: TStringList;
  Manifest: TExportManifest;
  Rendered: TRenderedDeck;
  Expand: Boolean;
  Rows: TExportResults;
  LegacyCopy: Boolean;
begin
  Expand := Mode = emExpand;
  if SameText(Context.Command['version'], LatestVersionSelector) then
    Snapshot := Context.LibraryFile.CurrentSnapshot
  else Snapshot := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['version']);
  Version := Snapshot.Version;
  RequireArchiveSourceNames(Context.LibraryFile, Context.Database);
  Context.LibraryFile.VersionBounds(Version, Base, Revision);
  Directory := CanonicalDirectory(Context.OutputDirectory);
  if Expand and SameExportLibrary(Directory, ExtractFileDir(CanonicalFile(Context.LibraryPath))) then
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
  Conflicts := nil;
  ConflictCount := 0;
  try
    Names.Sorted := True;
    Names.CaseSensitive := True;
    Names.Duplicates := dupIgnore;
    Context.LibraryFile.ChangedDecks(0, Revision, Names);
    for Index := Names.Count - 1 downto 0 do
      if not Context.LibraryFile.TryDeckSnapshot(Names[Index], Revision, Snapshot) then
        Names.Delete(Index);
    {$IFDEF WINDOWS}PreflightVersionNames(Context, Names, Directory);{$ENDIF}
    if SameExportLibrary(Directory, ExtractFileDir(CanonicalFile(Context.LibraryPath))) then
      RefreshWorkingExports(Context.Database, Context.LibraryPath);
    Manifest := TExportManifest.Create(Directory);
    Manifest.Recover;
    ExpansionUTC := UtcTimestamp(UtcNow);
    LegacyCopy := False;
    for Index := 0 to Names.Count - 1 do
    begin
      Selection := Default(TDeckSelection);
      Selection.Snapshot := Context.Snapshots.Selected;
      Rendered := RenderDeck(Context.LibraryFile, Context.Database, Names[Index], Selection, Mode, ExpansionUTC);
      LegacyCopy := LegacyCopy or Rendered.LegacyCopy;
      if FileNames.IndexOf(Rendered.FileName) >= 0 then
        raise EScuError.Create('Several decks export to source filename "' + Rendered.FileName + '". Choose unique source associations before exporting.');
      FileNames.Add(Rendered.FileName);
      try
        Manifest.PlanExport(Context.LibraryPath, OutputPath(Context, IncludeTrailingPathDelimiter(Directory) + Rendered.FileName),
          Names[Index], Version, Rendered.DeckVersion, Mode, Rendered.ExpansionUTC, '', Rendered.Bytes,
          BooleanArgument(Context.Command, 'overwrite', 'no'));
      except
        on E: EExportOverwriteRequired do
        begin
          if Expand then raise;
          if not Assigned(Conflicts) then
            Conflicts := TScuTable.Create(['Deck name', 'Deck version', 'Status', 'Output file']);
          Conflicts.AddRow([Names[Index], Rendered.DeckVersion, E.Status, StringToJSONString(Rendered.FileName)]);
          Inc(ConflictCount);
        end;
      end;
    end;
    if Context.LibraryFile.VersionTracker <> '' then
    begin
      try
        PlanTracker(Context, Manifest, IncludeTrailingPathDelimiter(Directory) + Context.LibraryFile.VersionTracker);
        FileNames.Add(Context.LibraryFile.VersionTracker);
      except
        on E: EExportOverwriteRequired do
        begin
          if Expand then raise;
          if not Assigned(Conflicts) then
            Conflicts := TScuTable.Create(['Deck name', 'Deck version', 'Status', 'Output file']);
          Conflicts.AddRow(['(version tracker)', '', E.Status, Context.LibraryFile.VersionTracker]);
          Inc(ConflictCount);
        end;
      end;
    end;
    if Assigned(Conflicts) then
    begin
      Conflicts.WriteTo(Context.Output, Context.Output.Columns);
      raise EScuError.CreateFmt('%d output file(s) in "%s" require overwrite=yes. No decks were extracted.',
        [ConflictCount, StringToJSONString(Directory)]);
    end;
    DeletedCount := 0;
    if Expand then DeletedCount := PlanReleaseCleanup(Context, Directory, Version, FileNames, Manifest, Removed, Preserved);
    WrittenCount := Manifest.Publish(Rows);
    Context.FilesPublished := (Length(Rows) > 0) or (DeletedCount > 0) or (Context.LibraryFile.VersionTracker <> '');
    if Context.LibraryFile.VersionTracker <> '' then
      ReportTracker(Context);
    if LegacyCopy then Context.Output.Report('Warning: COPY is no longer expanded; COPY directives are released as literal source.');
    if Length(Rows) > 0 then WriteExportResults(Rows, Context.Output);
    for Index := 0 to Removed.Count - 1 do Context.Output.WriteLine('Removed obsolete release file "' + StringToJSONString(Removed[Index]) + '".');
    for Index := 0 to Preserved.Count - 1 do Context.Output.WriteLine('Kept untracked release file "' + StringToJSONString(Preserved[Index]) + '"; use overwrite=yes to remove it.');
    if not Expand then ScheduleBuild(Context, Directory);
    Result := Format('Wrote %d deck(s) for version %s', [WrittenCount, Version]);
    if WrittenCount < Names.Count then
      Result := Result + Format(', %d unchanged', [Names.Count - WrittenCount]);
    if DeletedCount > 0 then Result := Result + Format('; removed %d obsolete file(s).', [DeletedCount]);
  finally
    Conflicts.Free;
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
