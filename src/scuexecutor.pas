unit ScuExecutor;

{$mode objfpc}{$H+}

interface

uses
  ScuCommand, ScuOutput, ScuLibrary, ScuCommandHandler;

type
  TBuildRequest = ScuCommandHandler.TBuildRequest;

  TScuExecutor = class
  private
    FLibraryPath: string;
    FInteractive: Boolean;
    FOutput: TScuOutput;
    FPendingLibrary: TDeckLibrary;
    procedure RunCommand(var Context: TCommandContext; const Handler: TCommandHandler;
      OutputLock: THandle = -1);
    procedure RestoreLibrary(var Context: TCommandContext; const Handler: TCommandHandler);
    procedure RunBuild(const Build: TBuildRequest; const Expansion: string; OutputLock: THandle);
  public
    constructor Create(const LibraryPath: string; Interactive: Boolean; Output: TScuOutput);
    destructor Destroy; override;
    procedure Execute(Command: TScuCommand);
    function RecoverPendingLibrary: string;
    property PendingLibrary: TDeckLibrary read FPendingLibrary;
  end;

implementation

uses
  Classes, SysUtils, BaseUnix, FPJSON, ScuAudit, ScuBuild, ScuCodec, ScuCommandRegistry,
  ScuErrors, ScuFiles, ScuLocks, ScuOutputLock, ScuRecovery, ScuSignals, ScuSQLite;

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

procedure TScuExecutor.RunBuild(const Build: TBuildRequest; const Expansion: string; OutputLock: THandle);
var
  Failure: string;

  procedure RecordOutcome(Cancelled: Boolean);
  var
    Lock: TLibraryLock;
    Audit: TAuditLog;
    Database: TSQLiteLibrary;
    Message: string;
  begin
    try
      // Record the build outcome even when the build was interrupted.
      Lock := TLibraryLock.Create(FLibraryPath + '.lock', @SessionEnding);
      try
        Database := TSQLiteLibrary.OpenWrite(FLibraryPath);
        try
          Audit := TAuditLog.Create(Database, Expansion);
          try
            if (Failure = '') and (Build.Checkpoint.Version <> '') then
              Database.Checkpoints.SaveExpansionCheckpoint(Build.Checkpoint.Version, Build.OutputPath,
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
  const Detail: string; PendingSave: Boolean);
var
  Contents: TJSONObject;
begin
  Contents := nil;
  try
    if Assigned(Context.LibraryFile) then
      Contents := Context.LibraryFile.SavedContents(Context.StagedSave);
    Audit.EndCommand(True, Detail, Context.Snapshots, PendingSave, Contents);
  finally
    Contents.Free;
  end;
end;

procedure TScuExecutor.RestoreLibrary(var Context: TCommandContext; const Handler: TCommandHandler);
var
  Lock: TLibraryLock;
  TempDir, TempFile, Detail: string;
  Document: TJSONObject;
  Audit: TAuditLog;
  Stream: TFileStream;
begin
  if Assigned(FPendingLibrary) then
    raise EScuError.Create('Finish pending edits before recovering a library.');
  Context.LibraryPath := CanonicalFile(Context.LibraryPath);
  Lock := TLibraryLock.Create(Context.LibraryPath + '.lock', @SessionEnding, @CheckSessionInterrupt);
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
          Context.LibraryFile := TDeckLibrary.CreateRecovered(Document);
          try
            Audit := TAuditLog.Create(Context.Database);
            try
              Audit.BeginCommand(Context.Command);
              Detail := Handler.Run(Context);
              RecordSuccessfulCommand(Audit, Context, Detail, False);
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
          AtomicWrite(Context.LibraryPath, Stream, False);
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
      raise EScuError.Create('The output directory must already exist.');
    Context.OutputDirectory := CanonicalDirectory(Context.OutputDirectory);
    Lock := TOutputDirectoryLock.Create(Context.OutputDirectory, Handler.ReuseBuildLock);
    try
      RunCommand(Context, Handler, Lock.BuildHandle);
    finally
      Lock.Free;
    end;
  end
  else
    RunCommand(Context, Handler);
end;

procedure TScuExecutor.RunCommand(var Context: TCommandContext; const Handler: TCommandHandler;
  OutputLock: THandle);
var
  Lock: TLibraryLock;
  Audit: TAuditLog;
  Command: TScuCommand;
  LibraryExists, Initializing, Committed, PendingSave: Boolean;
  Checkpoint, Detail, Expansion: string;

  procedure RaiseMissingLibrary;
  begin
    raise EScuError.CreateFmt('Library "%s" does not exist. Use initialize_library to create it.',
      [FLibraryPath]);
  end;

