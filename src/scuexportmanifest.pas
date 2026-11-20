unit ScuExportManifest;

{$mode objfpc}{$H+}

interface

uses
  Classes, Contnrs, ScuExportTypes, ScuLocks, ScuExportNames;

const
  ExportManifestName = '.scu-exports.json';

type
  TExportMode = ScuExportTypes.TExportMode;
  TExportRecord = ScuExportTypes.TExportRecord;

  TExportManifest = class
  private
    FPath, FStageDirectory: string;
    FStageLock: TFileLock;
    FFiles: TFPHashObjectList;
    FRemovedCount: Integer;
    FPending, FPlanned: TObjectList;
    FPlanNames: TFPHashList;
    FFileKeys: TExportFileKeys;
    function FileKey(const Value: RawByteString): string;
    procedure ValidatePlanPath(const LibraryPath, OutputPath: string);
    function GetCount: Integer;
    function GetEntry(Index: Integer): TExportRecord;
    procedure Install(const Entry: TExportRecord);
    procedure RemoveRecord(const FileName: RawByteString);
    procedure CompactRecords;
    procedure Save(IncludePlan: Boolean = False);
    procedure Load;
  public
    constructor Create(const Directory: string);
    destructor Destroy; override;
    // Recovery is explicit and must run while the caller holds the directory lock.
    procedure Recover;
    function TracksFile(const LibraryPath, FileName: string): Boolean;
    function IsGeneratedFile(const FileName: RawByteString): Boolean;
    procedure PlanExport(const LibraryPath, OutputPath, Deck, Version, DeckVersion: string;
      Mode: TExportMode; const ExpansionUTC, Prefix: string; const Bytes: RawByteString;
      ReplaceExisting: Boolean = False);
    procedure PlanDelete(const LibraryPath, OutputPath, Version: string; ReplaceExisting: Boolean = False);
    procedure Observe(const Entry: TExportRecord; Removed: Boolean);
    procedure SaveObservations;
    function Publish(out Rows: TExportResults): Integer;
    function WriteExport(const LibraryPath, OutputPath, Deck, Version, DeckVersion: string;
      Mode: TExportMode; const ExpansionUTC, Prefix: string; const Bytes: RawByteString; ReplaceExisting: Boolean = False): Boolean;
    property Count: Integer read GetCount;
    property Entries[Index: Integer]: TExportRecord read GetEntry; default;
  end;

implementation

uses
  SysUtils, FPJSON, DateUtils, ScuClock, ScuCodec, ScuErrors, ScuFiles, ScuJSON,
  ScuSignals, ScuLibraryNames, ScuLibraryModel, ScuVersions, ScuCleanupFiles, ScuLibraryPaths
  {$IFDEF WINDOWS}, Windows, ScuPlatformPathsWindows{$ENDIF};

type
  TExportItem = class
    Data: TExportRecord;
    Removed: Boolean;
  end;
  TExportPlan = class(TExportItem)
    PreviousHash, StageFile: string;
    ReplaceExisting, DeleteOutput: Boolean;
  end;

function ByteKey(const Value: RawByteString): string;
const
  Digits = '0123456789abcdef';
var
  Index: SizeInt;
begin
  SetLength(Result, Length(Value) * 2);
  for Index := 1 to Length(Value) do
  begin
    Result[Index * 2 - 1] := Digits[(Byte(Value[Index]) shr 4) + 1];
    Result[Index * 2] := Digits[(Byte(Value[Index]) and 15) + 1];
  end;
end;

// Cleanup must retain the original failure/cancellation and must handle the
// same Unicode/extended paths as the owning export operation.
procedure DeleteStageFile(const Path: string);
begin
  {$IFDEF WINDOWS}DeleteFileW(PWideChar(NativeFilePath(Path)));
  {$ELSE}DeleteFile(Path);{$ENDIF}
end;
procedure DeleteStageDirectory(const Path: string);
begin
  {$IFDEF WINDOWS}RemoveDirectoryW(PWideChar(NativeFilePath(Path)));
  {$ELSE}RemoveDir(Path);{$ENDIF}
end;

function TExportManifest.FileKey(const Value: RawByteString): string;
begin
  Result := FFileKeys.Key(Value);
