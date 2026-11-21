unit ScuLibraryCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function InitializeLibrary(var Context: TCommandContext): string;
function SaveRecoveredLibrary(var Context: TCommandContext): string;
function SaveLibrary(var Context: TCommandContext): string;
function DisplayLibrary(var Context: TCommandContext): string;
procedure ReportLibraryHeader(const Context: TCommandContext);
function ConfigureLibrary(var Context: TCommandContext): string;
function UnlockVersion(var Context: TCommandContext): string;
function LockVersion(var Context: TCommandContext): string;
function DeleteVersion(var Context: TCommandContext): string;
function CreateVersion(var Context: TCommandContext): string;
function DisplayVersion(var Context: TCommandContext): string;
function DisplayVersionHistory(var Context: TCommandContext): string;
function DisplayAuditTrail(var Context: TCommandContext): string;

implementation

uses
  ScuLibraryPortability, ScuImportManifest, ScuFiles, ScuCodec, ScuExportPaths, Classes, SysUtils, FPJSON, ScuAudit, ScuCommands, ScuErrors, ScuJSON, ScuLibrary, ScuOutput, ScuSignals, ScuVersions, ScuLibraryDisplay, ScuTable, ScuTerminal;

function InitializeLibrary(var Context: TCommandContext): string;
begin
  Context.LibraryFile.Save(Context.Database, Context.StagedSave);
  Result := 'Initialized version ' + Context.LibraryFile.CurrentVersion;
end;

function SaveRecoveredLibrary(var Context: TCommandContext): string;
begin
  Context.LibraryFile.Save(Context.Database, Context.StagedSave);
  Context.Snapshots.Selected := Context.LibraryFile.CurrentSnapshot;
  Result := Format('Restored %d revision(s) to "%s".', [Context.LibraryFile.Revision, Context.LibraryPath]);
end;

function SaveLibrary(var Context: TCommandContext): string;
begin
  if not Context.LibraryFile.Modified then
    Exit('Library is already saved.');
  Context.LibraryFile.Save(Context.Database, Context.StagedSave);
  Context.Snapshots.Selected := Context.LibraryFile.CurrentSnapshot;
  Result := 'Saved library.';
end;

function DisplayLibrary(var Context: TCommandContext): string;
begin
  Context.Snapshots.Selected := Context.LibraryFile.CurrentSnapshot;
  if BooleanArgument(Context.Command, 'json', 'no') then Exit('');
  Result := Format('Library "%s".', [Context.LibraryPath]);
end;

procedure ReportLibraryHeader(const Context: TCommandContext);
var
  Configuration: TJSONObject;
  Previous: TLibrarySnapshot;
  PreviousVersion, VersionStatus: string;
begin
  if BooleanArgument(Context.Command, 'json', 'no') then
  begin
    Context.Output.WriteLine(Context.LibraryFile.HeaderJSON(Context.Database));
    Exit;
  end;
  Configuration := Context.LibraryFile.CreateHeaderConfiguration;
  try
    PreviousVersion := 'none';
    if Context.LibraryFile.TryPreviousSnapshot(Previous) then
      PreviousVersion := Previous.Version;
    Configuration.Strings['previous_locked_version'] := PreviousVersion;
    if Context.LibraryFile.VersionHistory[Context.LibraryFile.VersionCount - 1].Locked then
      VersionStatus := 'locked'
    else
      VersionStatus := 'unlocked';
    Configuration.Strings['current_version'] := Format('%s (%s)', [Context.LibraryFile.CurrentVersion, VersionStatus]);
    WriteLibraryConfiguration(Configuration, Context.Output, Context.Output.Columns);
    ReportPlatformWarnings(Context, Configuration.Strings['platform']);
  finally
    Configuration.Free;
  end;
end;

function ConfigureLibrary(var Context: TCommandContext): string;
var
  Settings: TLibrarySettingsChange;
  Editor, Patterns: TJSONData;
  PatternList: TStringList;
  Index: Integer;
