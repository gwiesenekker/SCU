unit ScuLibraryStore;

{$mode objfpc}{$H+}

interface

uses
  Contnrs, FPJSON, ScuLibraryModel, ScuSQLite;

type
  TLibrarySave = record
    StateKey: string;
    FirstRevision: Integer;
  end;

  TLibraryStore = class
  private
    FPath, FSavedState: string;
    FSavedRevisionCount: Integer;
    FMetadata: TJSONObject;
    FHeader: TLibraryHeader;
    FEntries: TObjectList;
    function GetCount: Integer;
    function GetEntry(Index: Integer): TLibraryRevision;
    procedure AddEntry(Entry: TLibraryRevision);
    procedure ReadIndexEntry(const Deck, Number: string; Deleted: Boolean);
    procedure LoadHeader;
    procedure ValidateDeckNumbers;
    function ExportJSON(Database: TSQLiteLibrary): RawByteString;
  public
    constructor CreateNew(const Path, InitialVersion: string);
    constructor Load(const Path: string; Database: TSQLiteLibrary);
    constructor CreateRecovered(var Document: TJSONObject);
    destructor Destroy; override;
    procedure Append(var Payload: TJSONObject);
    procedure RemoveLast;
    // The store owns the returned entry, including its lazily loaded payload.
    function PayloadAt(Index: Integer; Database: TSQLiteLibrary): TLibraryRevision;
    function RevisionDigest(Sequence: Integer; Database: TSQLiteLibrary): string;
    procedure StageSave(Database: TSQLiteLibrary; var Save: TLibrarySave);
    procedure AcceptSave(const Save: TLibrarySave);
    function CreateSavedContents(const Save: TLibrarySave): TJSONObject;
    function ExportRecoveryJSON: RawByteString;
    property Header: TLibraryHeader read FHeader;
    property Count: Integer read GetCount;
    property Entries[Index: Integer]: TLibraryRevision read GetEntry; default;
  end;

implementation

uses
  SysUtils, FGL, ScuCodec, ScuCopyMetadata, ScuErrors, ScuJSON, ScuSignals, ScuVersionNumbers;

type
  TDeckRevisionMap = specialize TFPGMap<string, Integer>;

constructor TLibraryStore.CreateNew(const Path, InitialVersion: string);
begin
  inherited Create;
  FPath := Path;
  FEntries := TObjectList.Create(True);
  FMetadata := NewLibraryMetadata(InitialVersion);
  LoadHeader;
end;

constructor TLibraryStore.Load(const Path: string; Database: TSQLiteLibrary);
begin
  inherited Create;
  FPath := Path;
  FEntries := TObjectList.Create(True);
  FSavedState := Database.Revisions.StateKey;
  FMetadata := Database.Revisions.ReadMetadata;
  Database.Revisions.ReadRevisionIndex(@ReadIndexEntry);
  FSavedRevisionCount := Count;
  LoadHeader;
  ValidateDeckNumbers;
end;

constructor TLibraryStore.CreateRecovered(var Document: TJSONObject);
var
  Revisions: TJSONArray;
  Entry: TJSONObject;
  Index: Integer;
begin
  inherited Create;
  FEntries := TObjectList.Create(True);
  FMetadata := Document;
  Document := nil;
  Field(FMetadata, 'revisions', jtArray);
  Revisions := TJSONArray(FMetadata.Extract('revisions'));
  try
    // Extract from the end to transfer ownership without shifting the array.
    for Index := Revisions.Count - 1 downto 0 do
    begin
      CheckSessionInterrupt;
      if not (Revisions.Items[Index] is TJSONObject) then
        raise EScuError.CreateFmt('Invalid library revision %d.', [Index + 1]);
      Entry := TJSONObject(Revisions.Extract(Index));
      try
        AddEntry(TLibraryRevision.CreatePayload(Entry, Index + 1));
      finally
        Entry.Free;
      end;
    end;
  finally
    Revisions.Free;
  end;
  for Index := 0 to Count div 2 - 1 do
    FEntries.Exchange(Index, Count - Index - 1);
  LoadHeader;
  ValidateDeckNumbers;
  for Index := 0 to Count - 1 do
  begin
    CheckSessionInterrupt;
    Entries[Index].ValidateRecoveredSource(Index + 1);
  end;
end;

destructor TLibraryStore.Destroy;
begin
  FEntries.Free;
  FHeader.Free;
  FMetadata.Free;
  inherited Destroy;