end;

procedure TExportManifest.ValidatePlanPath(const LibraryPath, OutputPath: string);
{$IFDEF WINDOWS}var Canonical: string;{$ENDIF}
begin
  {$IFDEF WINDOWS}
  ValidateExportPath(OutputPath);
  Canonical := CanonicalFile(OutputPath);
  if not SameExportLibrary(ExtractFileDir(Canonical), ExtractFileDir(FPath)) then
    raise EScuError.Create('Export target is outside its manifest directory.');
  if IsLibraryStoragePath(Canonical, CanonicalFile(LibraryPath)) or
    IsSQLiteFile(Canonical) or IsSQLiteCompanion(Canonical) then
    raise EScuError.Create('Export target is protected SQLite storage.');
  {$ENDIF}
end;

function DecodeKey(const Value, Context: string): RawByteString;
var
  Index, Number: Integer;
begin
  if Odd(Length(Value)) then
    raise EScuError.Create(Context + ': invalid filename byte encoding.');
  SetLength(Result, Length(Value) div 2);
  for Index := 1 to Length(Result) do
  begin
    if not TryStrToInt('$' + Copy(Value, Index * 2 - 1, 2), Number) then
      raise EScuError.Create(Context + ': invalid filename byte encoding.');
    Result[Index] := AnsiChar(Number);
  end;
  SetCodePage(Result, CP_UTF8, False);
end;

function RawField(Entry: TJSONObject; const Name, Context: string): RawByteString;
begin
  Result := UTF8Encode(Field(Entry, Name, jtString, Context).AsUnicodeString);
  SetCodePage(Result, CP_UTF8, False);
end;

function ReadRecord(Entry: TJSONObject; const Context: string): TExportRecord;
var
  Name, Mode, Stamp: string;
  Time: TDateTime;
