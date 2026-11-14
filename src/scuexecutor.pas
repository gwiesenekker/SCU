unit ScuExecutor;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ScuCommand, ScuOutput, ScuLibrary, ScuCommandHandler, ScuAudit;

type
  TBuildRequest = ScuCommandHandler.TBuildRequest;

  TScuExecutor = class
  private
    FLibraryPath: string;
    FInteractive: Boolean;
    FOutput: TScuOutput;
    procedure RunCommand(var Context: TCommandContext; const Handler: TCommandHandler;
      OutputLock: THandle = -1);
    procedure RaiseMissingLibrary;
    function OpenCommandDatabase(var Context: TCommandContext; const Handler: TCommandHandler): Boolean;
    procedure VerifyLibrary(var Context: TCommandContext; Audit: TAuditLog; LibraryExists: Boolean);
    procedure LoadCommandLibrary(var Context: TCommandContext; Audit: TAuditLog;
      LibraryExists, Initializing: Boolean);
    procedure RecordFailedCommand(const Context: TCommandContext; Audit: TAuditLog; Error: Exception);
    function RunAuditedOperation(var Context: TCommandContext; const Handler: TCommandHandler;
      Audit: TAuditLog; LibraryExists: Boolean): string;
    procedure CommitCommand(const Context: TCommandContext;
      Audit: TAuditLog; const Detail: string);
    procedure FinishLibrary(var Context: TCommandContext; Committed: Boolean);
    procedure RestoreLibrary(var Context: TCommandContext; const Handler: TCommandHandler);
    procedure RunBuild(const Build: TBuildRequest; const Expansion: string; OutputLock: THandle);
  public
    constructor Create(const LibraryPath: string; Interactive: Boolean; Output: TScuOutput);
    procedure Execute(Command: TScuCommand);
  end;

implementation

uses
  Classes, BaseUnix, FPJSON, ScuBuild, ScuCodec, ScuCommandRegistry,
  ScuErrors, ScuFiles, ScuLibraryPaths, ScuLocks, ScuOutputLock, ScuRecovery, ScuSignals, ScuSQLite;

constructor TScuExecutor.Create(const LibraryPath: string; Interactive: Boolean; Output: TScuOutput);
begin
  inherited Create;
  FLibraryPath := NormalizeLibraryName(LibraryPath);
  FInteractive := Interactive;
  FOutput := Output;
end;

procedure TScuExecutor.RunBuild(const Build: TBuildRequest; const Expansion: string; OutputLock: THandle);
var
  Failure: string;

  procedure RecordOutcome(Cancelled: Boolean);
  var
    Lock: TFileLock;
    Audit: TAuditLog;
    Database: TSQLiteLibrary;
    Message: string;
  begin
    try
      // Record the build outcome even when the build was interrupted.
      Lock := TFileLock.Create(LibraryLockPath(FLibraryPath), @SessionEnding);
      try
        Database := TSQLiteLibrary.OpenWrite(FLibraryPath);
        try
          Audit := TAuditLog.Open(Database, Expansion);
          try
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
      on E: ECommandCancelled do raise;
      on E: Exception do
      begin
        Message := 'Could not record build outcome: ' + E.Message;
        if Cancelled then
          WriteDiagnostic('scu: ' + Message)
        else if Failure = '' then
          Failure := Message
        else
          Failure := Failure + ' ' + Message;
      end;
    end;
  end;

begin
  try
    Failure := RunBuildProcess(Build, FInteractive, OutputLock);
  except
    on E: ECommandCancelled do
    begin
      Failure := E.Message;
      RecordOutcome(True);
      raise;
    end;
  end;
  RecordOutcome(False);
  if Failure <> '' then
    raise EScuError.Create(Failure);
end;

procedure RecordSuccessfulCommand(Audit: TAuditLog; const Context: TCommandContext;
  const Detail: string);
var
  Contents: TJSONObject;
begin
  Contents := nil;
  try
    if Assigned(Context.LibraryFile) then
      Contents := Context.LibraryFile.CreateSavedContents(Context.StagedSave);
    Audit.EndCommand(True, Detail, Context.Snapshots, Contents);
  finally
    Contents.Free;
  end;
end;

procedure TScuExecutor.RestoreLibrary(var Context: TCommandContext; const Handler: TCommandHandler);
var
  Lock: TFileLock;
  TempDir, TempFile, Detail: string;
  Document: TJSONObject;
  Audit: TAuditLog;
  Stream: TFileStream;
