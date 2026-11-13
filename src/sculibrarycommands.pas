unit ScuLibraryCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function InitializeLibrary(var Context: TCommandContext): string;
function SaveRecoveredLibrary(var Context: TCommandContext): string;
function SaveLibrary(var Context: TCommandContext): string;
function DisplayLibrary(var Context: TCommandContext): string;
function ShowLibrary(var Context: TCommandContext): string;
procedure ReportLibraryHeader(const Context: TCommandContext);
function ConfigureLibrary(var Context: TCommandContext): string;
function LockVersion(var Context: TCommandContext): string;
function CreateVersion(var Context: TCommandContext): string;
function DisplayVersion(var Context: TCommandContext): string;
function DisplayVersionHistory(var Context: TCommandContext): string;
function ListVersions(var Context: TCommandContext): string;
function ShowHistory(var Context: TCommandContext): string;

implementation

uses
  Classes, SysUtils, FPJSON, ScuAudit, ScuCommands, ScuErrors, ScuJSON, ScuLibrary, ScuOutput, ScuSignals, ScuVersions, ScuLibraryDisplay, ScuTable, ScuTerminal;

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
  Result := Format('Library "%s".', [Context.LibraryPath]);
end;

procedure ReportLibraryHeader(const Context: TCommandContext);
var
  Configuration: TJSONObject;
  Previous: TLibrarySnapshot;
  PreviousVersion: string;
begin
  Configuration := Context.LibraryFile.CreateHeaderConfiguration;
  try
    PreviousVersion := 'none';
    if Context.LibraryFile.TryPreviousSnapshot(Previous) then
      PreviousVersion := Previous.Version;
    Configuration.Strings['previous_locked_version'] := PreviousVersion;
    WriteLibraryConfiguration(Configuration, Context.Output, TerminalColumns(StdOutputHandle));
  finally
    Configuration.Free;
  end;
end;

function ShowLibrary(var Context: TCommandContext): string;
begin
  Context.Output.WriteLine(Context.LibraryFile.HeaderJSON);
  Result := '';
end;

function ConfigureLibrary(var Context: TCommandContext): string;
var
  Settings: TLibrarySettingsChange;
  Editor: TJSONData;
begin
  Settings.ChangePrefix := Context.Command.HasArgument('comment-prefix');
  Settings.ChangeBuild := Context.Command.HasArgument('build_command');
  Settings.VersionIncrement := Context.Command.Argument('version_increment');
  Settings.RevisionIncrement := Context.Command.Argument('revision_increment');
  if (Context.Command.HasArgument('version_increment') and (Settings.VersionIncrement = '')) or
    (Context.Command.HasArgument('revision_increment') and (Settings.RevisionIncrement = '')) then
    raise EScuError.Create('Expected a positive increment.');
  Editor := nil;
  try
    if Context.Command.HasArgument('editor') then
    begin
      Editor := ParseJSON(Context.Command.Argument('editor'), 'Invalid JSON for --editor');
      if not (Editor is TJSONArray) then
        raise EScuError.Create('Invalid value for --editor: The editor must be a JSON array of strings.');
    end;
    if not Settings.ChangePrefix and not Settings.ChangeBuild and (Editor = nil) and
      (Settings.VersionIncrement = '') and (Settings.RevisionIncrement = '') then
      raise EScuError.Create('Specify at least one library setting.');
    Settings.Prefix := PrefixArgument(Context.Command);
    Settings.Editor := TJSONArray(Editor);
    Settings.BuildCommand := Context.Command.Argument('build_command');
    Context.LibraryFile.Configure(Settings);
    Result := 'Updated library header';
  finally
    Editor.Free;
  end;
end;

function LockVersion(var Context: TCommandContext): string;
begin
  Context.LibraryFile.LockVersion(Context.Command['description']);
  Result := 'Locked version ' + Context.LibraryFile.CurrentVersion;
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
    end;
    Description := StringToJSONString(Description);
    Rows[Index - FirstVersion].Version := Entry.Name;
    Rows[Index - FirstVersion].Status := Status;
    Rows[Index - FirstVersion].LockedUTC := LockedUTC;
    Rows[Index - FirstVersion].Description := Description;
  end;
  WriteVersionHistoryRows(Rows, Context.Output);
  Result := '';
end;

function ListVersions(var Context: TCommandContext): string;
var
  Rows: TStringList;
  Row: string;
  Table: TScuTable;
begin
  Rows := TStringList.Create;
  Table := nil;
  try
    Table := TScuTable.Create(['Version', 'Status']);
    Context.LibraryFile.ListVersions(Rows);
    for Row in Rows do
      Table.AddDelimitedRow(Row);
    Table.WriteTo(Context.Output, TerminalColumns(StdOutputHandle));
  finally
    Table.Free;
    Rows.Free;
  end;
  Result := '';
end;

type
  THistoryWriter = class
  public
    Table: TScuTable;
    destructor Destroy; override;
    procedure WriteLine(const Attempt, Outcome: RawByteString);
  end;

function HistoryStatus(const Outcome: RawByteString): string;
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
  finally
    Event.Free;
  end;
end;

destructor THistoryWriter.Destroy;
begin
  Table.Free;
  inherited Destroy;
end;

procedure THistoryWriter.WriteLine(const Attempt, Outcome: RawByteString);
begin
  CheckSessionInterrupt;
  Table.AddRow([FormatAuditCommand(Attempt), HistoryStatus(Outcome)]);
end;

function ShowHistory(var Context: TCommandContext): string;
var
  Limit: Int64;
  Writer: THistoryWriter;
begin
  if not TryStrToInt64(Context.Command['number_of_lines'], Limit) or (Limit < 1) then
    raise EScuError.Create('Expected a positive number_of_lines.');
  Writer := THistoryWriter.Create;
  try
    Writer.Table := TScuTable.Create(['Command', 'Status']);
    Context.Database.Audit.ReadCommandHistory(Limit, @Writer.WriteLine);
    Writer.Table.WriteTo(Context.Output, TerminalColumns(StdOutputHandle));
  finally
    Writer.Free;
  end;
  Result := '';
end;

end.