begin
  Result := Default(TExportRecord);
  if Assigned(Entry.Find('file_bytes')) then
    Result.FileName := DecodeKey(Field(Entry, 'file_bytes', jtString, Context).AsString, Context)
  else
    Result.FileName := RawField(Entry, 'file', Context);
  Name := Result.FileName;
  try ValidateExportFileName(Name);
  except on E: EScuError do raise EScuError.Create(Context + ': ' + E.Message); end;
  if (Name = '') or (Name = '.') or (Name = '..') or (Pos(#0, Name) > 0) or
    (ExtractFileName(Name) <> Name) or (Name = ExportManifestName) then
    raise EScuError.Create(Context + ': invalid or duplicate file name.');
  if Assigned(Entry.Find('library_bytes')) then
    Result.LibraryPath := DecodeKey(Field(Entry, 'library_bytes', jtString, Context).AsString, Context)
  else
    Result.LibraryPath := RawField(Entry, 'library', Context);
  Result.Deck := DeckName(RawField(Entry, 'deck_name', Context));
  Result.LibraryVersion := RawField(Entry, 'library_version', Context);
  Result.DeckVersion := RawField(Entry, 'deck_version', Context);
  Result.SHA256 := RawField(Entry, 'sha256', Context);
  Result.ExpansionUTC := RawField(Entry, 'expansion_utc', Context);
  Result.CommentPrefix := RawField(Entry, 'comment_prefix', Context);
  if (Result.LibraryPath = '') or (Pos(#0, Result.LibraryPath) > 0) then
    raise EScuError.Create(Context + ': missing library path.');
  if (Result.LibraryVersion = '') or (Result.DeckVersion = '') then
    raise EScuError.Create(Context + ': missing version.');
  if not IsHexDigest(Result.SHA256, 64) then
    raise EScuError.Create(Context + ': invalid output checksum.');
  Mode := RawField(Entry, 'mode', Context);
  if Mode = 'expand' then Result.Mode := emExpand
  else if Mode = 'extract' then Result.Mode := emExtract
  else raise EScuError.Create(Context + ': invalid export mode.');
  Stamp := Result.ExpansionUTC;
  if (Result.Mode = emExpand) and
    (not TryISO8601ToDate(Stamp, Time) or (UtcTimestamp(Time) <> Stamp)) then
    raise EScuError.Create(Context + ': invalid expansion timestamp.');
  if Result.CommentPrefix <> '' then ValidateCommentPrefix(Result.CommentPrefix);
  if Assigned(Entry.Find('interrupted_export')) then
    Result.Interrupted := Field(Entry, 'interrupted_export', jtBoolean, Context).AsBoolean;
end;

function RecordJSON(const Entry: TExportRecord): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    // The hex identities survive every locale and arbitrary Unix filename bytes.
    Result.Add('file', UTF8Decode(Entry.FileName));
    Result.Add('file_bytes', ByteKey(Entry.FileName));
    Result.Add('library', UTF8Decode(Entry.LibraryPath));
    Result.Add('library_bytes', ByteKey(Entry.LibraryPath));
    Result.Add('deck_name', Entry.Deck);
    Result.Add('library_version', Entry.LibraryVersion);
    Result.Add('deck_version', Entry.DeckVersion);
    Result.Add('mode', ExportModeName(Entry.Mode));
    Result.Add('expansion_utc', Entry.ExpansionUTC);
    Result.Add('comment_prefix', UTF8Decode(Entry.CommentPrefix));
    Result.Add('sha256', Entry.SHA256);
    if Entry.Interrupted then Result.Add('interrupted_export', True);
  except
    Result.Free;
    raise;
  end;
end;

constructor TExportManifest.Create(const Directory: string);
begin
  inherited Create;
  FPath := IncludeTrailingPathDelimiter(CanonicalDirectory(Directory)) + ExportManifestName;
  FFiles := TFPHashObjectList.Create(True);
  FPending := TObjectList.Create(True);
  FPlanned := TObjectList.Create(True);
  FPlanNames := TFPHashList.Create;
  FFileKeys := TExportFileKeys.Create;
  Load;
end;

destructor TExportManifest.Destroy;
var
  Index: Integer;
begin
  if Assigned(FPlanned) then
    for Index := 0 to FPlanned.Count - 1 do
      if TExportPlan(FPlanned[Index]).StageFile <> '' then
        DeleteStageFile(TExportPlan(FPlanned[Index]).StageFile);
  if FStageDirectory <> '' then
  begin
    {$IFDEF WINDOWS}FreeAndNil(FStageLock);{$ENDIF}
    DeleteStageFile(FStageDirectory + '/.owner');
    FreeAndNil(FStageLock);
    DeleteStageDirectory(FStageDirectory);
  end;
  FPlanNames.Free;
  FPlanned.Free;
  FPending.Free;
  FFiles.Free;
  FFileKeys.Free;
  inherited Destroy;
end;

procedure TExportManifest.Load;
var
  Document, Journal, ObjectEntry: TJSONObject;
  Files, PendingItems: TJSONArray;
  Index: Integer;
  Entry: TExportRecord;
  Plan: TExportPlan;
  Context, Previous: string;

  procedure LoadPending(Item: TJSONObject);
  begin
    Entry := ReadRecord(TJSONObject(Field(Item, 'entry', jtObject, Context)), Context);
    Previous := Field(Item, 'previous_sha256', jtString, Context).AsString;
    if (Previous <> '') and not IsHexDigest(Previous, 64) then
      raise EScuError.Create(Context + ': invalid previous output checksum.');
    if FPlanNames.Find(FileKey(Entry.FileName)) <> nil then
      raise EScuError.Create(Context + ': duplicate pending file name.');
    Plan := TExportPlan.Create;
    Plan.Data := Entry;
    Plan.PreviousHash := Previous;
    if Assigned(Item.Find('delete')) then
      Plan.DeleteOutput := Field(Item, 'delete', jtBoolean, Context).AsBoolean;
    FPending.Add(Plan);
    FPlanNames.Add(FileKey(Entry.FileName), Plan);
  end;

begin
  if not RegularFileExists(FPath) then Exit;
  Context := 'Export manifest "' + FPath + '"';
  Document := nil;
  try
    try
      Document := ParseObject(ReadBytes(FPath, MaxDeckSize), Context);
      if not (IntegerField(Document, 'format', Context) in [1, 2]) then
        raise EScuError.Create(Context + ': unsupported format.');
      Files := TJSONArray(Field(Document, 'files', jtArray, Context));
      for Index := 0 to Files.Count - 1 do
      begin
        CheckSessionInterrupt;
        if not (Files[Index] is TJSONObject) then
          raise EScuError.Create(Context + ': expected a file record.');
        Entry := ReadRecord(TJSONObject(Files[Index]), Context);
        if Assigned(FFiles.Find(FileKey(Entry.FileName))) then
          raise EScuError.Create(Context + ': invalid or duplicate file name.');
        Install(Entry);
      end;
      if Assigned(Document.Find('pending')) then
      begin
        Journal := TJSONObject(Field(Document, 'pending', jtObject, Context));
        if Assigned(Journal.Find('entries')) then
        begin
          PendingItems := TJSONArray(Field(Journal, 'entries', jtArray, Context));
          for Index := 0 to PendingItems.Count - 1 do
          begin
            if not (PendingItems[Index] is TJSONObject) then
              raise EScuError.Create(Context + ': expected a pending export record.');
            ObjectEntry := TJSONObject(PendingItems[Index]);
            LoadPending(ObjectEntry);
          end;
        end
        else LoadPending(Journal); // Earlier per-file journal format.
      end;
    except
      on E: ECommandCancelled do raise;
      on E: EScuError do
        raise EScuError.Create(E.Message + ' Restore a manifest backup, or move the manifest aside to reset tracking; existing outputs will then be untracked.');
    end;
  finally
    Document.Free;
  end;
end;

procedure TExportManifest.Install(const Entry: TExportRecord);
var
  Item: TExportItem;
begin
  Item := TExportItem(FFiles.Find(FileKey(Entry.FileName)));
  if not Assigned(Item) then
  begin
    Item := TExportItem.Create;
    FFiles.Add(FileKey(Entry.FileName), Item);
  end;
  if Item.Removed then Dec(FRemovedCount);
  Item.Removed := False;
  Item.Data := Entry;
end;

procedure TExportManifest.RemoveRecord(const FileName: RawByteString);
var Item: TExportItem;
begin
  Item := TExportItem(FFiles.Find(FileKey(FileName)));
  if Assigned(Item) and not Item.Removed then
  begin
    Item.Removed := True;
    Inc(FRemovedCount);
  end;
end;

procedure TExportManifest.CompactRecords;
var
  Retained: TFPHashObjectList;
  Index: Integer;
  Item: TExportItem;
begin
  if FRemovedCount = 0 then Exit;
  Retained := TFPHashObjectList.Create(False);
  try
    for Index := 0 to FFiles.Count - 1 do
    begin
      Item := TExportItem(FFiles[Index]);
      if not Item.Removed then Retained.Add(FFiles.NameOfIndex(Index), Item);
    end;
    FFiles.OwnsObjects := False;
    for Index := 0 to FFiles.Count - 1 do
      if TExportItem(FFiles[Index]).Removed then TExportItem(FFiles[Index]).Free;
    FFiles.Free;
    FFiles := Retained;
    FFiles.OwnsObjects := True;
    Retained := nil;
    FRemovedCount := 0;
  finally
    Retained.Free;
  end;
end;

procedure TExportManifest.Save(IncludePlan: Boolean);
var
  Document, Journal, Item: TJSONObject;
  Files, Plans: TJSONArray;
  Index: Integer;
  Plan: TExportPlan;
begin
  Document := TJSONObject.Create;
  try
    Document.Add('format', 2);
    Files := TJSONArray.Create;
    Document.Add('files', Files);
    for Index := 0 to Count - 1 do Files.Add(RecordJSON(Entries[Index]));
    if IncludePlan then
    begin
      Journal := TJSONObject.Create;
      Document.Add('pending', Journal);
      Plans := TJSONArray.Create;
      Journal.Add('entries', Plans);
      for Index := 0 to FPlanned.Count - 1 do
      begin
        Plan := TExportPlan(FPlanned[Index]);
        Item := TJSONObject.Create;
        Plans.Add(Item);
        Item.Add('entry', RecordJSON(Plan.Data));
        Item.Add('previous_sha256', Plan.PreviousHash);
        if Plan.DeleteOutput then Item.Add('delete', True);
      end;
    end;
    AtomicWrite(FPath, RawByteString(Document.AsJSON) + LineEnding);
  finally
    Document.Free;
  end;
end;

procedure TExportManifest.Recover;
var
  Index: Integer;
  Plan: TExportPlan;
  Actual, Path: string;
begin
  CleanupStaleAtomicFiles(ExtractFileDir(FPath));
  if FPending.Count = 0 then Exit;
  for Index := 0 to FPending.Count - 1 do
  begin
    CheckSessionInterrupt;
    Plan := TExportPlan(FPending[Index]);
    Path := IncludeTrailingPathDelimiter(ExtractFileDir(FPath)) + Plan.Data.FileName;
    CheckExportTarget(Path);
    Actual := '';
    if RegularFileExists(Path) then Actual := AuditSHA256(ReadBytes(Path, MaxDeckSize));
    if Plan.DeleteOutput and (Actual = '') then
    begin
      RemoveRecord(Plan.Data.FileName);
    end
    else if not Plan.DeleteOutput and (Actual = Plan.Data.SHA256) then Install(Plan.Data)
    else if Actual <> Plan.PreviousHash then
    begin
      Plan.Data.Interrupted := True;
      Install(Plan.Data);
    end;
  end;
  CompactRecords;
  Save;
  FPlanNames.Clear;
  FPending.Clear;
end;

function TExportManifest.TracksFile(const LibraryPath, FileName: string): Boolean;
var Item: TExportItem;
begin
  Item := TExportItem(FFiles.Find(FileKey(FileName)));
  Result := Assigned(Item) and SameExportLibrary(Item.Data.LibraryPath, CanonicalFile(LibraryPath));
end;

function TExportManifest.IsGeneratedFile(const FileName: RawByteString): Boolean;
var Item: TExportItem;
begin
  Item := TExportItem(FFiles.Find(FileKey(FileName)));
  if Assigned(Item) and (Item.Data.Mode = emExpand) then Exit(True);
  Item := TExportItem(FPlanNames.Find(FileKey(FileName)));
  Result := Assigned(Item) and (Item.Data.Mode = emExpand);
end;

procedure TExportManifest.Observe(const Entry: TExportRecord; Removed: Boolean);
var Path: string; Existing: TExportItem;
begin
  ValidateSourceFileName(Entry.FileName);
  Path := IncludeTrailingPathDelimiter(ExtractFileDir(FPath)) + Entry.FileName;
  CheckExportTarget(Path);
  // Observations are hints. A changed, unreadable, non-regular or oversized
  // working file must not block other observations or later commands.
  try
    if Removed then
    begin
      Existing := TExportItem(FFiles.Find(FileKey(Entry.FileName)));
      if not RegularFileExists(Path) and Assigned(Existing) and
        SameExportLibrary(Existing.Data.LibraryPath, Entry.LibraryPath) and (Existing.Data.Mode = emExtract) then
        RemoveRecord(Entry.FileName);
    end
    else if RegularFileExists(Path) and (AuditSHA256(ReadBytes(Path, MaxDeckSize, [rbNoFollow])) = Entry.SHA256) then
      Install(Entry);
  except
    on E: EScuError do Exit;
  end;
end;

procedure TExportManifest.SaveObservations;
begin
  CompactRecords;
  Save;
end;

procedure TExportManifest.PlanExport(const LibraryPath, OutputPath, Deck, Version, DeckVersion: string;
  Mode: TExportMode; const ExpansionUTC, Prefix: string; const Bytes: RawByteString;
  ReplaceExisting: Boolean);
var
  Plan: TExportPlan;
  Existing: TExportItem;
  Name, Previous, CanonicalLibrary: string;
  Stream: TFileStream;
begin
  if FPending.Count <> 0 then
    raise EScuError.Create('Recover pending exports before planning another export.');
  ValidatePlanPath(LibraryPath, OutputPath);
  Name := ExtractFileName(OutputPath);
  ValidateExportFileName(Name);
  CheckExportTarget(OutputPath);
  Previous := '';
  if RegularFileExists(OutputPath) then Previous := AuditSHA256(ReadBytes(OutputPath, MaxDeckSize));
  CanonicalLibrary := CanonicalFile(LibraryPath);
  Existing := TExportItem(FFiles.Find(FileKey(Name)));
  if (Previous <> '') and (Previous <> AuditSHA256(Bytes)) and not ReplaceExisting and
    (not Assigned(Existing) or (Existing.Data.SHA256 <> Previous) or Existing.Data.Interrupted or
      (not SameExportLibrary(Existing.Data.LibraryPath, CanonicalLibrary))) then
    raise EScuError.Create('Refusing to overwrite untracked or edited output "' + OutputPath + '". Use overwrite=yes to replace it explicitly.');
  if FPlanNames.Find(FileKey(Name)) <> nil then
    raise EScuError.Create('Duplicate output path in export batch: "' + OutputPath + '".');
  if FStageDirectory = '' then
  begin
    FStageDirectory := MakeStagingDirectory(ExtractFileDir(FPath));
    FStageLock := TFileLock.Create(FStageDirectory + '/.owner');
  end;
  Plan := TExportPlan.Create;
  FPlanned.Add(Plan);
  FPlanNames.Add(FileKey(Name), Plan);
  Plan.Data.FileName := Name;
  SetCodePage(Plan.Data.FileName, CP_UTF8, False);
  Plan.Data.LibraryPath := CanonicalLibrary;
  SetCodePage(Plan.Data.LibraryPath, CP_UTF8, False);
  Plan.Data.Deck := Deck;
  Plan.Data.LibraryVersion := Version;
  Plan.Data.DeckVersion := DeckVersion;
  Plan.Data.Mode := Mode;
  Plan.Data.ExpansionUTC := ExpansionUTC;
  Plan.Data.CommentPrefix := Prefix;
  Plan.Data.SHA256 := AuditSHA256(Bytes);
  Plan.PreviousHash := Previous;
  Plan.ReplaceExisting := ReplaceExisting;
  Plan.StageFile := IncludeTrailingPathDelimiter(FStageDirectory) + IntToStr(FPlanned.Count);
  Stream := TFileStream.Create(Plan.StageFile, fmCreate);
  try
    if Bytes <> '' then Stream.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    Stream.Free;
  end;
end;

procedure TExportManifest.PlanDelete(const LibraryPath, OutputPath, Version: string; ReplaceExisting: Boolean);
var
  Plan: TExportPlan;
  Existing: TExportItem;
  Name, Previous: string;
begin
  if FPending.Count <> 0 then raise EScuError.Create('Recover pending exports before planning cleanup.');
  ValidatePlanPath(LibraryPath, OutputPath);
  Name := ExtractFileName(OutputPath);
  ValidateExportFileName(Name);
  CheckExportTarget(OutputPath);
  if (Name = '') or (Name = ExportManifestName) or (Pos(#0, Name) > 0) then
    raise EScuError.Create('Invalid release cleanup filename.');
  if FPlanNames.Find(FileKey(Name)) <> nil then
    raise EScuError.Create('Duplicate output path in release cleanup.');
  Previous := '';
  if RegularFileExists(OutputPath) then Previous := AuditSHA256(ReadBytes(OutputPath, MaxDeckSize));
  Existing := TExportItem(FFiles.Find(FileKey(Name)));
  if (Previous <> '') and not ReplaceExisting and
    (not Assigned(Existing) or (not SameExportLibrary(Existing.Data.LibraryPath, CanonicalFile(LibraryPath)))) then
    raise EScuError.Create('Refusing to remove untracked release file "' + OutputPath + '". Use overwrite=yes to remove it explicitly.');
  if Assigned(Existing) and not ReplaceExisting and (Previous <> '') and
    ((Existing.Data.SHA256 <> Previous) or (not SameExportLibrary(Existing.Data.LibraryPath, CanonicalFile(LibraryPath)))) then
    raise EScuError.Create('Refusing to remove edited release output "' + OutputPath + '". Use overwrite=yes to remove it explicitly.');
  Plan := TExportPlan.Create;
  FPlanned.Add(Plan);
  FPlanNames.Add(FileKey(Name), Plan);
  if Assigned(Existing) then Plan.Data := Existing.Data
  else
  begin
    Plan.Data.FileName := Name;
    Plan.Data.LibraryPath := CanonicalFile(LibraryPath);
    Plan.Data.Deck := 'obsolete-file';
    Plan.Data.LibraryVersion := Version;
    Plan.Data.DeckVersion := Version + '-0.000';
    Plan.Data.Mode := emExpand;
    Plan.Data.ExpansionUTC := UtcTimestamp(UtcNow);
    Plan.Data.SHA256 := AuditSHA256('');
  end;
  Plan.PreviousHash := Previous;
  Plan.DeleteOutput := True;
  Plan.ReplaceExisting := ReplaceExisting;
end;

function TExportManifest.Publish(out Rows: TExportResults): Integer;
var
  Index, RowCount: Integer;
  Plan, RecoveryPlan: TExportPlan;
  Path, Actual: string;
begin
  Result := 0;
  RowCount := 0;
  SetLength(Rows, FPlanned.Count);
  if FPlanned.Count = 0 then Exit;
  if FPending.Count <> 0 then raise EScuError.Create('Another export batch still needs recovery.');
  Save(True);
  for Index := 0 to FPlanned.Count - 1 do
  begin
    Plan := TExportPlan(FPlanned[Index]);
    RecoveryPlan := TExportPlan.Create;
    RecoveryPlan.Data := Plan.Data;
    RecoveryPlan.PreviousHash := Plan.PreviousHash;
    RecoveryPlan.DeleteOutput := Plan.DeleteOutput;
    FPending.Add(RecoveryPlan);
  end;
  for Index := 0 to FPlanned.Count - 1 do
  begin
    CheckSessionInterrupt;
    Plan := TExportPlan(FPlanned[Index]);
    Path := IncludeTrailingPathDelimiter(ExtractFileDir(FPath)) + Plan.Data.FileName;
    CheckExportTarget(Path);
    Actual := '';
    if RegularFileExists(Path) then Actual := AuditSHA256(ReadBytes(Path, MaxDeckSize));
    if not Plan.ReplaceExisting and (Actual <> Plan.PreviousHash) then
      raise EScuError.Create('Output changed after the export was planned: "' + Path + '". No replacement was made for this file.');
    if Plan.DeleteOutput then
    begin
      if Actual <> '' then RemoveObsoleteReleaseFile(Path);
      SyncParent(Path);
      RemoveRecord(Plan.Data.FileName);
    end
    else
    begin
      Rows[RowCount].Deck := Plan.Data.Deck;
      Rows[RowCount].DeckVersion := Plan.Data.DeckVersion;
      if Actual = Plan.Data.SHA256 then
        Rows[RowCount].Status := esUnchanged
      else
      begin
        AtomicWrite(Path, ReadBytes(Plan.StageFile, MaxDeckSize), [awSourceOutput]);
        Inc(Result);
        if Actual = '' then Rows[RowCount].Status := esCreated
        else Rows[RowCount].Status := esReplaced;
      end;
      Inc(RowCount);
      Install(Plan.Data);
    end;
  end;
  CompactRecords;
  Save;
  for Index := 0 to FPlanned.Count - 1 do
    if TExportPlan(FPlanned[Index]).StageFile <> '' then DeleteStageFile(TExportPlan(FPlanned[Index]).StageFile);
  FPending.Clear;
  FPlanNames.Clear;
  FPlanned.Clear;
  SetLength(Rows, RowCount);
end;

function TExportManifest.WriteExport(const LibraryPath, OutputPath, Deck, Version, DeckVersion: string;
  Mode: TExportMode; const ExpansionUTC, Prefix: string; const Bytes: RawByteString; ReplaceExisting: Boolean): Boolean;
var
  Rows: TExportResults;
begin
  PlanExport(LibraryPath, OutputPath, Deck, Version, DeckVersion, Mode, ExpansionUTC, Prefix, Bytes, ReplaceExisting);
  Result := Publish(Rows) <> 0;
end;

function TExportManifest.GetCount: Integer;
begin
  Result := FFiles.Count;
end;

function TExportManifest.GetEntry(Index: Integer): TExportRecord;
begin
  Result := TExportItem(FFiles[Index]).Data;
end;

end.