begin
  Settings.ChangePrefix := Context.Command.HasArgument('comment_prefix');
  Settings.ChangeBuild := Context.Command.HasArgument('build_command');
  Settings.ChangeReleaseDirectory := Context.Command.HasArgument('release_directory');
  Settings.ReleaseDirectory := Context.Command.Argument('release_directory');
  if Settings.ChangeReleaseDirectory then
    ResolveReleaseDirectory(Context.LibraryPath, Settings.ReleaseDirectory);
  Settings.VersionIncrement := Context.Command.Argument('version_increment');
  Settings.RevisionIncrement := Context.Command.Argument('revision_increment');
  if (Context.Command.HasArgument('version_increment') and (Settings.VersionIncrement = '')) or
    (Context.Command.HasArgument('revision_increment') and (Settings.RevisionIncrement = '')) then
    raise EScuError.Create('Expected a positive increment.');
  Editor := nil; Patterns := nil; PatternList := nil;
  try
    if Context.Command.HasArgument('file_patterns') then
    begin
      Patterns := ParseJSON(Context.Command['file_patterns'], 'Invalid JSON for file_patterns');
      if not (Patterns is TJSONArray) then raise EScuError.Create('file_patterns must be a JSON array of strings.');
      PatternList := TStringList.Create;
      for Index := 0 to TJSONArray(Patterns).Count - 1 do
      begin
        if Patterns.Items[Index].JSONType <> jtString then raise EScuError.Create('file_patterns must contain only strings.');
        PatternList.Add(TJSONArray(Patterns).Strings[Index]);
      end;
    end;
    if Context.Command.HasArgument('editor') then
    begin
      Editor := ParseJSON(Context.Command.Argument('editor'), 'Invalid JSON for --editor');
      if not (Editor is TJSONArray) then
        raise EScuError.Create('Invalid value for --editor: The editor must be a JSON array of strings.');
    end;
    if not Settings.ChangePrefix and not Settings.ChangeBuild and not Settings.ChangeReleaseDirectory and (Editor = nil) and
      (Settings.VersionIncrement = '') and (Settings.RevisionIncrement = '') and not Assigned(PatternList) then
      raise EScuError.Create('Specify at least one library setting.');
    Settings.Prefix := PrefixArgument(Context.Command);
    Settings.Editor := TJSONArray(Editor);
    Settings.BuildCommand := Context.Command.Argument('build_command');
    if Settings.ChangePrefix or Settings.ChangeBuild or Settings.ChangeReleaseDirectory or Assigned(Editor) or
      (Settings.VersionIncrement <> '') or (Settings.RevisionIncrement <> '') then
      Context.LibraryFile.Configure(Settings);
    if Assigned(PatternList) then Context.LibraryFile.SetFilePatterns(PatternList);
    Result := 'Updated library header';
  finally
    Editor.Free; Patterns.Free; PatternList.Free;
  end;
end;

function UnlockVersion(var Context: TCommandContext): string;
begin
  Context.LibraryFile.UnlockVersion;
  Result := 'Unlocked version ' + Context.LibraryFile.CurrentVersion;
end;

function LockVersion(var Context: TCommandContext): string;
var
  Path, Digest: string;
  Manifest: TJSONObject;
begin
  if (Context.Command.ExpectedVersion <> '') and
    (Context.Command.ExpectedVersion <> Context.LibraryFile.CurrentVersion) then
    raise EScuError.CreateFmt('Version changed from %s to %s while editing the lock description.',
      [Context.Command.ExpectedVersion, Context.LibraryFile.CurrentVersion]);
  Digest := '';
  Path := Context.Command.Argument('import_manifest_file');
  if Path <> '' then
  begin
    Manifest := ParseObject(ReadBytes(Path, MaxDeckSize), 'Import manifest "' + Path + '"');
    try
      Digest := StoreImportManifest(Context.Database, Context.LibraryFile.CurrentVersion, Manifest);
    finally
      Manifest.Free;
    end;
  end;
  Context.LibraryFile.LockVersion(Context.Command['description'], Digest);
  Result := 'Locked version ' + Context.LibraryFile.CurrentVersion;
end;

function DeleteVersion(var Context: TCommandContext): string;
var
  BeforeCount: Integer;
begin
  BeforeCount := Context.LibraryFile.Revision;
  Context.LibraryFile.DeleteVersion(Context.Command['version'],
    BooleanArgument(Context.Command, 'delete_revisions', 'no'));
  RemoveImportManifest(Context.Database, Context.Command['version']);
  Result := Format('Deleted version %s. Current version %s is locked.',
    [Context.Command['version'], Context.LibraryFile.CurrentVersion]);
  if BeforeCount > Context.LibraryFile.Revision then
    Result := Result + Format(' Removed %d deck revision(s).', [BeforeCount - Context.LibraryFile.Revision]);
end;

function CreateVersion(var Context: TCommandContext): string;
begin
  Context.LibraryFile.CreateVersion(Context.Command.Argument('version'));
  Result := 'Created version ' + Context.LibraryFile.CurrentVersion;
end;

function DisplayVersion(var Context: TCommandContext): string;
var
  Rows: TVersionDeckEntries;