begin
  Command := Context.Command;
  if Command.SessionExit and not FInteractive then
    raise EScuError.CreateFmt('%s is only available in interactive mode.', [Command.Name]);
  FLibraryPath := CanonicalFile(FLibraryPath);
  Context.LibraryPath := FLibraryPath;
  Initializing := Handler.Mode = cmInitialize;
  Audit := nil;
  Committed := False;
  Lock := TLibraryLock.Create(FLibraryPath + '.lock', @SessionEnding, @CheckSessionInterrupt);
  try
    Checkpoint := Command.Option('head');
    if Command.HasOption('head') and not IsHexDigest(Checkpoint, 64) then
      raise EScuError.Create('Expected a lowercase SHA-256 audit head.');
    if not RegularFileExists(FLibraryPath) and not Initializing then
      RaiseMissingLibrary;
    if Initializing then
      Context.Database := TSQLiteLibrary.OpenForInitialization(FLibraryPath)
    else if Handler.Mode in [cmHistory, cmVerifyAudit] then
      Context.Database := TSQLiteLibrary.OpenRead(FLibraryPath)
    else
      Context.Database := TSQLiteLibrary.OpenWrite(FLibraryPath);
    LibraryExists := Context.Database.Revisions.StateKey <> '';
    if Handler.Mode = cmHistory then
    begin
      if not LibraryExists then
        RaiseMissingLibrary;
      Handler.Run(Context);
      Exit;
    end;
    Audit := TAuditLog.Create(Context.Database, Checkpoint, Handler.Mode = cmVerifyAudit);
    if (LibraryExists or Assigned(FPendingLibrary)) and (Audit.Records = 0) then
      raise EScuError.Create('The audit log for the existing library is empty.');
    if Handler.Mode = cmVerifyAudit then
    begin
      if Audit.SavedHeaderDigest <> '' then
      begin
        if not LibraryExists then
          RaiseMissingLibrary;
        Context.LibraryFile := TDeckLibrary.Create(FLibraryPath, '', Context.Database);
        Audit.VerifyContents(Context.LibraryFile);
      end;
      FOutput.WriteLine(Format('records=%d interrupted=%d head=%s', [Audit.Records, Audit.Interrupted, Audit.Head]));
      Exit;
    end;
    if Assigned(Handler.Prepare) and LibraryExists and not Assigned(FPendingLibrary) and
      Handler.Prepare(Context) then
    begin
      // Output files cannot roll back with SQLite. Commit checkpoint
      // invalidation before the handler writes any files.
      Context.Database.Commit;
      Context.Database.BeginTransaction;
      FreeAndNil(Audit);
      Audit := TAuditLog.Create(Context.Database, Checkpoint);
    end;
    Audit.BeginCommand(Command);
    Context.Database.Execute('SAVEPOINT scu_operation');
    try
      if Initializing then
      begin
        if LibraryExists or Audit.Initialized then
          raise EScuError.Create('A library already exists or was previously initialized here.');
        Context.LibraryFile := TDeckLibrary.Create(FLibraryPath, '1.0', Context.Database);
      end
      else
      begin
        Context.LibraryFile := FPendingLibrary;
        if not Assigned(Context.LibraryFile) then
        begin
          if not LibraryExists then
            RaiseMissingLibrary;
          Context.LibraryFile := TDeckLibrary.Create(FLibraryPath, '', Context.Database);
        end;
      end;
      if not Assigned(Handler.Run) then
        raise EScuError.CreateFmt('No implementation for command "%s".', [Command.Name]);
      Detail := Handler.Run(Context);
      if not Initializing then
      begin
        if not SessionEnding then
          FOutput.Flush;
        if not FInteractive then
          Context.LibraryFile.Save(Context.Database, Context.StagedSave);
      end;
    except
      on E: Exception do
      begin
        if Initializing and not LibraryExists then
          raise;
        try
          Context.Database.Execute('ROLLBACK TO scu_operation');
          Audit.EndCommand(False, E.Message, Context.Snapshots, Assigned(FPendingLibrary));
          Context.Database.Commit;
        except
          on AuditError: ECommandCancelled do raise;
          on AuditError: Exception do
          begin
            if E is ECommandCancelled then
              WriteDiagnostic('scu: Could not save the audit outcome: ' + AuditError.Message)
            else
              raise EScuError.CreateFmt('%s Also could not save the audit outcome: %s',
                [E.Message, AuditError.Message]);
          end;
        end;
        raise;
      end;
    end;
    try
      PendingSave := FInteractive and Context.LibraryFile.Modified and not Initializing and
        not Handler.SavesLibrary;
      RecordSuccessfulCommand(Audit, Context, Detail, PendingSave);
      Context.Database.Commit;
      Committed := True;
      if Context.Build.Command <> '' then
        Expansion := Audit.Head;
    except
      on E: ECommandCancelled do raise;
      on E: Exception do
        raise EScuError.Create('Could not commit the command outcome: ' + E.Message);
    end;
    if (Detail <> '') and not SessionEnding then
      FOutput.WriteLine(Detail);
    if Assigned(Handler.ReportCommitted) then
      Handler.ReportCommitted(Context);
  finally
    if Assigned(Context.LibraryFile) then
    begin
      if Committed then
        Context.LibraryFile.AcceptSave(Context.StagedSave);
      if FInteractive and Context.LibraryFile.Modified and not Initializing then
        FPendingLibrary := Context.LibraryFile
      else
      begin
        if Context.LibraryFile = FPendingLibrary then
          FPendingLibrary := nil;
        Context.LibraryFile.Free;
      end;
    end;
    Audit.Free;
    Context.Database.Free;
    Lock.Free;
  end;
  if Context.Build.Command <> '' then
  begin
    FOutput.Flush;
    RunBuild(Context.Build, Expansion, OutputLock);
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
    on E: ECommandCancelled do raise;
    on E: Exception do
    begin
      Result := IncludeTrailingPathDelimiter(MakeTempDirectory('scu-recovery')) + 'library.json';
      AtomicWrite(Result, Data, False);
    end;
  end;
end;

end.
