unit ScuRecovery;

{$mode objfpc}{$H+}

interface

uses
  ScuCommand;

function RestoreLibrary(const Destination: string; Command: TScuCommand): string;

implementation

uses
  Classes, SysUtils, FPJSON, ScuAudit, ScuIO, ScuJSON, ScuLibrary, ScuSignals, ScuSQLite;

procedure CheckBaseHistory(BaseHeader, RecoveryHeader: TJSONObject);
var
  Saved, Recovered: TJSONArray;
  SavedVersion, RecoveredVersion: TJSONObject;
  Index: Integer;
begin
  Saved := TJSONArray(Field(BaseHeader, 'versions', jtArray));
  Recovered := TJSONArray(Field(RecoveryHeader, 'versions', jtArray));
  if (Saved.Count = 0) or (Saved.Count > Recovered.Count) then
    raise EScuError.Create('The base library version history does not match the recovery file.');
  for Index := 0 to Saved.Count - 1 do
  begin
    if not (Saved.Items[Index] is TJSONObject) or not (Recovered.Items[Index] is TJSONObject) then
      raise EScuError.Create('Invalid recovery version history.');
    SavedVersion := TJSONObject(Saved.Items[Index]);
    RecoveredVersion := TJSONObject(Recovered.Items[Index]);
    if (Field(SavedVersion, 'name', jtString).AsString <> Field(RecoveredVersion, 'name', jtString).AsString) or
      (IntegerField(SavedVersion, 'base_revision') <> IntegerField(RecoveredVersion, 'base_revision')) then
      raise EScuError.Create('The base library version history does not match the recovery file.');
  end;
end;

function CombineRecovery(Recovery: TJSONObject; const BasePath: string): TJSONObject;
var
  Base: TSQLiteLibrary;
  BaseDocument, Header: TJSONObject;
  Pending, Revisions: TJSONArray;
  State: string;
  Count: Int64;
  Index: Integer;
begin
  Count := IntegerField(Recovery, 'base_library_revision');
  if (Count < 0) or (Count > High(Integer)) then
    raise EScuError.Create('Invalid base library revision count.');
  if (BasePath = '') and (Count > 0) then
    raise EScuError.Create('This recovery file requires base_library to identify the saved SQLite snapshot.');
  Header := TJSONObject(Field(Recovery, 'header', jtObject));
  Pending := TJSONArray(Field(Recovery, 'pending_revisions', jtArray));
  Base := nil;
  try
    if BasePath <> '' then
    begin
      if not RegularFileExists(BasePath) then
        raise EScuError.CreateFmt('Base library "%s" does not exist.', [BasePath]);
      Base := TSQLiteLibrary.Create(BasePath, False, True);
      Base.BeginTransaction(True);
      Base.EnsureSchema(False);
      State := Base.StateKey;
      if (State = '') or (Assigned(Recovery.Find('base_library_state')) and
        (Field(Recovery, 'base_library_state', jtString).AsString <> State)) then
        raise EScuError.Create('The base library does not match the saved snapshot in the recovery file.');
      if Count <> Base.RevisionCount then
        raise EScuError.Create('The base library revision count does not match the recovery file.');
      BaseDocument := Base.ReadDocument;
      try
        CheckBaseHistory(TJSONObject(Field(BaseDocument, 'header', jtObject)), Header);
      finally
        BaseDocument.Free;
      end;
    end;
    Result := TJSONObject.Create;
    try
      Result.Add('format', 1);
      Result.Add('header', Header.Clone);
      Revisions := TJSONArray.Create;
      Result.Add('revisions', Revisions);
      for Index := 1 to Count do
      begin
        CheckSessionInterrupt;
        Revisions.Add(Base.ReadRevision(Index));
      end;
      for Index := 0 to Pending.Count - 1 do
        Revisions.Add(Pending.Items[Index].Clone);
    except
      Result.Free;
      raise;
    end;
  finally
    Base.Free;
  end;
end;

function ReadRecovery(const Path, BasePath: string): TJSONObject;
var
  Recovery: TJSONObject;
  FormatValue: TJSONData;
begin
  Recovery := ParseObject(ReadBytes(Path, High(SizeInt)));
  try
    FormatValue := Recovery.Find('format');
    if Assigned(FormatValue) and (FormatValue.JSONType = jtNumber) and
      (IntegerField(Recovery, 'format') = 1) then
    begin
      if BasePath <> '' then
        raise EScuError.Create('A full recovery file already contains the base revisions. Omit base_library.');
      Result := Recovery;
      Recovery := nil;
    end
    else if Assigned(FormatValue) and (FormatValue.JSONType = jtString) and
      (FormatValue.AsString = 'scu-pending-recovery-v1') then
      Result := CombineRecovery(Recovery, BasePath)
    else
      raise EScuError.Create('Unsupported SCU recovery file format.');
  finally
    Recovery.Free;
  end;
end;

function RestoreLibrary(const Destination: string; Command: TScuCommand): string;
var
  Lock: TLibraryLock;
  TempDir, TempFile: string;
  Document, Contents: TJSONObject;
  Database: TSQLiteLibrary;
  LibraryFile: TDeckLibrary;
  Audit: TAuditLog;
  Snapshots: TAuditSnapshots;
  Stream: TFileStream;
begin
  Lock := TLibraryLock.Create(Destination + '.lock', @SessionEnding, @CheckSessionInterrupt);
  try
    if RegularFileExists(Destination) then
      raise EScuError.Create('Choose a new library path for recovery. The destination already exists.');
    Document := ReadRecovery(Command['recovery_file'], Command.Option('base_library'));
    try
      TempDir := MakeTempDirectory('scu-restore');
      TempFile := IncludeTrailingPathDelimiter(TempDir) + 'library.sqlite';
      try
        Database := TSQLiteLibrary.Create(TempFile, True, False);
        try
          Database.BeginTransaction(False);
          Database.EnsureSchema(True);
          LibraryFile := TDeckLibrary.CreateRecovered(Document, Database);
          try
            Audit := TAuditLog.Create(Database);
            try
              Audit.BeginCommand(Command);
              LibraryFile.Save;
              Snapshots := Default(TAuditSnapshots);
              Snapshots.Selected := LibraryFile.CurrentSnapshot;
              Result := Format('Restored %d revision(s) to "%s".', [LibraryFile.Revision, Destination]);
              Contents := LibraryFile.SavedContents;
              try
                Audit.EndCommand(True, Result, Snapshots, False, Contents);
              finally
                Contents.Free;
              end;
              Database.Commit;
            finally
              Audit.Free;
            end;
          finally
            LibraryFile.Free;
          end;
        finally
          Database.Free;
        end;
        CheckSessionInterrupt;
        Stream := TFileStream.Create(TempFile, fmOpenRead);
        try
          AtomicWrite(Destination, Stream, False);
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
end;

end.
