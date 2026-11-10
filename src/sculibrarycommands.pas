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
function StartVersion(var Context: TCommandContext): string;
function ListVersions(var Context: TCommandContext): string;
function ShowHistory(var Context: TCommandContext): string;

implementation

uses
  Classes, SysUtils, FPJSON, ScuAudit, ScuCommands, ScuErrors, ScuJSON, ScuLibrary, ScuOutput, ScuSignals;

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
var
  SaveRequested: Boolean;
begin
  SaveRequested := True;
  if Context.Command.SessionExit and Context.Command.HasArgument('save_library') and
    not TryParseYesNo(Context.Command['save_library'], SaveRequested) then
    raise EScuError.Create('Expected yes/y or no/n for save_library.');
  if not SaveRequested then
    Exit('Discarded unsaved library changes.');
  if not Context.LibraryFile.Modified then
    Exit('No unsaved library changes.');
  Context.LibraryFile.Save(Context.Database, Context.StagedSave);
  Context.Snapshots.Selected := Context.LibraryFile.CurrentSnapshot;
  Result := 'Saved library.';
end;

function DisplayLibrary(var Context: TCommandContext): string;
var
  Previous: TLibrarySnapshot;
  Version: string;
begin
  Context.Snapshots.Selected := Context.LibraryFile.CurrentSnapshot;
  Version := 'none';
  if Context.LibraryFile.TryPreviousSnapshot(Previous) then
    Version := Previous.Version;
  Result := Format('Library "%s", current version %s, previous locked version %s.',
    [Context.LibraryPath, Context.Snapshots.Selected.Version, Version]);
end;

procedure ReportLibraryHeader(const Context: TCommandContext);
begin
  Context.Output.WriteLine(Context.LibraryFile.HeaderJSON);
end;

function ShowLibrary(var Context: TCommandContext): string;
begin
  ReportLibraryHeader(Context);
  Result := '';
end;

function ConfigureLibrary(var Context: TCommandContext): string;
var
  Settings: TLibrarySettingsChange;
  Editor: TJSONData;
begin
  Settings.ChangePrefix := Context.Command.HasOption('comment-prefix');
  Settings.ChangeBuild := Context.Command.HasOption('build_command');
  Settings.VersionIncrement := Context.Command.Option('version_increment');
  Settings.RevisionIncrement := Context.Command.Option('revision_increment');
  if (Context.Command.HasOption('version_increment') and (Settings.VersionIncrement = '')) or
    (Context.Command.HasOption('revision_increment') and (Settings.RevisionIncrement = '')) then
    raise EScuError.Create('Expected a positive increment.');
  Editor := nil;
  try
    if Context.Command.HasOption('editor') then
    begin
      Editor := ParseJSON(Context.Command.Option('editor'), 'Invalid JSON for --editor');
      if not (Editor is TJSONArray) then
        raise EScuError.Create('Invalid value for --editor: The editor must be a JSON array of strings.');
    end;
    if not Settings.ChangePrefix and not Settings.ChangeBuild and (Editor = nil) and
      (Settings.VersionIncrement = '') and (Settings.RevisionIncrement = '') then
      raise EScuError.Create('Specify at least one library setting.');
    Settings.Prefix := PrefixOption(Context.Command);
    Settings.Editor := TJSONArray(Editor);
    Settings.BuildCommand := Context.Command.Option('build_command');
    Context.LibraryFile.Configure(Settings);
    Result := 'Updated library header';
  finally
    Editor.Free;
  end;
end;

function LockVersion(var Context: TCommandContext): string;
begin
  Context.LibraryFile.LockVersion;
  Result := 'Locked version ' + Context.LibraryFile.CurrentVersion;
end;

function StartVersion(var Context: TCommandContext): string;
begin
  Context.LibraryFile.StartVersion(Context.Command['version']);
  Result := 'Started version ' + Context.LibraryFile.CurrentVersion;
end;

function ListVersions(var Context: TCommandContext): string;
var
  Rows: TStringList;
  Row: string;
begin
  Rows := TStringList.Create;
  try
    Context.LibraryFile.ListVersions(Rows);
    for Row in Rows do
      Context.Output.WriteLine(Row);
  finally
    Rows.Free;
  end;
  Result := '';
end;

type
  THistoryWriter = class
  public
    Output: TScuOutput;
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

procedure THistoryWriter.WriteLine(const Attempt, Outcome: RawByteString);
begin
  CheckSessionInterrupt;
  Output.WriteLine(FormatAuditCommand(Attempt) + #9 + HistoryStatus(Outcome));
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
    Writer.Output := Context.Output;
    Context.Database.Audit.ReadCommandHistory(Limit, @Writer.WriteLine);
  finally
    Writer.Free;
  end;
  Result := '';
end;

end.
