unit ScuExecutor;

{$mode objfpc}{$H+}

interface

uses
  ScuCommand, ScuOutput, ScuLibrary, ScuAudit, ScuSQLite;

type
  TBuildRequest = record
    Command, OutputPath: string;
    Checkpoint: TLibrarySnapshot;
    CommentPrefix: string;
  end;

  TScuExecutor = class
  private
    FLibraryPath: string;
    FInteractive: Boolean;
    FOutput: TScuOutput;
    FPendingLibrary: TDeckLibrary;
    function ResolveSnapshot(Command: TScuCommand; LibraryFile: TDeckLibrary; const Deck: string): TLibrarySnapshot;
    function OutputPath(const Path: string): string;
    function BulkOutputDirectory(Command: TScuCommand): string;
    function PrefixOption(Command: TScuCommand): string;
    function ExecuteLibrary(Command: TScuCommand; LibraryFile: TDeckLibrary; Database: TSQLiteLibrary;
      const OutputDirectory: string; out SnapshotsUsed: TAuditSnapshots; out Build: TBuildRequest): string;
    procedure RunCommandInDirectory(Command: TScuCommand; const OutputDirectory: string;
      OutputLock: THandle = -1);
    procedure RunBuild(const Build: TBuildRequest; const Expansion: string; OutputLock: THandle);
    procedure WriteHistoryLine(const Payload: RawByteString);
  public
    constructor Create(const LibraryPath: string; Interactive: Boolean; Output: TScuOutput);
    destructor Destroy; override;
    procedure Execute(Command: TScuCommand);
    function RecoverPendingLibrary: string;
    property PendingLibrary: TDeckLibrary read FPendingLibrary;
  end;

implementation

uses
  Classes, SysUtils, BaseUnix, Process, FPJSON, ScuIO, ScuJSON, ScuCodec,
  ScuExpand, ScuEdit, ScuDiff, ScuCommands, ScuVersions, ScuSignals, ScuRecovery, ScuOutputLock;

const
  CurrentLibraryVersionSelector = 'scu$current_library_version';
  LibraryDirectorySelector = 'scu$library_directory';
  DeckNameSelector = 'scu$deck_name';

constructor TScuExecutor.Create(const LibraryPath: string; Interactive: Boolean; Output: TScuOutput);
begin
  inherited Create;
  FLibraryPath := LibraryPath;
  FInteractive := Interactive;
  FOutput := Output;
end;

destructor TScuExecutor.Destroy;
begin
  FPendingLibrary.Free;
  inherited Destroy;
end;

function TScuExecutor.ResolveSnapshot(Command: TScuCommand; LibraryFile: TDeckLibrary; const Deck: string): TLibrarySnapshot;
var
  Version: string;
  Base, Revision: Integer;
begin
  if Command.HasOption('version') then
  begin
    if Command.HasOption('revision') then
      raise EScuError.Create('Choose either --version or --revision.');
    Version := Command.Option('version');
    if ((Command.Name = 'extract_deck') or (Command.Name = 'expand_deck')) and (Pos('-', Version) > 0) then
      Exit(LibraryFile.ParseDeckSnapshot(DeckName(Deck), Version));
    LibraryFile.VersionBounds(Version, Base, Revision);
  end
  else if Command.HasOption('revision') then
  begin
    Revision := LibraryFile.ParseRevision(Command.Option('revision'));
    Version := LibraryFile.VersionAt(Revision);
  end
  else
    Exit(LibraryFile.CurrentSnapshot);
  Result.Version := Version;
  Result.LibraryRevision := Revision;
end;

function TScuExecutor.OutputPath(const Path: string): string;
begin
  Result := CanonicalFile(Path);
  if (Result = FLibraryPath) or (Result = FLibraryPath + '.lock') or
    (Result = FLibraryPath + '-journal') or
    (Result = FLibraryPath + '-wal') or (Result = FLibraryPath + '-shm') then
    raise EScuError.Create('The output path would overwrite a library or audit file.');
  RegularFileExists(Result);