begin
  Context.LibraryPath := CanonicalFile(Context.LibraryPath);
  Lock := TFileLock.Create(LibraryLockPath(Context.LibraryPath), @SessionEnding, @CheckSessionInterrupt);
  try
    if RegularFileExists(Context.LibraryPath) then
      raise EScuError.Create('Choose a new library path for recovery. The destination already exists.');
    Document := ReadRecovery(Context.Command);
    try
      TempDir := MakeTempDirectory('scu-restore');
      TempFile := IncludeTrailingPathDelimiter(TempDir) + 'library.sqlite';
      try
        Context.Database := TSQLiteLibrary.OpenForInitialization(TempFile);
        try
          try
            Context.LibraryFile := TDeckLibrary.CreateRecovered(Document);
          except
            on E: EScuError do raise EScuError.Create('Recovery file "' + Context.Command['recovery_file'] + '": ' + E.Message);
          end;
          try
            Audit := TAuditLog.Open(Context.Database);
            try
              Audit.BeginCommand(Context.Command);
              Detail := Handler.Run(Context);
              RecordSuccessfulCommand(Audit, Context, Detail);
              Context.Database.Commit;
            finally
              Audit.Free;
            end;
          finally
            Context.LibraryFile.Free;
          end;
        finally
          Context.Database.Free;
        end;
        CheckSessionInterrupt;
        Stream := TFileStream.Create(TempFile, fmOpenRead);
        try
          AtomicWrite(Context.LibraryPath, Stream, [awNoReplace]);
        finally
          Stream.Free;
        end;
      finally
        DeleteFile(TempFile);
        RemoveDir(TempDir);
      end;
    finally
      Document.Free;
    end;
  finally
    Lock.Free;
  end;
  Context.Output.WriteLine(Detail);
end;

procedure TScuExecutor.Execute(Command: TScuCommand);
var
  Context: TCommandContext;
  Handler: TCommandHandler;
  Lock: TOutputDirectoryLock;
begin
  Context := Default(TCommandContext);
  Context.Command := Command;
  Context.LibraryPath := FLibraryPath;
  Context.Output := FOutput;
  Handler := CommandHandler(Command.Name);
  if Handler.Mode = cmRecover then
    RestoreLibrary(Context, Handler)
  else if Assigned(Handler.ResolveOutputDirectory) then
  begin
    Context.OutputDirectory := Handler.ResolveOutputDirectory(Context);
    if not DirectoryExists(Context.OutputDirectory) then
      raise EScuError.CreateFmt('The output directory must already exist: "%s".', [Context.OutputDirectory]);
    Context.OutputDirectory := CanonicalDirectory(Context.OutputDirectory);
    if Handler.OutputLockPolicy = olReuseBuild then
      Lock := TOutputDirectoryLock.CreateWithBuildLockReuse(Context.OutputDirectory)
    else
      Lock := TOutputDirectoryLock.Create(Context.OutputDirectory);
    try
      RunCommand(Context, Handler, Lock.BuildHandle);
    finally
      Lock.Free;
    end;
  end
  else
    RunCommand(Context, Handler);
end;

procedure TScuExecutor.RaiseMissingLibrary;
begin
  raise EScuError.CreateFmt('Library "%s" does not exist. Use initialize_library to create it.',
    [FLibraryPath]);
end;

function TScuExecutor.OpenCommandDatabase(var Context: TCommandContext;
  const Handler: TCommandHandler): Boolean;
begin
  if Context.Command.HasArgument('head') and not IsHexDigest(Context.Command.Argument('head'), 64) then
    raise EScuError.Create('Expected a lowercase SHA-256 audit head.');
  if not RegularFileExists(FLibraryPath) and (Handler.Mode <> cmInitialize) then
    RaiseMissingLibrary;
  if Handler.Mode = cmInitialize then
    Context.Database := TSQLiteLibrary.OpenForInitialization(FLibraryPath)
  else if Handler.Mode in [cmHistory, cmVerifyAudit] then
    Context.Database := TSQLiteLibrary.OpenRead(FLibraryPath)
  else
    Context.Database := TSQLiteLibrary.OpenWrite(FLibraryPath);
  Result := Context.Database.Revisions.StateKey <> '';
end;

procedure TScuExecutor.VerifyLibrary(var Context: TCommandContext; Audit: TAuditLog; LibraryExists: Boolean);
begin
  if Audit.SavedHeaderDigest <> '' then
  begin
    if not LibraryExists then
      RaiseMissingLibrary;
    Context.LibraryFile := TDeckLibrary.Load(FLibraryPath, Context.Database);
    Audit.VerifyContents(Context.LibraryFile);
  end;
  FOutput.WriteLine(Format('records=%d interrupted=%d head=%s', [Audit.Records, Audit.Interrupted, Audit.Head]));
end;

procedure TScuExecutor.LoadCommandLibrary(var Context: TCommandContext; Audit: TAuditLog;
  LibraryExists, Initializing: Boolean);
begin
  if Initializing then
  begin
    if LibraryExists or Audit.Initialized then
      raise EScuError.Create('A library already exists or was previously initialized here.');
    Context.LibraryFile := TDeckLibrary.CreateNew(FLibraryPath, Context.Command.Argument('version', '1.0'));
  end
  else
  begin
    if not LibraryExists then
      RaiseMissingLibrary;
    Context.LibraryFile := TDeckLibrary.Load(FLibraryPath, Context.Database);
  end;
end;