end;

function TLibraryStore.GetCount: Integer;
begin
  Result := FEntries.Count;
end;

function TLibraryStore.GetEntry(Index: Integer): TLibraryRevision;
begin
  Result := TLibraryRevision(FEntries[Index]);
end;

procedure TLibraryStore.ReadIndexEntry(const Deck, Number: string; Deleted: Boolean);
begin
  AddEntry(TLibraryRevision.CreateIndex(Deck, Number, Count + 1, Deleted));
end;

procedure TLibraryStore.AddEntry(Entry: TLibraryRevision);
begin
  try
    FEntries.Add(Entry);
  except
    Entry.Free;
    raise;
  end;
end;

procedure TLibraryStore.LoadHeader;
var LastDeck, Context: string;
begin
  Context := 'Recovered library header';
  if FPath <> '' then Context := 'Library "' + FPath + '" header';
  try
    if IntegerField(FMetadata, 'format') <> 1 then
      raise EScuError.Create('Unsupported library format.');
    LastDeck := '';
    if Count > 0 then
      LastDeck := Entries[Count - 1].Name;
    FHeader := TLibraryHeader.Create(TJSONObject(Field(FMetadata, 'header', jtObject)), Count, LastDeck);
  except
    on E: EScuError do raise EScuError.Create(Context + ': ' + E.Message);
  end;
end;

procedure TLibraryStore.ValidateDeckNumbers;
var
  Seen: TDeckRevisionMap;
  Entry: TLibraryRevision;
  Version, PreviousVersion: string;
  Index, Slot, Previous: Integer;
begin
  Seen := TDeckRevisionMap.Create;
  try
    Seen.Sorted := True;
    PreviousVersion := '';
    for Index := 0 to Count - 1 do
    begin
      Version := Header.Versions.AtRevision(Index + 1);
      if Version <> PreviousVersion then
      begin
        Seen.Clear;
        PreviousVersion := Version;
      end;
      Entry := Entries[Index];
      Slot := Seen.IndexOf(Entry.Name);
      Previous := -1;
      if Slot >= 0 then
        Previous := Seen.Data[Slot];
      if Entry.Number < 0 then
        Entry.SetLegacyNumber(Previous + 1)
      else if (Entry.Number <= Previous) or ((Slot < 0) and (Entry.Number <> 0)) then
        raise EScuError.CreateFmt('Invalid deck revision in library revision %d.', [Index + 1]);
      if Slot >= 0 then
        Seen.Data[Slot] := Entry.Number
      else
        Seen.Add(Entry.Name, Entry.Number);
    end;
  finally
    Seen.Free;
  end;
end;

procedure TLibraryStore.Append(var Payload: TJSONObject);
begin
  AddEntry(TLibraryRevision.CreatePayload(Payload, Count + 1));
end;

procedure TLibraryStore.RemoveLast;
begin
  FEntries.Delete(Count - 1);
end;

function TLibraryStore.PayloadAt(Index: Integer; Database: TSQLiteLibrary): TLibraryRevision;
var
  Payload: TJSONObject;
begin
  Result := Entries[Index];
  if Result.Loaded then
    Exit;
  if not Assigned(Database) then
    raise EScuError.Create('Reading a revision requires an open SQLite transaction.');
  Payload := Database.Revisions.ReadRevision(Index + 1);
  try
    Result.LoadPayload(Payload);
  finally
    Payload.Free;
  end;
end;

function TLibraryStore.RevisionDigest(Sequence: Integer; Database: TSQLiteLibrary): string;
var
  Entry: TLibraryRevision;
  Metadata: TJSONObject;
  Indexed: RawByteString;
begin
  Entry := PayloadAt(Sequence - 1, Database);
  if Entry.CopyMetadataJSON = '' then
  begin
    // Older audit digests cover the original payload. Validate derived metadata separately.
    Indexed := Database.Revisions.ReadRevisionCopyMetadata(Sequence);
    if Indexed <> '' then
    begin
      Metadata := ScanCopyMetadata(Entry.Decode, Entry.CommentPrefix);
      try
        if Metadata.AsJSON <> Indexed then
          raise EScuError.CreateFmt('SQLite COPY metadata does not match revision %d.', [Sequence]);
      finally
        Metadata.Free;
      end;
    end;
  end;
  Result := AuditSHA256(Entry.Serialized);
end;

