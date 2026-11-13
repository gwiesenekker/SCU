unit ScuExpandCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommand, ScuCommandHandler;

function SingleDeckDirectory(const Context: TCommandContext): string;
function BulkExpansionDirectory(const Context: TCommandContext): string;
function CheckpointDirectory(const Context: TCommandContext): string;
function PrepareBulkExpansion(const Context: TCommandContext): Boolean;
function ExtractDeck(var Context: TCommandContext): string;
function ExpandDeck(var Context: TCommandContext): string;
function ExtractModifiedDecks(var Context: TCommandContext): string;
function ExpandVersion(var Context: TCommandContext): string;
function DisplayExpansionCheckpoints(var Context: TCommandContext): string;
function ResetExpansionCheckpoint(var Context: TCommandContext): string;

implementation

uses
  ScuExportManifest, ScuLibraryDisplay, ScuTable, Classes, SysUtils, FPJSON, ScuCommands, ScuExpand, ScuErrors, ScuFiles, ScuLibrary,
  ScuLibraryPaths, ScuSignals, ScuTerminal, ScuSQLiteCheckpoint, ScuJSON, ScuVersions;

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
  if IsLibraryStoragePath(Result, Context.LibraryPath) then
    raise EScuError.Create('The output path would overwrite a library or audit file.');
  if ExtractFileName(Result) = ExportManifestName then
    raise EScuError.Create('The output path is reserved for the SCU export manifest.');
  RegularFileExists(Result);
end;

function SingleDeckDirectory(const Context: TCommandContext): string;
var
  Path: string;
begin
  Path := OutputFileArgument(Context.Command);
  if (Path = '') or SameText(Path, DeckNameSelector) or SameText(Path, LastModifiedDeckSelector) then
    Result := GetCurrentDir
  else
    Result := ExtractFileDir(ExpandFileName(Path));
end;

function BulkExpansionDirectory(const Context: TCommandContext): string;
begin
  Result := Context.Command['output_directory'];
  if SameText(Result, LibraryDirectorySelector) then
    Result := ExtractFileDir(CanonicalFile(Context.LibraryPath));
end;

function CheckpointDirectory(const Context: TCommandContext): string;
begin
  Result := Context.Command['output_directory'];
end;

function StoredVersionName(const Context: TCommandContext; const Selector: string): string;
var
  Metadata: TJSONObject;
  History: TVersionHistory;
  Last: Integer;
begin
  Result := Selector;
  if SameText(Selector, CurrentVersionSelector) or SameText(Selector, LatestVersionSelector) then
    Exit(Context.Database.Revisions.ReadCurrentVersion);
  if not SameText(Selector, PreviousVersionSelector) then
    Exit;
  Metadata := Context.Database.Revisions.ReadMetadata;
  History := nil;
  try
    History := TVersionHistory.Create(TJSONArray(Field(TJSONObject(Field(Metadata, 'header', jtObject)),
      'versions', jtArray)), Context.Database.Revisions.RevisionCount);
    if not History.TryPrevious(Result, Last) then
      raise EScuError.CreateFmt('No locked version precedes current version %s.', [History.Current]);
  finally
    History.Free;
    Metadata.Free;
  end;
end;

function PrepareBulkExpansion(const Context: TCommandContext): Boolean;
var
  Version: string;
begin
  Version := StoredVersionName(Context, Context.Command['version']);
  Result := Context.Database.Checkpoints.InvalidateExpansionOutput(Version, Context.OutputDirectory,
    PrefixArgument(Context.Command), SameText(Context.Command['version'], LatestVersionSelector));
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
    Context.Build.OutputPath := Target;
  end;
end;