procedure TScuExecutor.RecordFailedCommand(const Context: TCommandContext; Audit: TAuditLog; Error: Exception);
begin
  try
    Context.Database.Execute('ROLLBACK TO scu_operation');
    Audit.EndCommand(False, Error.Message, Context.Snapshots, nil, Error is ECommandCancelled);
    Context.Database.Commit;
  except
    on AuditError: ECommandCancelled do raise;
    on AuditError: Exception do
    begin
      if Error is ECommandCancelled then
        WriteDiagnostic('scu: Could not save the audit outcome: ' + AuditError.Message)
      else
        raise EScuError.CreateFmt('%s Also could not save the audit outcome: %s',
          [Error.Message, AuditError.Message]);
    end;
  end;
end;

function TScuExecutor.RunAuditedOperation(var Context: TCommandContext; const Handler: TCommandHandler;
  Audit: TAuditLog; LibraryExists: Boolean): string;
var
  Initializing: Boolean;
begin
  Initializing := Handler.Mode = cmInitialize;
  Audit.BeginCommand(Context.Command);
  Context.Database.Execute('SAVEPOINT scu_operation');
  try
    LoadCommandLibrary(Context, Audit, LibraryExists, Initializing);
    Result := Handler.Run(Context);
    if Context.FilesPublished and ClearInterrupt then
    begin
      Context.Build.Command := '';
      Context.Output.Report('Export completed before Ctrl+C; build skipped.');
    end;
    if not Initializing then
    begin
      if not SessionEnding then
        FOutput.Flush;
      // Stage changes for both interactive and one-shot commands. The audit
      // outcome and library rows commit together in CommitCommand.
      Context.LibraryFile.Save(Context.Database, Context.StagedSave);
    end;
  except
    on E: ECommandCancelled do
    begin
      if not Context.FilesPublished then
      begin
        RecordFailedCommand(Context, Audit, E);
        raise;
      end;
      ClearInterrupt;
      Context.Build.Command := '';
      Result := 'Export completed; Ctrl+C stopped the remaining display and build.';
      Context.LibraryFile.Save(Context.Database, Context.StagedSave);
    end;
    on E: Exception do
    begin
      if Initializing and not LibraryExists then
        raise;
      RecordFailedCommand(Context, Audit, E);
      raise;
    end;
  end;
end;

procedure TScuExecutor.CommitCommand(const Context: TCommandContext;
  Audit: TAuditLog; const Detail: string);
begin
  try
    RecordSuccessfulCommand(Audit, Context, Detail);
    Context.Database.Commit;
  except
    on E: ECommandCancelled do raise;
    on E: Exception do
      raise EScuError.Create('Could not commit the command outcome: ' + E.Message);
  end;
end;

procedure TScuExecutor.FinishLibrary(var Context: TCommandContext; Committed: Boolean);
begin
  if Assigned(Context.LibraryFile) then
  begin
    if Committed then
      Context.LibraryFile.AcceptSave(Context.StagedSave);
    FreeAndNil(Context.LibraryFile);
  end;
end;

procedure TScuExecutor.RunCommand(var Context: TCommandContext; const Handler: TCommandHandler;
  OutputLock: THandle);
var
  Lock: TFileLock;
  Audit: TAuditLog;
  LibraryExists, Committed: Boolean;
  Checkpoint, Detail, Expansion: string;
begin
  if Context.Command.SessionExit and not FInteractive then
    raise EScuError.CreateFmt('%s is only available in interactive mode.', [Context.Command.Name]);
  FLibraryPath := CanonicalFile(FLibraryPath);
  Context.LibraryPath := FLibraryPath;
  Audit := nil;
  Committed := False;
  Lock := nil;
  try
    if Handler.Mode <> cmHistory then
      Lock := TFileLock.Create(LibraryLockPath(FLibraryPath), @SessionEnding, @CheckSessionInterrupt);
    LibraryExists := OpenCommandDatabase(Context, Handler);
    if Handler.Mode = cmHistory then
    begin
      if not LibraryExists then
        RaiseMissingLibrary;
      Handler.Run(Context);
      Exit;
    end;
    Checkpoint := Context.Command.Argument('head');
    if Handler.Mode = cmVerifyAudit then
      Audit := TAuditLog.Verify(Context.Database, Checkpoint)
    else
      Audit := TAuditLog.Open(Context.Database, Checkpoint);
    if LibraryExists and (Audit.Records = 0) then
      raise EScuError.Create('The audit log for the existing library is empty.');
    if Handler.Mode = cmVerifyAudit then
    begin
      VerifyLibrary(Context, Audit, LibraryExists);
      Exit;
    end;
    Detail := RunAuditedOperation(Context, Handler, Audit, LibraryExists);
    CommitCommand(Context, Audit, Detail);
    Committed := True;
    if Context.Build.Command <> '' then
      Expansion := Audit.Head;
    if (Detail <> '') and (PendingSignal <> SIGHUP) then
      FOutput.WriteLine(Detail);
    if Assigned(Handler.ReportCommitted) then
      Handler.ReportCommitted(Context);
  finally
    FinishLibrary(Context, Committed);
    Audit.Free;
    Context.Database.Free;
    Lock.Free;
  end;
  if (Context.Build.Command <> '') and not SessionEnding then
  begin
    FOutput.Flush;
    RunBuild(Context.Build, Expansion, OutputLock);
  end;
end;

end.