begin
  Context.Snapshots.Selected := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['version']);
  Rows := Context.LibraryFile.VersionDecks(Context.Database, Context.Snapshots.Selected.Version);
  Context.Output.WriteLine(FormatTerminalLines(Format('Version "%s".', [Context.Snapshots.Selected.Version]),
    TerminalColumns(StdOutputHandle)));
  WriteVersionDecks(Rows, Context.Output);
  Result := '';
end;

function DisplayVersionHistory(var Context: TCommandContext): string;
var
  Index: Integer;
  Entry: TVersionEntry;
  Status, LockedUTC, Description, Mode, LimitText: string;
  FirstBreak, FirstVersion: Integer;
  Limit: Int64;
  Rows: TVersionHistoryDisplayRows;
begin
  LimitText := Context.Command.Argument('limit', '10');
  if not TryStrToInt64(LimitText, Limit) or (Limit < 0) then
    raise EScuError.Create('Expected a nonnegative integer for limit; use 0 for all versions.');
  Mode := Context.Command.Argument('display_description', 'short');
  if not (SameText(Mode, 'short') or SameText(Mode, 'full')) then
    raise EScuError.Create('Expected short or full for display_description.');
  FirstVersion := 0;
  if (Limit > 0) and (Limit < Context.LibraryFile.VersionCount) then
    FirstVersion := Context.LibraryFile.VersionCount - Integer(Limit);
  SetLength(Rows, Context.LibraryFile.VersionCount - FirstVersion);
  for Index := FirstVersion to Context.LibraryFile.VersionCount - 1 do
  begin
    Entry := Context.LibraryFile.VersionHistory[Index];
    if Entry.Locked then
      Status := 'locked'
    else
      Status := 'open';
    LockedUTC := Entry.LockedUTC;
    if LockedUTC = '' then
      LockedUTC := 'None';
    Description := Entry.Description;
    if SameText(Mode, 'short') then
    begin
      for FirstBreak := 1 to Length(Description) do
        if Description[FirstBreak] in [#10, #13] then
        begin
          SetLength(Description, FirstBreak - 1);
          Break;
        end;
      Description := StringToJSONString(Description);
    end;
    Rows[Index - FirstVersion].Version := Entry.Name;
    Rows[Index - FirstVersion].Status := Status;
    Rows[Index - FirstVersion].LockedUTC := LockedUTC;
    Rows[Index - FirstVersion].Description := Description;
  end;
  WriteVersionHistoryRows(Rows, Context.Output, SameText(Mode, 'full'));
  Result := '';
end;

type
  THistoryWriter = class
  public
    Table: TScuTable;
    destructor Destroy; override;
    procedure WriteLine(const Attempt, Outcome, BuildOutcome: RawByteString);
  end;

function HistoryStatus(const Outcome, BuildOutcome: RawByteString): string;
var
  Event: TJSONObject;
begin
  if Outcome = '' then
    Exit('interrupted');
  Event := ParseObject(Outcome, 'Audit history outcome');
  try
    if Event.Get('cancelled', False) then
      Exit('cancelled');
    if not Field(Event, 'success', jtBoolean).AsBoolean then
      Exit('failed');
    if Event.Get('pending_save', False) then
      Exit('pending save');
    Result := 'succeeded';
    if BuildOutcome <> '' then
    begin
      Event.Free;
      Event := nil;
      Event := ParseObject(BuildOutcome, 'Audit build outcome');
      if not Field(Event, 'success', jtBoolean, 'Audit build outcome').AsBoolean then
        Result := 'build failed';
    end;
  finally
    Event.Free;
  end;
end;

destructor THistoryWriter.Destroy;
begin
  Table.Free;
  inherited Destroy;
end;

procedure THistoryWriter.WriteLine(const Attempt, Outcome, BuildOutcome: RawByteString);
begin
  CheckSessionInterrupt;
  Table.AddRow([FormatAuditCommand(Attempt), HistoryStatus(Outcome, BuildOutcome)]);
end;

function DisplayAuditTrail(var Context: TCommandContext): string;
var
  Limit: Int64;
  Writer: THistoryWriter;
begin
  if not TryStrToInt64(Context.Command['number_of_lines'], Limit) or (Limit < 1) then
    raise EScuError.Create('Expected a positive number_of_lines.');
  Writer := THistoryWriter.Create;
  try
    Writer.Table := TScuTable.Create(['Command', 'Status']);
    Writer.Table.WrapWords := True;
    Context.Database.Audit.ReadCommandHistory(Limit, @Writer.WriteLine);
    Writer.Table.WriteTo(Context.Output, Context.Output.Columns);
  finally
    Writer.Free;
  end;
  Result := '';
end;

end.
