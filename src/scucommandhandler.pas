unit ScuCommandHandler;

{$mode objfpc}{$H+}

interface

uses
  ScuAudit, ScuCommand, ScuLibrary, ScuOutput, ScuSQLite;

type
  TBuildRequest = record
    Command, OutputPath: string;
    Checkpoint: TLibrarySnapshot;
    CommentPrefix: string;
  end;

  TCommandContext = record
    // The executor owns the command's locks, database and library lifetime.
    Command: TScuCommand;
    LibraryPath, OutputDirectory: string;
    LibraryFile: TDeckLibrary;
    Database: TSQLiteLibrary;
    StagedSave: TLibrarySave;
    Output: TScuOutput;
    Snapshots: TAuditSnapshots;
    Build: TBuildRequest;
  end;

  TCommandOperation = function(var Context: TCommandContext): string;
  TResolveOutputDirectory = function(const Context: TCommandContext): string;
  // True asks the executor to commit the preparation before running the command.
  TPrepareCommand = function(const Context: TCommandContext): Boolean;
  TReportCommand = procedure(const Context: TCommandContext);

  TCommandMode = (cmLibrary, cmInitialize, cmHistory, cmVerifyAudit, cmRecover);
  TCommandHandler = record
    Mode: TCommandMode;
    Run: TCommandOperation;
    ResolveOutputDirectory: TResolveOutputDirectory;
    Prepare: TPrepareCommand;
    ReportCommitted: TReportCommand;
    SavesLibrary, ReuseBuildLock: Boolean;
  end;

function PrefixOption(Command: TScuCommand): string;
function ResolveSnapshot(const Context: TCommandContext; const Deck: string = '';
  AllowDeckVersion: Boolean = False): TLibrarySnapshot;
function ResolveLastModifiedDeck(LibraryFile: TDeckLibrary): string;
function ResolveDeck(var Context: TCommandContext): string;
procedure ReportSnapshot(const Context: TCommandContext);

implementation

uses
  SysUtils, ScuIO, ScuVersions;

function PrefixOption(Command: TScuCommand): string;
begin
  Result := Command.Option('comment-prefix');
  if Command.HasOption('comment-prefix') then
    ValidateCommentPrefix(Result);
end;

function ResolveSnapshot(const Context: TCommandContext; const Deck: string;
  AllowDeckVersion: Boolean): TLibrarySnapshot;
var
  Version: string;
  Base, Revision: Integer;
begin
  if Context.Command.HasOption('version') then
  begin
    if Context.Command.HasOption('revision') then
      raise EScuError.Create('Choose either --version or --revision.');
    Version := Context.Command.Option('version');
    if AllowDeckVersion and (Pos('-', Version) > 0) then
      Exit(Context.LibraryFile.ParseDeckSnapshot(DeckName(Deck), Version));
    Context.LibraryFile.VersionBounds(Version, Base, Revision);
  end
  else if Context.Command.HasOption('revision') then
  begin
    Revision := Context.LibraryFile.ParseRevision(Context.Command.Option('revision'));
    Version := Context.LibraryFile.VersionAt(Revision);
  end
  else
    Exit(Context.LibraryFile.CurrentSnapshot);
  Result.Version := Version;
  Result.LibraryRevision := Revision;
end;

function ResolveLastModifiedDeck(LibraryFile: TDeckLibrary): string;
begin
  Result := LibraryFile.LastModifiedDeck;
  if Result = '' then
    raise EScuError.Create('No deck has been modified in this library.');
end;

function ResolveDeck(var Context: TCommandContext): string;
begin
  Result := Context.Command['deck_name'];
  if SameText(Result, LastModifiedDeckSelector) then
  begin
    Result := ResolveLastModifiedDeck(Context.LibraryFile);
    Context.Snapshots.ResolvedDeck := Result;
  end;
end;

procedure ReportSnapshot(const Context: TCommandContext);
begin
  Context.Output.Report(Format('Using version %s, library revision %d.',
    [Context.Snapshots.Selected.Version, Context.Snapshots.Selected.LibraryRevision]));
end;

end.
