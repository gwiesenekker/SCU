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
function ExpandModifiedDecks(var Context: TCommandContext): string;
function DisplayExpansionCheckpoints(var Context: TCommandContext): string;
function ResetExpansionCheckpoint(var Context: TCommandContext): string;

implementation

uses
  Classes, SysUtils, FPJSON, ScuCommands, ScuExpand, ScuErrors, ScuFiles, ScuLibrary, ScuSignals, ScuSQLiteCheckpoint;

const
  CurrentLibraryVersionSelector = 'scu$current_library_version';
  LibraryDirectorySelector = 'scu$library_directory';
  DeckNameSelector = 'scu$deck_name';

function OutputFileArgument(Command: TScuCommand): string;
begin
  // Older command catalogs use output as the argument name.
  if not Command.HasArgument('output_file') and Command.HasArgument('output') then
    Exit(Command['output']);
  Result := Command['output_file'];
end;

function OutputPath(const Context: TCommandContext; const Path: string): string;
begin
  Result := CanonicalFile(Path);
  if (Result = Context.LibraryPath) or (Result = Context.LibraryPath + '.lock') or
    (Result = Context.LibraryPath + '-journal') or
    (Result = Context.LibraryPath + '-wal') or (Result = Context.LibraryPath + '-shm') then
    raise EScuError.Create('The output path would overwrite a library or audit file.');
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

function PrepareBulkExpansion(const Context: TCommandContext): Boolean;
var
  Version: string;
begin
  Version := Context.Command['version'];
  if SameText(Version, CurrentLibraryVersionSelector) then
    Version := Context.Database.Revisions.ReadCurrentVersion;
  Result := Context.Database.Checkpoints.InvalidateExpansionOutput(Version, Context.OutputDirectory,
    PrefixOption(Context.Command));
end;

procedure ScheduleBuild(var Context: TCommandContext; const Target: string);
var
  Enabled: Boolean;
begin
  if not TryParseYesNo(Context.Command.Option('build', 'no'), Enabled) then
    raise EScuError.Create('Expected yes/y or no/n for build.');
  if Enabled and (Context.LibraryFile.BuildCommand <> '') then
  begin
    Context.Build.Command := Context.LibraryFile.BuildCommand;
    Context.Build.OutputPath := Target;
  end;
end;

function TransferDeck(var Context: TCommandContext; Expand: Boolean): string;
var
  Deck, Path, MissingDeckVersion: string;
  Bytes: RawByteString;
  Source: TDeckSource;
  Expander: TDeckExpander;
begin
  Deck := ResolveDeck(Context);
  Context.Snapshots.Selected := ResolveSnapshot(Context, Deck, True);
  MissingDeckVersion := '';
  if not Context.Command.HasOption('revision') then
    MissingDeckVersion := Context.Snapshots.Selected.Version;
  Path := OutputFileArgument(Context.Command);
  if SameText(Path, DeckNameSelector) then
    Path := DeckName(Deck)
  else if SameText(Path, LastModifiedDeckSelector) then
    Path := ResolveLastModifiedDeck(Context.LibraryFile);
  Path := OutputPath(Context, Path);
  if Expand then
  begin
    Expander := TDeckExpander.Create(Context.LibraryFile, Context.Database, Context.Snapshots.Selected.LibraryRevision,
      Context.Snapshots.Selected.Version, PrefixOption(Context.Command), MissingDeckVersion);
    try
      Bytes := Expander.Expand(Deck);
    finally
      Expander.Free;
    end;
  end
  else
  begin
    Source := Context.LibraryFile.Extract(Context.Database, Deck, Context.Snapshots.Selected.LibraryRevision, MissingDeckVersion);
    Bytes := Source.Bytes;
  end;
  CheckSessionInterrupt;
  AtomicWrite(Path, Bytes, True, True);
  if Expand then
    ScheduleBuild(Context, Path);
  ReportSnapshot(Context);
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
  Refresh, BuildPending: Boolean;
  Names, Destinations: TStringList;
  Expander: TDeckExpander;
  Source: TDeckSource;
  Bytes: RawByteString;