function TransferDeck(var Context: TCommandContext; Expand: Boolean): string;
var
  Deck, Path, MissingDeckVersion, ResolvedDeckVersion: string;
  Bytes: RawByteString;
  Source: TDeckSource;
  Selection: TDeckSelection;
  Manifest: TExportManifest;
  Mode, ExpansionUTC: string;
  Expander: TDeckExpander;
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
  MissingDeckVersion := Selection.Snapshot.Version;
  Mode := 'extract';
  ExpansionUTC := '';
  Path := OutputFileArgument(Context.Command);
  if SameText(Path, DeckNameSelector + '.scu') then
    Path := DeckName(Deck) + '.scu'
  else if SameText(Path, DeckNameSelector) then
    Path := DeckName(Deck)
  else if SameText(Path, LastModifiedDeckSelector) then
    Path := ResolveLastModifiedDeck(Context.LibraryFile);
  Path := OutputPath(Context, Path);
  Context.Snapshots.OutputPath := Path;
  if Expand then
  begin
    Expander := TDeckExpander.Create(Context.LibraryFile, Context.Database, Context.Snapshots.Selected.LibraryRevision,
      Context.Snapshots.Selected.Version, PrefixArgument(Context.Command), MissingDeckVersion);
    try
      Bytes := Expander.Expand(Deck, Selection.RootRevision);
      ResolvedDeckVersion := Expander.RootDeckVersion;
      ExpansionUTC := Expander.ExpansionUTC;
      Mode := 'expand';
    finally
      Expander.Free;
    end;
  end
  else
  begin
    if Selection.RootRevision = 0 then
      Selection.RootRevision := Selection.Snapshot.LibraryRevision;
    Source := Context.LibraryFile.Extract(Context.Database, Deck, Selection.RootRevision, MissingDeckVersion);
    Bytes := Source.Bytes;
    ResolvedDeckVersion := Source.DeckVersion;
  end;
  CheckSessionInterrupt;
  Manifest := TExportManifest.Create(ExtractFileDir(Path));
  try
    Manifest.WriteExport(Context.LibraryPath, Path, Deck, Selection.Snapshot.Version,
      ResolvedDeckVersion, Mode, ExpansionUTC, PrefixArgument(Context.Command), Bytes);
  finally
    Manifest.Free;
  end;
  if Expand then
    ScheduleBuild(Context, Path);
  Context.Snapshots.DeckVersion := ResolvedDeckVersion;
  ReportSnapshot(Context, ResolvedDeckVersion, Deck);
  Result := '';
end;

function ExtractDeck(var Context: TCommandContext): string;
begin
  Result := TransferDeck(Context, False);
end;

function ExpandDeck(var Context: TCommandContext): string;
begin
  Result := TransferDeck(Context, True);
end;

function TransferModifiedDecks(var Context: TCommandContext; Expand: Boolean): string;
var
  LibraryFile: TDeckLibrary;
  Version, Directory, Prefix, Name: string;
  Revision, Base, CheckpointRevision, Index: Integer;
  Refresh, BuildPending, ChangesPending, FullSnapshot: Boolean;
  Snapshot: TLibrarySnapshot;
  Names, Destinations: TStringList;
  Expander: TDeckExpander;
  Manifest: TExportManifest;
  Mode, ExpansionUTC, ExportedVersion: string;
  Source: TDeckSource;
  Written: TDeckListEntries;
  Bytes: RawByteString;