procedure TLibraryStore.StageSave(Database: TSQLiteLibrary; var Save: TLibrarySave);
var
  Entry: TLibraryRevision;
  Index, SavedCount: Integer;
begin
  if Save.StateKey <> '' then
    Exit;
  CheckSessionInterrupt;
  if not Assigned(Database) then
    raise EScuError.Create('Saving requires an open SQLite transaction.');
  if Database.Revisions.StateKey <> FSavedState then
    raise EScuError.Create('The saved library changed outside this session. Unsaved changes are still in this session.');
  SavedCount := Database.Revisions.RevisionCount;
  if SavedCount <> FSavedRevisionCount then
    raise EScuError.Create('The saved library changed outside this session. Unsaved changes are still in this session.');
  if SavedCount > Count then
    Database.Revisions.RemoveVersionTail(Count, Database.Revisions.ReadCurrentVersion);
  Database.Revisions.SaveMetadata(FMetadata.AsJSON);
  for Index := SavedCount to Count - 1 do
  begin
    Entry := Entries[Index];
    Database.Revisions.AppendRevision(Index + 1, Entry.Name, Header.Versions.AtRevision(Index + 1),
      FormatFixed(Entry.Number, 3), Entry.Serialized, Entry.CopyMetadataJSON, Entry.Deleted);
  end;
  Save.StateKey := Database.Revisions.StateKey;
  if SavedCount > Count then
    Save.FirstRevision := Count + 1
  else
    Save.FirstRevision := SavedCount + 1;
end;

procedure TLibraryStore.AcceptSave(const Save: TLibrarySave);
begin
  FSavedState := Save.StateKey;
  FSavedRevisionCount := Count;
end;

function TLibraryStore.CreateSavedContents(const Save: TLibrarySave): TJSONObject;
var
  Index: Integer;
  Digests: TJSONArray;
begin
  if Save.StateKey = '' then
    Exit(nil);
  Result := TJSONObject.Create;
  try
    Result.Add('header_sha256', Header.Digest);
    Result.Add('revision_count', Count);
    if FSavedRevisionCount > Count then
      Result.Add('removed_revisions', FSavedRevisionCount - Count);
    Result.Add('first_revision', Save.FirstRevision);
    Digests := TJSONArray.Create;
    Result.Add('revision_sha256', Digests);
    for Index := Save.FirstRevision - 1 to Count - 1 do
      Digests.Add(AuditSHA256(Entries[Index].Serialized));
  except
    Result.Free;
    raise;
  end;
end;

function TLibraryStore.ExportJSON(Database: TSQLiteLibrary): RawByteString;
var
  Document: TJSONObject;
  Revisions: TJSONArray;
  Index: Integer;
begin
  Document := TJSONObject(FMetadata.Clone);
  try
    Revisions := TJSONArray.Create;
    Document.Add('revisions', Revisions);
    for Index := 0 to Count - 1 do
      Revisions.Add(PayloadAt(Index, Database).CloneJSON);
    Result := Document.FormatJSON + #10;
  finally
    Document.Free;
  end;
end;

function TLibraryStore.ExportRecoveryJSON: RawByteString;
var
  Reader: TSQLiteLibrary;
  Recovery: TJSONObject;
  Pending: TJSONArray;
  Index: Integer;
  State: string;
begin
  if FSavedState = '' then
    Exit(ExportJSON(nil));
  Reader := nil;
  try
    try
      Reader := TSQLiteLibrary.OpenRead(FPath);
      State := Reader.Revisions.StateKey;
      if Copy(State, 1, Pos(':', State)) = Copy(FSavedState, 1, Pos(':', FSavedState)) then
        Exit(ExportJSON(Reader));
    except
      // A removed or replaced database can leave only the in-memory edits available.
      on E: ECommandCancelled do raise;
      on E: Exception do ;
    end;
  finally
    Reader.Free;
  end;
  Recovery := TJSONObject.Create;
  try
    Recovery.Add('format', 'scu-pending-recovery-v1');
    Recovery.Add('base_library_revision', FSavedRevisionCount);
    Recovery.Add('base_library_state', FSavedState);
    Recovery.Add('header', Header.CloneJSON);
    Pending := TJSONArray.Create;
    Recovery.Add('pending_revisions', Pending);
    for Index := FSavedRevisionCount to Count - 1 do
      Pending.Add(Entries[Index].CloneJSON);
    Result := Recovery.FormatJSON + #10;
  finally
    Recovery.Free;
  end;
end;

end.