begin
  LibraryFile := Context.LibraryFile;
  Version := Context.Command['version'];
  if Expand then
  begin
    if SameText(Version, CurrentLibraryVersionSelector) then
      Version := LibraryFile.CurrentVersion;
    Directory := Context.OutputDirectory;
    if LibraryFile.Modified then
      raise EScuError.Create('Save the SQLite library before running expand_modified_decks.');
  end
  else
    Directory := Context.Command['output_directory'];
  LibraryFile.VersionBounds(Version, Base, Revision);
  if not DirectoryExists(Directory) then
    raise EScuError.Create('The output directory must already exist.');
  Context.Snapshots.Selected.Version := Version;
  Context.Snapshots.Selected.LibraryRevision := Revision;
  BuildPending := False;
  if Expand and Context.Database.Checkpoints.ReadExpansionCheckpoint(Version, Directory, CheckpointRevision,
    Refresh, BuildPending) then
  begin
    if (CheckpointRevision < Base) or (CheckpointRevision > Revision) then
      raise EScuError.Create('The expansion checkpoint is outside the selected version.');
    if Refresh then
      Base := 0
    else
      Base := CheckpointRevision;
  end;
  Names := nil;
  Destinations := nil;
  Expander := nil;
  try
    Names := TStringList.Create;
    Names.CaseSensitive := True;
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;
    LibraryFile.ChangedDecks(Base, Revision, Names);
    if Expand then
    begin
      Prefix := PrefixOption(Context.Command);
      Expander := TDeckExpander.Create(LibraryFile, Context.Database, Revision, Version, Prefix);
      Expander.IncludeCopyDependents(Names);
    end;
    Destinations := TStringList.Create;
    for Name in Names do
      Destinations.Add(OutputPath(Context, IncludeTrailingPathDelimiter(Directory) + Name));
    for Index := 0 to Names.Count - 1 do
    begin
      if Assigned(Expander) then
        Bytes := Expander.Expand(Names[Index])
      else
      begin
        Source := LibraryFile.Extract(Context.Database, Names[Index], Revision);
        Bytes := Source.Bytes;
      end;
      CheckSessionInterrupt;
      AtomicWrite(Destinations[Index], Bytes, True, True);
    end;
    if Expand and ((Names.Count > 0) or BuildPending) then
    begin
      ScheduleBuild(Context, Directory);
      if Context.Build.Command <> '' then
      begin
        Context.Build.Checkpoint := Context.Snapshots.Selected;
        Context.Build.CommentPrefix := Prefix;
      end
      else if (Names.Count > 0) and (LibraryFile.BuildCommand = '') then
        Context.Database.Checkpoints.SaveExpansionCheckpoint(Version, Directory, Prefix, Revision, True);
    end;
    Result := Format('Wrote %d deck(s) for version %s', [Names.Count, Version]);
  finally
    Expander.Free;
    Destinations.Free;
    Names.Free;
  end;
end;

function ExtractModifiedDecks(var Context: TCommandContext): string;
begin
  Result := TransferModifiedDecks(Context, False);
end;

function ExpandModifiedDecks(var Context: TCommandContext): string;
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
begin
  Rows := Context.Database.Checkpoints.ReadExpansionCheckpoints;
  if Length(Rows) = 0 then
    Exit('No expansion checkpoints.');
  Context.Output.WriteLine('Version'#9'Output directory'#9'Last built library revision'#9'Status'#9 +
    'Last successful build (UTC)'#9'Checkpoint library revision');
  for Row in Rows do
    Context.Output.WriteLine(FormatExpansionCheckpoint(Row));
  Result := '';
end;

function ResetExpansionCheckpoint(var Context: TCommandContext): string;
var
  Version: string;
  Base, Revision: Integer;
begin
  Version := Context.Command['version'];
  Context.LibraryFile.VersionBounds(Version, Base, Revision);
  if Context.Database.Checkpoints.ResetExpansionCheckpoint(Version, Context.OutputDirectory) then
    Result := Format('Reset expansion checkpoint for version %s in "%s".', [Version, Context.OutputDirectory])
  else
    Result := Format('No expansion checkpoint for version %s in "%s".', [Version, Context.OutputDirectory]);
end;

end.