begin
  LibraryFile := Context.LibraryFile;
  FullSnapshot := Expand and SameText(Context.Command['version'], LatestVersionSelector);
  if FullSnapshot then
    Snapshot := LibraryFile.CurrentSnapshot
  else
    Snapshot := LibraryFile.ParseLibrarySnapshot(Context.Command['version']);
  Version := Snapshot.Version;
  Directory := Context.OutputDirectory;
  LibraryFile.VersionBounds(Version, Base, Revision);
  if not DirectoryExists(Directory) then
    raise EScuError.CreateFmt('The output directory must already exist: "%s".', [Directory]);
  Directory := CanonicalDirectory(Directory);
  Context.Snapshots.OutputDirectory := Directory;
  Context.Snapshots.Selected.Version := Version;
  Context.Snapshots.Selected.LibraryRevision := Revision;
  BuildPending := False;
  if Expand and not FullSnapshot and Context.Database.Checkpoints.ReadExpansionCheckpoint(Version, Directory, CheckpointRevision,
    Refresh, BuildPending) then
  begin
    if (CheckpointRevision < Base) or (CheckpointRevision > Revision) then
      raise EScuError.Create('The expansion checkpoint is outside the selected version.');
    if Refresh then
      Base := 0
    else
      Base := CheckpointRevision;
  end;
  if FullSnapshot then
    Base := 0;
  Names := nil;
  Destinations := nil;
  Expander := nil;
  Manifest := nil;
  try
    Manifest := TExportManifest.Create(Directory);
    Names := TStringList.Create;
    Names.CaseSensitive := True;
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;
    LibraryFile.ChangedDecks(Base, Revision, Names);
    if Expand then
    begin
      Prefix := PrefixArgument(Context.Command);
      Expander := TDeckExpander.Create(LibraryFile, Context.Database, Revision, Version, Prefix);
      Expander.IncludeCopyDependents(Names);
    end;
    ChangesPending := Names.Count > 0;
    for Index := Names.Count - 1 downto 0 do
      if not LibraryFile.TryDeckSnapshot(Names[Index], Revision, Snapshot) then
        Names.Delete(Index);
    Destinations := TStringList.Create;
    for Name in Names do
      if Expand then
        Destinations.Add(OutputPath(Context, IncludeTrailingPathDelimiter(Directory) + Name))
      else
        Destinations.Add(OutputPath(Context, IncludeTrailingPathDelimiter(Directory) + Name + '.scu'));
    SetLength(Written, Names.Count);
    for Index := 0 to Names.Count - 1 do
    begin
      Mode := 'extract';
      ExpansionUTC := '';
      if Assigned(Expander) then
      begin
        Bytes := Expander.Expand(Names[Index]);
        ExportedVersion := Expander.RootDeckVersion;
        ExpansionUTC := Expander.ExpansionUTC;
        Mode := 'expand';
      end
      else
      begin
        Source := LibraryFile.Extract(Context.Database, Names[Index], Revision);
        Bytes := Source.Bytes;
        ExportedVersion := Source.DeckVersion;
      end;
      CheckSessionInterrupt;
      Manifest.WriteExport(Context.LibraryPath, Destinations[Index], Names[Index], Version,
        ExportedVersion, Mode, ExpansionUTC, PrefixArgument(Context.Command), Bytes);
      Written[Index].Name := Names[Index];
      Written[Index].DeckVersion := ExportedVersion;
    end;
    if Length(Written) > 0 then
      WriteDeckList(Written, Context.Output);
    if Expand and (ChangesPending or BuildPending) then
    begin
      ScheduleBuild(Context, Directory);
      if Context.Build.Command <> '' then
      begin
        Context.Build.Checkpoint := Context.Snapshots.Selected;
        Context.Build.CommentPrefix := Prefix;
      end
      else if ChangesPending and (LibraryFile.BuildCommand = '') then
        Context.Database.Checkpoints.SaveExpansionCheckpoint(Version, Directory, Prefix, Revision, True);
    end;
    Result := Format('Wrote %d deck(s) for version %s', [Names.Count, Version]);
  finally
    Manifest.Free;
    Expander.Free;
    Destinations.Free;
    Names.Free;
  end;
end;

function ExtractModifiedDecks(var Context: TCommandContext): string;
begin
  Result := TransferModifiedDecks(Context, False);
end;

function ExpandVersion(var Context: TCommandContext): string;
begin
  Result := TransferModifiedDecks(Context, True);
end;

function FormatExpansionCheckpoint(const Row: TExpansionCheckpoint): string;
var
  BuiltRevision, BuiltUTC, Status: string;
begin
  BuiltRevision := 'None';
  if Row.HasBuiltRevision then
    BuiltRevision := IntToStr(Row.BuiltRevision);
  BuiltUTC := 'None';
  if Row.HasBuildTime then
    BuiltUTC := Row.BuiltUTC;
  if Row.FullRebuildPending then
    Status := 'Full rebuild pending'
  else
    Status := 'Incremental';
  Result := Row.Version + #9 + StringToJSONString(Row.OutputDirectory) + #9 + BuiltRevision +
    #9 + Status + #9 + BuiltUTC + #9 + IntToStr(Row.Revision);
end;

function DisplayExpansionCheckpoints(var Context: TCommandContext): string;
var
  Rows: TExpansionCheckpoints;
  Row: TExpansionCheckpoint;
  Table: TScuTable;
begin
  Rows := Context.Database.Checkpoints.ReadExpansionCheckpoints;
  if Length(Rows) = 0 then
    Exit('No expansion checkpoints.');
  Table := TScuTable.Create(['Version', 'Output directory', 'Last built library revision',
    'Status', 'Last successful build (UTC)', 'Checkpoint library revision']);
  try
    for Row in Rows do
      Table.AddDelimitedRow(FormatExpansionCheckpoint(Row));
    Table.WriteTo(Context.Output, TerminalColumns(StdOutputHandle));
  finally
    Table.Free;
  end;
  Result := '';
end;

function ResetExpansionCheckpoint(var Context: TCommandContext): string;
var
  Version: string;
  Snapshot: TLibrarySnapshot;
begin
  Snapshot := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['version']);
  Context.Snapshots.Selected := Snapshot;
  Version := Snapshot.Version;
  if Context.Database.Checkpoints.ResetExpansionCheckpoint(Version, Context.OutputDirectory) then
    Result := Format('Reset expansion checkpoint for version %s in "%s".', [Version, Context.OutputDirectory])
  else
    Result := Format('No expansion checkpoint for version %s in "%s".', [Version, Context.OutputDirectory]);
end;

end.