end;

function TScuExecutor.PrefixOption(Command: TScuCommand): string;
begin
  Result := Command.Option('comment-prefix');
  if Command.HasOption('comment-prefix') then
    ValidateCommentPrefix(Result);
end;

function TScuExecutor.BulkOutputDirectory(Command: TScuCommand): string;
begin
  Result := Command.Arguments[1].Value;
  if (Command.Name = 'expand_modified_decks') and SameText(Result, LibraryDirectorySelector) then
    Result := ExtractFileDir(CanonicalFile(FLibraryPath));
end;

function TScuExecutor.ExecuteLibrary(Command: TScuCommand; LibraryFile: TDeckLibrary; Database: TSQLiteLibrary;
  const OutputDirectory: string; out SnapshotsUsed: TAuditSnapshots; out Build: TBuildRequest): string;
var
  Source, OtherSource: TDeckSource;
  Bytes: RawByteString;
  Expander: TDeckExpander;
  Names, Destinations: TStringList;
  Deck, Name, Path, Version, VersionIncrement, RevisionIncrement, Prefix, Directory, MissingDeckVersion: string;
  Revision, Base, Index, CheckpointRevision: Integer;
  Previous, FromSnapshot, ToSnapshot: TLibrarySnapshot;
  Editor: TJSONData;
  ChangePrefix, ChangeBuild, SaveRequested, UsePriorDeckRevision, Refresh, BuildPending: Boolean;

  function ResolveLastModifiedDeck: string;
  begin
    Result := LibraryFile.LastModifiedDeck;
    if Result = '' then
      raise EScuError.Create('No deck has been modified in this library.');
  end;

  function DeckWriteReport(const Deck: string; StoredRevision: Integer): string;
  begin
    if StoredRevision = 0 then
      Exit('No changes to ' + Deck);
    Result := Format('%s version %s revision %s, deck version %s',
      [Deck, LibraryFile.VersionAt(StoredRevision), LibraryFile.DeckRevision[StoredRevision],
        LibraryFile.DeckVersion[StoredRevision]]);
  end;

  procedure ReportSnapshot(const LabelText: string; const Snapshot: TLibrarySnapshot);
  begin
    FOutput.Report(Format('%s version %s, library revision %d.',
      [LabelText, Snapshot.Version, Snapshot.LibraryRevision]));
  end;

  procedure ScheduleBuild(const Target: string);
  var
    Enabled: Boolean;
  begin
    if not TryParseYesNo(Command.Option('build', 'no'), Enabled) then
      raise EScuError.Create('Expected yes/y or no/n for build.');
    if Enabled and (LibraryFile.BuildCommand <> '') then
    begin
      Build.Command := LibraryFile.BuildCommand;
      Build.OutputPath := Target;
    end;
  end;

begin
  Result := '';
  Build := Default(TBuildRequest);
  Deck := '';
  if Command.ArgumentCount > 0 then
  begin
    Deck := Command.Arguments[0].Value;
    if (Command.Arguments[0].Name = 'deck_name') and SameText(Deck, LastModifiedDeckSelector) then
    begin
      Deck := ResolveLastModifiedDeck;
      SnapshotsUsed.ResolvedDeck := Deck;
    end;
  end;
  case Command.Name of
    'save_library', 'quit_session', 'quit':
      begin
        SaveRequested := True;
        if Command.SessionExit and (Command.ArgumentCount > 0) and
          not TryParseYesNo(Command.Arguments[0].Value, SaveRequested) then
          raise EScuError.Create('Expected yes/y or no/n for save_library.');
        if not SaveRequested then
          Result := 'Discarded unsaved library changes.'
        else if LibraryFile.Modified then
        begin
          LibraryFile.Save;
          SnapshotsUsed.Selected := LibraryFile.CurrentSnapshot;
          Result := 'Saved library.';
        end
        else
          Result := 'No unsaved library changes.';
      end;
    'display_expansion_checkpoints':
      begin
        Names := TStringList.Create;
        try
          Database.ListExpansionCheckpoints(Names);
          if Names.Count = 0 then
            Result := 'No expansion checkpoints.'
          else
          begin
            FOutput.WriteLine('Version'#9'Output directory'#9'Last built library revision'#9'Status'#9 +
              'Last successful build (UTC)'#9'Checkpoint library revision');
            for Name in Names do
              FOutput.WriteLine(Name);
          end;
        finally
          Names.Free;
        end;
      end;
    'reset_expansion_checkpoint':
      begin
        Version := Command.Arguments[0].Value;
        LibraryFile.VersionBounds(Version, Base, Revision);
        if Database.ResetExpansionCheckpoint(Version, OutputDirectory) then
          Result := Format('Reset expansion checkpoint for version %s in "%s".', [Version, OutputDirectory])
        else
          Result := Format('No expansion checkpoint for version %s in "%s".', [Version, OutputDirectory]);
      end;
    'display_library':
      begin
        SnapshotsUsed.Selected := LibraryFile.CurrentSnapshot;
        Version := 'none';
        if LibraryFile.TryPreviousSnapshot(Previous) then
          Version := Previous.Version;
        Result := Format('Library "%s", current version %s, previous locked version %s.',
          [FLibraryPath, SnapshotsUsed.Selected.Version, Version]);
      end;
    'show_library':
      FOutput.WriteLine(LibraryFile.HeaderJSON);
    'configure_library', 'configure':
      begin
        ChangePrefix := Command.HasOption('comment-prefix');
        ChangeBuild := Command.HasOption('build_command');
        VersionIncrement := Command.Option('version_increment');
        RevisionIncrement := Command.Option('revision_increment');
        if ((Command.HasOption('version_increment')) and (VersionIncrement = '')) or
          ((Command.HasOption('revision_increment')) and (RevisionIncrement = '')) then
          raise EScuError.Create('Expected a positive increment.');
        Editor := nil;
        try
          if Command.HasOption('editor') then
          begin
            Editor := ParseJSON(Command.Option('editor'));
            if not (Editor is TJSONArray) then
              raise EScuError.Create('The editor must be a JSON array of strings.');
          end;
          if not ChangePrefix and not ChangeBuild and (Editor = nil) and
            (VersionIncrement = '') and (RevisionIncrement = '') then
            raise EScuError.Create('Specify at least one library setting.');
          LibraryFile.Configure(ChangePrefix, PrefixOption(Command), TJSONArray(Editor), VersionIncrement,
            RevisionIncrement, ChangeBuild, Command.Option('build_command'));
          Result := 'Updated library header';
        finally
          Editor.Free;
        end;
      end;
    'edit_deck':
      begin
        Name := DeckName(Deck);
        Result := DeckWriteReport(Name, EditDeck(LibraryFile, Name));
      end;
    'create_deck', 'store_deck':
      begin
        LibraryFile.RequireOpenVersion;
        Name := DeckName(Deck);
        Bytes := '';
        if (Command.Name = 'store_deck') or (Command.Arguments[1].Value <> '') then
          Bytes := ReadBytes(Command.Arguments[1].Value, MaxDeckSize);
        Revision := LibraryFile.Store(Name, Bytes, Command.Name = 'create_deck', PrefixOption(Command));
        Result := DeckWriteReport(Name, Revision);
      end;
    'lock_version':
      begin
        LibraryFile.LockVersion;
        Result := 'Locked version ' + LibraryFile.CurrentVersion;
      end;
    'start_version':
      begin
        LibraryFile.StartVersion(Command.Arguments[0].Value);
        Result := 'Started version ' + LibraryFile.CurrentVersion;
      end;
    'display_deck_list', 'list_versions', 'display_deck':
      begin
        Names := TStringList.Create;
        try
          if Command.Name = 'list_versions' then
            LibraryFile.ListVersions(Names)
          else if Command.Name = 'display_deck' then
            LibraryFile.ListDeckHistory(Deck, Names)
          else
          begin
            SnapshotsUsed.Selected := ResolveSnapshot(Command, LibraryFile, Deck);
            LibraryFile.List(SnapshotsUsed.Selected.LibraryRevision, Names);
            Names.Sort;
          end;
          for Name in Names do
            FOutput.WriteLine(Name);
          if Command.Name = 'display_deck_list' then
            ReportSnapshot('Using', SnapshotsUsed.Selected);
        finally
          Names.Free;
        end;
      end;
    'diff_deck':
      begin
        Name := DeckName(Deck);
        UsePriorDeckRevision := not Command.Arguments[1].Provided and
          SameText(Command.Arguments[1].Value, PreviousDeckVersionSelector);
        if not UsePriorDeckRevision then
        begin
          FromSnapshot := LibraryFile.ParseDeckSnapshot(Name, Command.Arguments[1].Value);
          SnapshotsUsed.FromDeckVersion := LibraryFile.DeckVersion[FromSnapshot.LibraryRevision];
        end;
        ToSnapshot := LibraryFile.ParseDeckSnapshot(Name, Command.Arguments[2].Value);
        SnapshotsUsed.ToDeckVersion := LibraryFile.DeckVersion[ToSnapshot.LibraryRevision];
        if UsePriorDeckRevision then
        begin
          FromSnapshot := LibraryFile.PreviousDeckSnapshot(Name, ToSnapshot.LibraryRevision);
          SnapshotsUsed.FromDeckVersion := LibraryFile.DeckVersion[FromSnapshot.LibraryRevision];
        end;
        Source := LibraryFile.Extract(Name, FromSnapshot.LibraryRevision);
        OtherSource := LibraryFile.Extract(Name, ToSnapshot.LibraryRevision);
        WriteDeckDiff(Source.Bytes, OtherSource.Bytes,
          Name + '@' + SnapshotsUsed.FromDeckVersion, Name + '@' + SnapshotsUsed.ToDeckVersion, FOutput);
        FOutput.Report('From deck version ' + SnapshotsUsed.FromDeckVersion + '.');
        FOutput.Report('To deck version ' + SnapshotsUsed.ToDeckVersion + '.');
      end;
    'extract_deck', 'expand_deck':
      begin
        SnapshotsUsed.Selected := ResolveSnapshot(Command, LibraryFile, Deck);
        MissingDeckVersion := '';
        if not Command.HasOption('revision') then
          MissingDeckVersion := SnapshotsUsed.Selected.Version;
        Path := Command.Arguments[1].Value;
        if SameText(Path, DeckNameSelector) then
          Path := DeckName(Deck)
        else if SameText(Path, LastModifiedDeckSelector) then
          Path := ResolveLastModifiedDeck;
        Path := OutputPath(Path);
        if Command.Name = 'expand_deck' then
        begin
          Expander := TDeckExpander.Create(LibraryFile, SnapshotsUsed.Selected.LibraryRevision,
            SnapshotsUsed.Selected.Version, PrefixOption(Command), MissingDeckVersion);
          try
            Bytes := Expander.Expand(Deck);
          finally
            Expander.Free;
          end;
        end
        else
        begin
          Source := LibraryFile.Extract(Deck, SnapshotsUsed.Selected.LibraryRevision, MissingDeckVersion);
          Bytes := Source.Bytes;
        end;
        CheckSessionInterrupt;
        AtomicWrite(Path, Bytes, True, True);
        if Command.Name = 'expand_deck' then
          ScheduleBuild(Path);
        ReportSnapshot('Using', SnapshotsUsed.Selected);
      end;
    'extract_modified_decks', 'expand_modified_decks':
      begin
        Version := Command.Arguments[0].Value;
        if (Command.Name = 'expand_modified_decks') and SameText(Version, CurrentLibraryVersionSelector) then
          Version := LibraryFile.CurrentVersion;
        Directory := OutputDirectory;
        if Directory = '' then
          Directory := BulkOutputDirectory(Command)
        else if LibraryFile.Modified then
          raise EScuError.Create('Save the SQLite library before running expand_modified_decks.');
        LibraryFile.VersionBounds(Version, Base, Revision);
        if not DirectoryExists(Directory) then
          raise EScuError.Create('The output directory must already exist.');
        SnapshotsUsed.Selected.Version := Version;
        SnapshotsUsed.Selected.LibraryRevision := Revision;
        BuildPending := False;
        if OutputDirectory <> '' then
          if Database.ReadExpansionCheckpoint(Version, Directory, CheckpointRevision, Refresh, BuildPending) then
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
          if Command.Name = 'expand_modified_decks' then
          begin
            Prefix := PrefixOption(Command);
            Expander := TDeckExpander.Create(LibraryFile, Revision, Version, Prefix);
            if OutputDirectory <> '' then
              Expander.IncludeCopyDependents(Names);
          end;
          Destinations := TStringList.Create;
          for Name in Names do
            Destinations.Add(OutputPath(IncludeTrailingPathDelimiter(Directory) + Name));
          for Index := 0 to Names.Count - 1 do
          begin
            if Assigned(Expander) then
              Bytes := Expander.Expand(Names[Index])
            else
            begin
              Source := LibraryFile.Extract(Names[Index], Revision);
              Bytes := Source.Bytes;
            end;
            CheckSessionInterrupt;
            AtomicWrite(Destinations[Index], Bytes, True, True);
          end;
          if Assigned(Expander) and ((Names.Count > 0) or BuildPending) then
          begin
            if OutputDirectory = '' then
              ScheduleBuild(ExtractFileDir(Destinations[0]))
            else
            begin
              ScheduleBuild(Directory);
              if Build.Command <> '' then
              begin
                Build.Checkpoint := SnapshotsUsed.Selected;
                Build.CommentPrefix := Prefix;
              end
              else if (Names.Count > 0) and (LibraryFile.BuildCommand = '') then
                Database.SaveExpansionCheckpoint(Version, Directory, Prefix, Revision, True);
            end;
          end;
          Result := Format('Wrote %d deck(s) for version %s', [Names.Count, Version]);
        finally
          Expander.Free;
          Destinations.Free;
          Names.Free;
        end;
      end;
    else
      raise EScuError.CreateFmt('No implementation for command "%s".', [Command.Name]);
  end;
end;

type
  TBuildProcess = class(TProcess)
  private
    FOutputLock: THandle;
    FInteractive: Boolean;
    procedure PrepareChild(Sender: TObject);
  public
    constructor Create(OutputLock: THandle; Interactive: Boolean); reintroduce;
  end;

constructor TBuildProcess.Create(OutputLock: THandle; Interactive: Boolean);
var
  Index: Integer;
begin
  inherited Create(nil);
  FOutputLock := OutputLock;
  FInteractive := Interactive;
  if OutputLock >= 0 then
  begin
    for Index := 1 to GetEnvironmentVariableCount do
      Environment.Add(GetEnvironmentString(Index));
    Environment.Values[BuildOutputLockVariable] := IntToStr(OutputLock);
  end;
  OnForkEvent := @PrepareChild;
end;

procedure TBuildProcess.PrepareChild(Sender: TObject);
begin
  // Only the build child and its descendants inherit the directory descriptor.
  if (FOutputLock >= 0) and (fpFcntl(FOutputLock, F_SETFD, 0) < 0) then
    fpExit(126);
  if FInteractive then
    StartBuildProcessGroup;
end;

procedure TScuExecutor.RunBuild(const Build: TBuildRequest; const Expansion: string; OutputLock: THandle);
var
  Child: TProcess;
  Lock: TLibraryLock;
  Audit: TAuditLog;
  Database: TSQLiteLibrary;
  Failure: string;
  Status: Integer;
begin
  Failure := '';
  try
    Child := TBuildProcess.Create(OutputLock, FInteractive);
    try
      Child.Executable := '/bin/sh';
      Child.Parameters.Add('-c');
      Child.Parameters.Add('exec </dev/null' + LineEnding + Build.Command);
      Child.Parameters.Add('scu-build');
      Child.Parameters.Add(Build.OutputPath);
      Status := WaitForChild(Child, FInteractive);
      if (SessionSignal <> 0) or (Status = 128 + SIGINT) then
        raise EScuError.Create('Build command interrupted.');
      if Status <> 0 then
        raise EScuError.CreateFmt('Build command failed with exit status %d.', [Status]);
    finally
      Child.Free;
    end;
  except
    on E: Exception do Failure := E.Message;
  end;

  try
    // Record the build outcome even when the build was interrupted.
    Lock := TLibraryLock.Create(FLibraryPath + '.lock', @SessionEnding);
    try
      Database := nil;
      try
        Database := TSQLiteLibrary.Create(FLibraryPath, False, False);
        Database.BeginTransaction(False);
        Database.EnsureSchema(False);
        Audit := TAuditLog.Create(Database, Expansion);
        try
          if (Failure = '') and (Build.Checkpoint.Version <> '') then
            Database.SaveExpansionCheckpoint(Build.Checkpoint.Version, Build.OutputPath,
              Build.CommentPrefix, Build.Checkpoint.LibraryRevision, False);
          Audit.RecordBuild(Expansion, Build.Command, Build.OutputPath, Failure = '', Failure);
          Database.Commit;
        finally
          Audit.Free;
        end;
      finally
        Database.Free;
      end;
    finally
      Lock.Free;
    end;
  except
    on E: Exception do
    begin
      if Failure <> '' then
        Failure := Failure + ' ';
      Failure := Failure + 'Could not record build outcome: ' + E.Message;
    end;
  end;
  if Failure <> '' then
    raise EScuError.Create(Failure);
end;

procedure TScuExecutor.Execute(Command: TScuCommand);
var
  Directory, Path: string;
  Lock: TOutputDirectoryLock;
begin
  if Command.Name = 'recover_library' then
  begin
    if Assigned(FPendingLibrary) then
      raise EScuError.Create('Finish pending edits before recovering a library.');
    FOutput.WriteLine(RestoreLibrary(CanonicalFile(FLibraryPath), Command));
    Exit;
  end;
  if Command.Name = 'expand_deck' then
  begin
    Path := Command.Arguments[1].Value;
    if (Path = '') or SameText(Path, DeckNameSelector) or SameText(Path, LastModifiedDeckSelector) then
      Directory := GetCurrentDir
    else
      Directory := ExtractFileDir(ExpandFileName(Path));
  end
  else if (Command.Name = 'expand_modified_decks') or (Command.Name = 'reset_expansion_checkpoint') then
    Directory := BulkOutputDirectory(Command)
  else
  begin
    RunCommandInDirectory(Command, '');
    Exit;
  end;
  if not DirectoryExists(Directory) then
    raise EScuError.Create('The output directory must already exist.');
  Directory := CanonicalDirectory(Directory);
  Lock := TOutputDirectoryLock.Create(Directory, Command.Name = 'expand_deck');
  try
    if Command.Name <> 'expand_deck' then
      RunCommandInDirectory(Command, Directory, Lock.BuildHandle)
    else
      RunCommandInDirectory(Command, '', Lock.BuildHandle);
  finally
    Lock.Free;
  end;
end;

procedure TScuExecutor.WriteHistoryLine(const Payload: RawByteString);
begin
  FOutput.WriteLine(FormatAuditCommand(Payload));
end;

procedure TScuExecutor.RunCommandInDirectory(Command: TScuCommand; const OutputDirectory: string;
  OutputLock: THandle);
var
  Lock: TLibraryLock;
  Audit: TAuditLog;
  Database: TSQLiteLibrary;
  LibraryFile: TDeckLibrary;
  LibraryExists, Verifying, ListingHistory, Initializing, Committed, PendingSave: Boolean;
  Checkpoint, Detail, Expansion, ExpansionVersion: string;
  SnapshotsUsed: TAuditSnapshots;
  Build: TBuildRequest;
  Contents: TJSONObject;
  HistoryLimit: Int64;

  procedure RaiseMissingLibrary;
  begin
    raise EScuError.CreateFmt('Library "%s" does not exist. Use initialize_library to create it.',
      [FLibraryPath]);
  end;


begin
  if Command.SessionExit and not FInteractive then
    raise EScuError.CreateFmt('%s is only available in interactive mode.', [Command.Name]);
  FLibraryPath := CanonicalFile(FLibraryPath);
  Verifying := Command.Name = 'verify_audit';
  ListingHistory := Command.Name = 'show_history';
  Initializing := (Command.Name = 'initialize_library') or (Command.Name = 'init');
  Build := Default(TBuildRequest);
  Lock := nil;
  Database := nil;
  Audit := nil;
  LibraryFile := nil;
  Committed := False;
  try
    Lock := TLibraryLock.Create(FLibraryPath + '.lock', @SessionEnding, @CheckSessionInterrupt);
    Checkpoint := Command.Option('head');
    if (Command.HasOption('head')) and not IsHexDigest(Checkpoint, 64) then
      raise EScuError.Create('Expected a lowercase SHA-256 audit head.');
    if not RegularFileExists(FLibraryPath) and not Initializing then
      RaiseMissingLibrary;
    Database := TSQLiteLibrary.Create(FLibraryPath, Initializing, Verifying or ListingHistory);
    Database.BeginTransaction(Verifying or ListingHistory);
    Database.EnsureSchema(Initializing);
    LibraryExists := Database.StateKey <> '';
    if ListingHistory then
    begin
      if not LibraryExists then
        RaiseMissingLibrary;
      if not TryStrToInt64(Command.Arguments[0].Value, HistoryLimit) or (HistoryLimit < 1) then
        raise EScuError.Create('Expected a positive number_of_lines.');
      Database.ReadCommandHistory(HistoryLimit, @WriteHistoryLine);
      Exit;
    end;
    Audit := TAuditLog.Create(Database, Checkpoint, Verifying);
    if (LibraryExists or Assigned(FPendingLibrary)) and (Audit.Records = 0) then
      raise EScuError.Create('The audit log for the existing library is empty.');
    if Verifying then
    begin
      if Audit.SavedHeaderDigest <> '' then
      begin
        if not LibraryExists then
          RaiseMissingLibrary;
        LibraryFile := TDeckLibrary.Create(FLibraryPath, '', Database);
        Audit.VerifyContents(LibraryFile);
      end;
      FOutput.WriteLine(Format('records=%d interrupted=%d head=%s', [Audit.Records, Audit.Interrupted, Audit.Head]));
      Exit;
    end;
    if (Command.Name = 'expand_modified_decks') and (OutputDirectory <> '') and LibraryExists and
      not Assigned(FPendingLibrary) then
    begin
      ExpansionVersion := Command.Arguments[0].Value;
      if SameText(ExpansionVersion, CurrentLibraryVersionSelector) then
        ExpansionVersion := Database.CurrentVersion;
      if Database.InvalidateExpansionOutput(ExpansionVersion, OutputDirectory, PrefixOption(Command)) then
      begin
        // Output files cannot roll back with SQLite. Invalidate before writing
        // files for a different version or prefix, even if expansion fails.
        Database.Commit;
        Database.BeginTransaction(False);
        FreeAndNil(Audit);
        Audit := TAuditLog.Create(Database, Checkpoint);
      end;
    end;
    Audit.BeginCommand(Command);
    Database.Execute('SAVEPOINT scu_operation');
    SnapshotsUsed := Default(TAuditSnapshots);
    try
      if Initializing then
      begin
        if LibraryExists or Audit.Initialized then
          raise EScuError.Create('A library already exists or was previously initialized here.');
        LibraryFile := TDeckLibrary.Create(FLibraryPath, '1.0', Database);
        LibraryFile.Save;
        Detail := 'Initialized version ' + LibraryFile.CurrentVersion;
      end
      else
      begin
        LibraryFile := FPendingLibrary;
        if not Assigned(LibraryFile) then
        begin
          if not LibraryExists then
            RaiseMissingLibrary;
          LibraryFile := TDeckLibrary.Create(FLibraryPath, '', Database);
        end
        else
          LibraryFile.AttachDatabase(Database);
        Detail := ExecuteLibrary(Command, LibraryFile, Database, OutputDirectory, SnapshotsUsed, Build);
        if not SessionEnding then
          FOutput.Flush;
        if not FInteractive then
          LibraryFile.Save;
      end;
    except
      on E: Exception do
      begin
        if Initializing and not LibraryExists then
          raise;
        try
          Database.Execute('ROLLBACK TO scu_operation');
          Audit.EndCommand(False, E.Message, SnapshotsUsed, Assigned(FPendingLibrary));
          Database.Commit;
        except
          on AuditError: Exception do
            raise EScuError.CreateFmt('%s Also could not save the audit outcome: %s',
              [E.Message, AuditError.Message]);
        end;
        raise;
      end;
    end;
    try
      PendingSave := FInteractive and Assigned(LibraryFile) and LibraryFile.Modified and
        not Initializing and not Command.SessionExit and (Command.Name <> 'save_library');
      Contents := nil;
      try
        if Assigned(LibraryFile) then
          Contents := LibraryFile.SavedContents;
        Audit.EndCommand(True, Detail, SnapshotsUsed, PendingSave, Contents);
      finally
        Contents.Free;
      end;
      Database.Commit;
      Committed := True;
      if Build.Command <> '' then
        Expansion := Audit.Head;
    except
      on E: Exception do
        raise EScuError.Create('Could not commit the command outcome: ' + E.Message);
    end;
    if (Detail <> '') and not SessionEnding then
      FOutput.WriteLine(Detail);
    if Command.Name = 'display_library' then
      FOutput.WriteLine(LibraryFile.HeaderJSON);
  finally
    if Assigned(LibraryFile) then
    begin
      LibraryFile.FinishDatabaseSave(Committed);
      if FInteractive and LibraryFile.Modified and not Initializing then
        FPendingLibrary := LibraryFile
      else
      begin
        if LibraryFile = FPendingLibrary then
          FPendingLibrary := nil;
        LibraryFile.Free;
      end;
    end;
    Audit.Free;
    Database.Free;
    Lock.Free;
  end;
  if Build.Command <> '' then
  begin
    FOutput.Flush;
    RunBuild(Build, Expansion, OutputLock);
  end;
end;

function TScuExecutor.RecoverPendingLibrary: string;
var
  Data: RawByteString;
begin
  if not Assigned(FPendingLibrary) then
    Exit('');
  Data := FPendingLibrary.ExportRecoveryJSON;
  Result := FLibraryPath + '.recovery-' + IntToStr(fpGetPid) + '.json';
  try
    AtomicWrite(Result, Data, False);
  except
    on E: Exception do
    begin
      Result := IncludeTrailingPathDelimiter(MakeTempDirectory('scu-recovery')) + 'library.json';
      AtomicWrite(Result, Data, False);
    end;
  end;
end;

end.
