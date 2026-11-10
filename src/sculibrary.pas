unit ScuLibrary;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, ScuVersions, ScuSQLite;

const
  CurrentDeckVersionSelector = 'scu$current_deck_version';
  PreviousDeckVersionSelector = 'scu$previous_deck_version';
  LastModifiedDeckSelector = 'scu$last_modified_deck';

type
  TLibrarySnapshot = record
    Version: string;
    LibraryRevision: Integer;
  end;

  TDeckSource = record
    Bytes: RawByteString;
    ModifiedUTC: string;
    DeckVersion: string;
    CommentPrefix: string;
  end;

  TDeckLibrary = class
  private
    FPath: string;
    FDocument, FHeader: TJSONObject;
    FRevisions: TJSONArray;
    FVersions: TVersionHistory;
    FModified: Boolean;
    FDatabase: TSQLiteLibrary;
    FOwnedReader: TSQLiteLibrary;
    FIndexedRevisions, FSavedRevisionCount, FSaveFrom: Integer;
    FSavedState, FNextSavedState: string;
    FDeckNumbers: array of Integer;
    function GetRevision: Integer;
    function RevisionAt(Index: Integer): TJSONObject;
    function RevisionPayloadAt(Index: Integer): TJSONObject;
    function FindDeckRevision(const Name: string; LastRevision: Integer): Integer;
    procedure LoadDeckNumbers;
    procedure MarkModified;
    function GetHeaderJSON: string;
    function GetEditor: TJSONArray;
    function GetBuildCommand: string;
    function GetLastModifiedDeck: string;
    procedure WriteDatabase(Database: TSQLiteLibrary);
    function ExportJSON: RawByteString;
  public
    constructor Create(const Path: string; const InitialVersion: string = ''; Database: TSQLiteLibrary = nil);
    destructor Destroy; override;
    procedure Save;
    procedure AttachDatabase(Database: TSQLiteLibrary);
    procedure FinishDatabaseSave(Committed: Boolean);
    function ExportRecoveryJSON: RawByteString;
    function SavedContents: TJSONObject;
    function HeaderDigest: string;
    function RevisionDigest(Sequence: Integer): string;
    function Store(const Deck: string; const Source: RawByteString;
      CreateOnly: Boolean = False; const Prefix: string = ''): Integer;
    function Extract(const Deck: string; Revision: Integer; const SelectedVersion: string = ''): TDeckSource;
    procedure RequireOpenVersion;
    procedure List(Revision: Integer; Dest: TStrings);
    procedure ListDeckHistory(const Deck: string; Dest: TStrings);
    function ListDeckRevisions(const Deck: string; Dest: TStrings; IncludeLibraryRevisions,
      IncludeDeckVersions: Boolean): Integer;
    procedure ChangedDecks(Base, Last: Integer; Dest: TStrings);
    procedure VersionBounds(const Name: string; out Base, Last: Integer);
    procedure ListVersions(Dest: TStrings);
    procedure ListVersionNames(Dest: TStrings; const Deck: string = '');
    function ParseRevision(const Value: string): Integer;
    function ParseDeckSnapshot(const Name, Selector: string): TLibrarySnapshot;
    function DeckVersionAt(Revision: Integer): string;
    function DeckRevisionAt(Revision: Integer): string;
    function CurrentSnapshot: TLibrarySnapshot;
    function TryPreviousSnapshot(out Snapshot: TLibrarySnapshot): Boolean;
    function PreviousDeckSnapshot(const Name: string; AtRevision: Integer): TLibrarySnapshot;
    procedure LockVersion;
    procedure StartVersion(const Name: string);
    function CurrentVersion: string;
    function VersionAt(Revision: Integer): string;
    function DefaultCommentPrefix(const Version: string): string;
    procedure Configure(ChangePrefix: Boolean; const Prefix: string; NewEditor: TJSONArray;
      const VersionIncrement, RevisionIncrement: string; ChangeBuild: Boolean; const NewBuildCommand: string);
    property HeaderJSON: string read GetHeaderJSON;
    property Editor: TJSONArray read GetEditor;
    property BuildCommand: string read GetBuildCommand;
    property LastModifiedDeck: string read GetLastModifiedDeck;
    property DeckVersion[LibraryRevision: Integer]: string read DeckVersionAt;
    property DeckRevision[LibraryRevision: Integer]: string read DeckRevisionAt;
    property Revision: Integer read GetRevision;
    property Modified: Boolean read FModified;
  end;

function DeckName(const Name: string): string;

implementation

uses
  SysUtils, DateUtils, FGL, ScuIO, ScuJSON, ScuCodec, ScuVersionNumbers, ScuSignals;

const
  MaxDeckRevision = 999;
  DefaultVersionIncrement = '0.01';
  DefaultRevisionIncrement = '0.001';

type
  TDeckRevisionMap = specialize TFPGMap<string, Integer>;

function ParseIncrement(const Value, Name: string; Places: Integer; Maximum: Int64): Int64;
begin
  if not TryParseFixed(Value, Places, Result) or (Result < 1) or (Result > Maximum) then
    raise EScuError.CreateFmt('Expected a positive %s from %s to %s.',
      [Name, FormatFixed(1, Places), FormatFixed(Maximum, Places)]);
end;

function DeckName(const Name: string): string;
var
  Index: Integer;
begin
  if (Name = '') or (Length(Name) > 128) or
    not (Name[1] in ['a'..'z', 'A'..'Z', '0'..'9']) then
    raise EScuError.CreateFmt('Invalid deck name "%s".', [Name]);
  for Index := 2 to Length(Name) do
    if not (Name[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.']) then
      raise EScuError.CreateFmt('Invalid deck name "%s".', [Name]);
  Result := LowerCase(Name);
end;

function ModificationTime(Entry: TJSONObject; const Deck: string): string;
var
  Stamp: TDateTime;
begin
  Result := Field(Entry, 'modified_utc', jtString).AsString;
  if not TryISO8601ToDate(Result, Stamp) or (UtcTimestamp(Stamp) <> Result) then
    raise EScuError.CreateFmt('Invalid modification timestamp for deck "%s".', [Deck]);
end;

function StoredCommentPrefix(Entry: TJSONObject): string;
begin
  Result := '';
  if Assigned(Entry) and Assigned(Entry.Find('comment_prefix')) then
  begin
    Result := Field(Entry, 'comment_prefix', jtString).AsString;
    ValidateCommentPrefix(Result);
  end;
end;

procedure ValidateEditor(Args: TJSONArray);
var
  Index: Integer;
begin
  if (Args.Count = 0) or (Args.Items[0].JSONType <> jtString) or (Args.Strings[0] = '') then
    raise EScuError.Create('The editor must be a JSON array beginning with an executable.');
  for Index := 0 to Args.Count - 1 do
    if (Args.Items[Index].JSONType <> jtString) or (Pos(#0, Args.Strings[Index]) > 0) then
      raise EScuError.Create('Editor arguments must be strings without NUL bytes.');
end;

constructor TDeckLibrary.Create(const Path: string; const InitialVersion: string; Database: TSQLiteLibrary);
var
  Index: Integer;
  Name: string;
  Versions, DefaultEditor: TJSONArray;
begin
  inherited Create;
  FSaveFrom := -1;
  FPath := Path;
  FDatabase := Database;
  if InitialVersion <> '' then
  begin
    FDocument := TJSONObject.Create;
    FDocument.Add('format', 1);
    FHeader := TJSONObject.Create;
    FDocument.Add('header', FHeader);
    FHeader.Add('current_version', InitialVersion);
    FHeader.Add('last_modified_deck', '');
    FHeader.Add('version_increment', DefaultVersionIncrement);
    FHeader.Add('revision_increment', DefaultRevisionIncrement);
    FHeader.Add('build_command', '');
    FHeader.Add('comment_prefix', '//');
    DefaultEditor := TJSONArray.Create;
    FHeader.Add('editor', DefaultEditor);
    DefaultEditor.Add('vi');
    FRevisions := TJSONArray.Create;
    FDocument.Add('revisions', FRevisions);
    Versions := TJSONArray.Create;
    FHeader.Add('versions', Versions);
    FVersions := TVersionHistory.Create(Versions, 0);
    FVersions.Start(InitialVersion, '//', 0);
    MarkModified;
  end
  else
  begin
    if not Assigned(FDatabase) then
    begin
      FOwnedReader := TSQLiteLibrary.Create(Path, False, True);
      FOwnedReader.BeginTransaction(True);
      FOwnedReader.EnsureSchema(False);
      FDatabase := FOwnedReader;
    end;
    FSavedState := FDatabase.StateKey;
    FDocument := FDatabase.ReadDocument;
    if IntegerField(FDocument, 'format') <> 1 then
      raise EScuError.Create('Unsupported library format.');
    FRevisions := TJSONArray(Field(FDocument, 'revisions', jtArray));
    FIndexedRevisions := Revision;
    FHeader := TJSONObject(Field(FDocument, 'header', jtObject));
    Versions := TJSONArray(Field(FHeader, 'versions', jtArray));
    if Versions.Count = 0 then
      raise EScuError.Create('Library has no versions.');
    FVersions := TVersionHistory.Create(Versions, Revision);
    if (Field(FHeader, 'current_version', jtString).AsString <> CurrentVersion) or
      (Field(FHeader, 'comment_prefix', jtString).AsString <> DefaultCommentPrefix(CurrentVersion)) then
      raise EScuError.Create('The library header does not match the current version.');
    ValidateEditor(Editor);
    if not Assigned(FHeader.Find('build_command')) then
      FHeader.Add('build_command', '');
    if Pos(#0, BuildCommand) > 0 then
      raise EScuError.Create('The build command cannot contain NUL bytes.');
    if not Assigned(FHeader.Find('version_increment')) then
      FHeader.Add('version_increment', DefaultVersionIncrement);
    if not Assigned(FHeader.Find('revision_increment')) then
      FHeader.Add('revision_increment', DefaultRevisionIncrement);
    ParseIncrement(Field(FHeader, 'version_increment', jtString).AsString,
      'version_increment', 2, Int64(High(Integer)) * 100 + 99);
    ParseIncrement(Field(FHeader, 'revision_increment', jtString).AsString,
      'revision_increment', 3, MaxDeckRevision);
    Name := '';
    for Index := 0 to FRevisions.Count - 1 do
    begin
      Name := Field(RevisionAt(Index), 'deck', jtString).AsString;
      if Name <> DeckName(Name) then
        raise EScuError.CreateFmt('Invalid deck name in revision %d.', [Index + 1]);
    end;
    if not Assigned(FHeader.Find('last_modified_deck')) then
      FHeader.Add('last_modified_deck', Name)
    else if LastModifiedDeck <> Name then
      raise EScuError.Create('The last_modified_deck header does not match the revision history.');
    LoadDeckNumbers;
    FSavedRevisionCount := Revision;
  end;
end;

destructor TDeckLibrary.Destroy;
begin
  FOwnedReader.Free;
  FVersions.Free;
  FDocument.Free;
  inherited Destroy;
end;

function TDeckLibrary.GetRevision: Integer;
begin
  Result := FRevisions.Count;
end;

function TDeckLibrary.RevisionAt(Index: Integer): TJSONObject;
begin
  if not (FRevisions.Items[Index] is TJSONObject) then
    raise EScuError.CreateFmt('Invalid library revision %d.', [Index + 1]);
  Result := TJSONObject(FRevisions.Items[Index]);
end;

function TDeckLibrary.RevisionPayloadAt(Index: Integer): TJSONObject;
var
  Payload: TJSONObject;
  Number: Int64;
begin
  Result := RevisionAt(Index);
  if (Index >= FIndexedRevisions) or Assigned(Result.Find('zstd_base64')) then
    Exit;
  Payload := FDatabase.ReadRevision(Index + 1);
  try
    if Field(Payload, 'deck', jtString).AsString <> Field(Result, 'deck', jtString).AsString then
      raise EScuError.Create('The SQLite deck name does not match its payload.');
    if Assigned(Payload.Find('deck_revision')) and
      (not TryParseFixed(Field(Payload, 'deck_revision', jtString).AsString, 3, Number) or
      (Number <> FDeckNumbers[Index])) then
      raise EScuError.Create('The SQLite deck revision does not match its payload.');
    Field(Payload, 'zstd_base64', jtString);
    FRevisions.Items[Index] := Payload;
    Result := Payload;
  except
    Payload.Free;
    raise;
  end;
end;

function TDeckLibrary.FindDeckRevision(const Name: string; LastRevision: Integer): Integer;
begin
  for Result := LastRevision downto 1 do
    if Field(RevisionAt(Result - 1), 'deck', jtString).AsString = Name then
      Exit;
  Result := 0;
end;

procedure TDeckLibrary.LoadDeckNumbers;
var
  Seen: TDeckRevisionMap;
  Entry: TJSONObject;
  Name, Version, PreviousVersion: string;
  Index, Slot, Previous: Integer;
  Number: Int64;
begin
  SetLength(FDeckNumbers, Revision);
  Seen := TDeckRevisionMap.Create;
  try
    Seen.Sorted := True;
    PreviousVersion := '';
    for Index := 0 to High(FDeckNumbers) do
    begin
      Version := VersionAt(Index + 1);
      if Version <> PreviousVersion then
      begin
        Seen.Clear;
        PreviousVersion := Version;
      end;
      Entry := RevisionAt(Index);
      Name := Field(Entry, 'deck', jtString).AsString;
      Slot := Seen.IndexOf(Name);
      Previous := -1;
      if Slot >= 0 then
        Previous := Seen.Data[Slot];
      if Assigned(Entry.Find('deck_revision')) then
      begin
        if not TryParseFixed(Field(Entry, 'deck_revision', jtString).AsString, 3, Number) or
          (Number > MaxDeckRevision) or (Number <= Previous) or ((Slot < 0) and (Number <> 0)) then
          raise EScuError.CreateFmt('Invalid deck revision in library revision %d.', [Index + 1]);
      end
      else
        // Older libraries numbered only library snapshots.
        Number := Previous + 1;
      FDeckNumbers[Index] := Number;
      if Slot >= 0 then
        Seen.Data[Slot] := Number
      else
        Seen.Add(Name, Number);
    end;
  finally
    Seen.Free;
  end;
end;

procedure TDeckLibrary.MarkModified;
begin
  FModified := True;
end;

procedure TDeckLibrary.AttachDatabase(Database: TSQLiteLibrary);
begin
  if (FSavedState <> '') and not Assigned(Database) then
    raise EScuError.Create('The saved SQLite library is unavailable. Unsaved changes are still in this session.');
  FDatabase := Database;
end;

procedure TDeckLibrary.FinishDatabaseSave(Committed: Boolean);
begin
  if Committed and (FNextSavedState <> '') then
  begin
    FSavedState := FNextSavedState;
    FModified := False;
  end;
  if Committed and (FSaveFrom >= 0) then
    FSavedRevisionCount := Revision;
  FSaveFrom := -1;
  FNextSavedState := '';
  FDatabase := nil;
end;

procedure TDeckLibrary.WriteDatabase(Database: TSQLiteLibrary);
var
  Metadata, Entry: TJSONObject;
  Index, SavedCount: Integer;
begin
  SavedCount := Database.RevisionCount;
  if SavedCount > Revision then
    raise EScuError.Create('SQLite library contains newer revisions.');
  Metadata := TJSONObject.Create;
  try
    for Index := 0 to FDocument.Count - 1 do
      if FDocument.Names[Index] <> 'revisions' then
        Metadata.Add(FDocument.Names[Index], FDocument.Items[Index].Clone);
    Database.SaveMetadata(Metadata.AsJSON);
  finally
    Metadata.Free;
  end;
  for Index := SavedCount to Revision - 1 do
  begin
    Entry := RevisionAt(Index);
    Database.AppendRevision(Index + 1, Field(Entry, 'deck', jtString).AsString,
      VersionAt(Index + 1), FormatFixed(FDeckNumbers[Index], 3), Entry.AsJSON);
  end;
end;

function TDeckLibrary.HeaderDigest: string;
begin
  Result := AuditSHA256(FHeader.AsJSON);
end;

function TDeckLibrary.RevisionDigest(Sequence: Integer): string;
begin
  Result := AuditSHA256(RevisionPayloadAt(Sequence - 1).AsJSON);
end;

function TDeckLibrary.SavedContents: TJSONObject;
var
  Index: Integer;
  Digests: TJSONArray;
begin
  if FSaveFrom < 0 then
    Exit(nil);
  Result := TJSONObject.Create;
  try
    Result.Add('header_sha256', HeaderDigest);
    Result.Add('revision_count', Revision);
    Result.Add('first_revision', FSaveFrom + 1);
    Digests := TJSONArray.Create;
    Result.Add('revision_sha256', Digests);
    for Index := FSaveFrom + 1 to Revision do
      Digests.Add(RevisionDigest(Index));
  except
    Result.Free;
    raise;
  end;
end;

function TDeckLibrary.ExportJSON: RawByteString;
var
  Index: Integer;
begin
  for Index := 0 to FIndexedRevisions - 1 do
    RevisionPayloadAt(Index);
  Result := FDocument.FormatJSON + #10;
end;

function TDeckLibrary.ExportRecoveryJSON: RawByteString;
var
  Reader: TSQLiteLibrary;
  Recovery: TJSONObject;
  Pending: TJSONArray;
  Index: Integer;
  State: string;
begin
  if FSavedState = '' then
    Exit(ExportJSON);
  Reader := nil;
  try
    try
      Reader := TSQLiteLibrary.Create(FPath, False, True);
      Reader.BeginTransaction(True);
      Reader.EnsureSchema(False);
      State := Reader.StateKey;
      if Copy(State, 1, Pos(':', State)) = Copy(FSavedState, 1, Pos(':', FSavedState)) then
      begin
        FDatabase := Reader;
        Exit(ExportJSON);
      end;
    except
      // A removed or replaced database can leave only the in-memory edits available.
      on E: Exception do ;
    end;
  finally
    FDatabase := nil;
    Reader.Free;
  end;
  Recovery := TJSONObject.Create;
  try
    Recovery.Add('format', 'scu-pending-recovery-v1');
    Recovery.Add('base_library_revision', FSavedRevisionCount);
    Recovery.Add('header', FHeader.Clone);
    Pending := TJSONArray.Create;
    Recovery.Add('pending_revisions', Pending);
    for Index := FSavedRevisionCount to Revision - 1 do
      Pending.Add(RevisionAt(Index).Clone);
    Result := Recovery.FormatJSON + #10;
  finally
    Recovery.Free;
  end;
end;

procedure TDeckLibrary.Save;
begin
  if not FModified then
    Exit;
  CheckSessionInterrupt;
  if not Assigned(FDatabase) then
    raise EScuError.Create('Saving requires an open SQLite transaction.');
  if FDatabase.StateKey <> FSavedState then
    raise EScuError.Create('The saved library changed outside this session. Unsaved changes are still in this session.');
  WriteDatabase(FDatabase);
  FNextSavedState := FDatabase.StateKey;
  FSaveFrom := FSavedRevisionCount;
end;

procedure TDeckLibrary.RequireOpenVersion;
begin
  if FVersions.Locked then
    raise EScuError.CreateFmt('Version %s is locked. Start a new version first.', [CurrentVersion]);
end;

function TDeckLibrary.Store(const Deck: string; const Source: RawByteString;
  CreateOnly: Boolean; const Prefix: string): Integer;
var
  Entry, Previous: TJSONObject;
  Name, CommentPrefix, PreviousLastDeck, Digest: string;
  PreviousSource: TDeckSource;
  PreviousRevision, Number, Base, Last: Integer;
begin
  RequireOpenVersion;
  Name := DeckName(Deck);
  PreviousRevision := FindDeckRevision(Name, Revision);
  if CreateOnly and (PreviousRevision > 0) then
    raise EScuError.CreateFmt('Deck "%s" already exists.', [Name]);
  VersionBounds(CurrentVersion, Base, Last);
  Previous := nil;
  if PreviousRevision > 0 then
    Previous := RevisionPayloadAt(PreviousRevision - 1);
  CommentPrefix := Prefix;
  if CommentPrefix = '' then
    CommentPrefix := StoredCommentPrefix(Previous);
  if CommentPrefix = '' then
    CommentPrefix := DefaultCommentPrefix(CurrentVersion);
  ValidateCommentPrefix(CommentPrefix);
  Digest := DeckSHA1(Source);
  Number := 0;
  if PreviousRevision > Base then
  begin
    if (CommentPrefix = StoredCommentPrefix(Previous)) and
      (Digest = Field(Previous, 'sha1', jtString).AsString) then
    begin
      PreviousSource := Extract(Name, PreviousRevision);
      if PreviousSource.Bytes = Source then
        Exit(0);
    end;
    Number := FDeckNumbers[PreviousRevision - 1] + ParseIncrement(
      Field(FHeader, 'revision_increment', jtString).AsString, 'revision_increment', 3, MaxDeckRevision);
    if Number > MaxDeckRevision then
      raise EScuError.CreateFmt('Deck "%s" has reached the revision limit. Lock version %s and start a new version.',
        [Name, CurrentVersion]);
  end;
  Entry := TJSONObject.Create;
  try
    Entry.Add('deck', Name);
    Entry.Add('deck_revision', FormatFixed(Number, 3));
    Entry.Add('comment_prefix', CommentPrefix);
    Entry.Add('size', Length(Source));
    Entry.Add('sha1', Digest);
    Entry.Add('modified_utc', UtcTimestamp(UtcNow));
    Entry.Add('zstd_base64', EncodeDeck(Source));
    CheckSessionInterrupt;
  except
    Entry.Free;
    raise;
  end;
  PreviousLastDeck := LastModifiedDeck;
  FRevisions.Add(Entry);
  try
    SetLength(FDeckNumbers, Revision);
    FDeckNumbers[Revision - 1] := Number;
    FHeader.Strings['last_modified_deck'] := Name;
    MarkModified;
  except
    FRevisions.Delete(FRevisions.Count - 1);
    SetLength(FDeckNumbers, Revision);
    FHeader.Strings['last_modified_deck'] := PreviousLastDeck;
    raise;
  end;
  Result := FRevisions.Count;
end;

function TDeckLibrary.Extract(const Deck: string; Revision: Integer; const SelectedVersion: string): TDeckSource;
var
  Name: string;
  Entry: TJSONObject;
  StoredRevision: Integer;
begin
  Name := DeckName(Deck);
  StoredRevision := FindDeckRevision(Name, Revision);
  if StoredRevision = 0 then
  begin
    if SelectedVersion <> '' then
      raise EScuError.CreateFmt('Deck "%s" does not exist in version %s.', [Name, SelectedVersion]);
    raise EScuError.CreateFmt('Deck "%s" does not exist at revision %d.', [Name, Revision]);
  end;
  Entry := RevisionPayloadAt(StoredRevision - 1);
  Result.CommentPrefix := StoredCommentPrefix(Entry);
  Result.ModifiedUTC := ModificationTime(Entry, Name);
  Result.DeckVersion := DeckVersionAt(StoredRevision);
  Result.Bytes := DecodeDeck(Field(Entry, 'zstd_base64', jtString).AsString,
    Field(Entry, 'sha1', jtString).AsString, IntegerField(Entry, 'size'));
end;

procedure TDeckLibrary.List(Revision: Integer; Dest: TStrings);
var
  Seen: TStringList;
  Index: Integer;
  Name: string;
begin
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.CaseSensitive := True;
    for Index := Revision - 1 downto 0 do
    begin
      Name := Field(RevisionAt(Index), 'deck', jtString).AsString;
      if Seen.IndexOf(Name) >= 0 then
        Continue;
      Seen.Add(Name);
      Dest.Add(Name + #9 + DeckVersionAt(Index + 1));
    end;
  finally
    Seen.Free;
  end;
end;

procedure TDeckLibrary.ListDeckHistory(const Deck: string; Dest: TStrings);
var
  Name: string;
  Index, InitialCount: Integer;
  Entry: TJSONObject;
begin
  Name := DeckName(Deck);
  InitialCount := Dest.Count;
  for Index := Revision - 1 downto 0 do
  begin
    Entry := RevisionAt(Index);
    if Field(Entry, 'deck', jtString).AsString = Name then
      Dest.Add(Format('%d'#9'%s'#9'%s'#9'%s', [Index + 1, VersionAt(Index + 1),
        ModificationTime(RevisionPayloadAt(Index), Name), DeckVersionAt(Index + 1)]));
  end;
  if Dest.Count = InitialCount then
    raise EScuError.CreateFmt('Deck "%s" does not exist.', [Name]);
end;

procedure TDeckLibrary.ChangedDecks(Base, Last: Integer; Dest: TStrings);
var
  Index: Integer;
begin
  for Index := Base to Last - 1 do
    Dest.Add(Field(RevisionAt(Index), 'deck', jtString).AsString);
end;

function TDeckLibrary.ListDeckRevisions(const Deck: string; Dest: TStrings; IncludeLibraryRevisions,
  IncludeDeckVersions: Boolean): Integer;
var
  Name: string;
  Index: Integer;
begin
  Name := DeckName(Deck);
  Result := 0;
  for Index := 0 to Revision - 1 do
    if Field(RevisionAt(Index), 'deck', jtString).AsString = Name then
    begin
      Inc(Result);
      if IncludeLibraryRevisions then
        Dest.Add(IntToStr(Index + 1));
      if IncludeDeckVersions then
        Dest.Add(DeckVersionAt(Index + 1));
    end;
end;

procedure TDeckLibrary.VersionBounds(const Name: string; out Base, Last: Integer);
begin
  FVersions.Bounds(Name, Revision, Base, Last);
end;

procedure TDeckLibrary.ListVersions(Dest: TStrings);
begin
  FVersions.List(Revision, Dest);
end;

procedure TDeckLibrary.ListVersionNames(Dest: TStrings; const Deck: string);
var
  Name: string;
  Index, Latest, FirstRevision: Integer;
begin
  Latest := Revision;
  FirstRevision := 0;
  if Deck <> '' then
  begin
    Name := DeckName(Deck);
    Index := 0;
    while (Index < Latest) and (Field(RevisionAt(Index), 'deck', jtString).AsString <> Name) do
      Inc(Index);
    if Index = Latest then
      Exit;
    FirstRevision := Index + 1;
  end;
  FVersions.ListNames(Latest, FirstRevision, Dest);
end;

function TDeckLibrary.ParseRevision(const Value: string): Integer;
begin
  if not TryStrToInt(Value, Result) or
    (Result < 0) or (Result > Revision) then
    raise EScuError.CreateFmt('Expected a revision between 0 and %d.', [Revision]);
end;

function TDeckLibrary.CurrentSnapshot: TLibrarySnapshot;
begin
  Result.Version := CurrentVersion;
  Result.LibraryRevision := Revision;
end;

function TDeckLibrary.DeckVersionAt(Revision: Integer): string;
begin
  Result := VersionAt(Revision) + '-' + DeckRevisionAt(Revision);
end;

function TDeckLibrary.DeckRevisionAt(Revision: Integer): string;
begin
  Result := FormatFixed(FDeckNumbers[Revision - 1], 3);
end;

function TDeckLibrary.ParseDeckSnapshot(const Name, Selector: string): TLibrarySnapshot;
var
  Separator, Base, Last, Index: Integer;
  Number: Int64;
begin
  if SameText(Selector, PreviousDeckVersionSelector) then
    Exit(PreviousDeckSnapshot(Name, Revision));
  if SameText(Selector, CurrentDeckVersionSelector) then
  begin
    Result.LibraryRevision := FindDeckRevision(Name, Revision);
    if Result.LibraryRevision = 0 then
      raise EScuError.CreateFmt('Deck "%s" does not exist at revision %d.', [Name, Revision]);
    Result.Version := VersionAt(Result.LibraryRevision);
    Exit;
  end;
  Separator := Pos('-', Selector);
  if (Separator <= 1) or not TryParseFixed(Copy(Selector, Separator + 1, MaxInt), 3, Number) then
    raise EScuError.CreateFmt('Invalid deck version "%s". Expected VERSION-REVISION, %s, or %s.',
      [Selector, CurrentDeckVersionSelector, PreviousDeckVersionSelector]);
  Result.Version := Copy(Selector, 1, Separator - 1);
  VersionBounds(Result.Version, Base, Last);
  for Index := Last downto Base + 1 do
    if (FDeckNumbers[Index - 1] = Number) and
      (Field(RevisionAt(Index - 1), 'deck', jtString).AsString = Name) then
    begin
      Result.LibraryRevision := Index;
      Exit;
    end;
  raise EScuError.CreateFmt('Deck "%s" has no deck version "%s".', [Name, Selector]);
end;

function TDeckLibrary.TryPreviousSnapshot(out Snapshot: TLibrarySnapshot): Boolean;
begin
  Result := FVersions.TryPrevious(Snapshot.Version, Snapshot.LibraryRevision);
end;

function TDeckLibrary.PreviousDeckSnapshot(const Name: string; AtRevision: Integer): TLibrarySnapshot;
var
  StoredRevision: Integer;
begin
  StoredRevision := FindDeckRevision(Name, AtRevision);
  if StoredRevision = 0 then
    raise EScuError.CreateFmt('Deck "%s" does not exist at revision %d.', [Name, AtRevision]);
  Result.LibraryRevision := FindDeckRevision(Name, StoredRevision - 1);
  if Result.LibraryRevision = 0 then
    raise EScuError.CreateFmt('Deck "%s" has no earlier revision to compare with. Store an edit before comparing.', [Name]);
  Result.Version := VersionAt(Result.LibraryRevision);
end;

procedure TDeckLibrary.LockVersion;
begin
  FVersions.Lock;
  MarkModified;
end;

procedure TDeckLibrary.StartVersion(const Name: string);
var
  Next: string;
begin
  Next := Name;
  if Next = '' then
    Next := FVersions.NextVersion(ParseIncrement(Field(FHeader, 'version_increment', jtString).AsString,
      'version_increment', 2, Int64(High(Integer)) * 100 + 99));
  FVersions.Start(Next, DefaultCommentPrefix(CurrentVersion), Revision);
  FHeader.Strings['current_version'] := CurrentVersion;
  MarkModified;
end;

function TDeckLibrary.CurrentVersion: string;
begin
  Result := FVersions.Current;
end;

function TDeckLibrary.VersionAt(Revision: Integer): string;
begin
  Result := FVersions.AtRevision(Revision);
end;

function TDeckLibrary.DefaultCommentPrefix(const Version: string): string;
begin
  Result := FVersions.CommentPrefix(Version);
end;

function TDeckLibrary.GetHeaderJSON: string;
begin
  Result := FHeader.FormatJSON;
end;

function TDeckLibrary.GetLastModifiedDeck: string;
begin
  Result := Field(FHeader, 'last_modified_deck', jtString).AsString;
end;

function TDeckLibrary.GetEditor: TJSONArray;
begin
  Result := TJSONArray(Field(FHeader, 'editor', jtArray));
end;

function TDeckLibrary.GetBuildCommand: string;
begin
  Result := Field(FHeader, 'build_command', jtString).AsString;
end;

procedure TDeckLibrary.Configure(ChangePrefix: Boolean; const Prefix: string; NewEditor: TJSONArray;
  const VersionIncrement, RevisionIncrement: string; ChangeBuild: Boolean; const NewBuildCommand: string);
var
  Changed: Boolean;
  VersionValue, RevisionValue: string;
begin
  Changed := False;
  VersionValue := '';
  RevisionValue := '';
  if VersionIncrement <> '' then
    VersionValue := FormatFixed(ParseIncrement(VersionIncrement, 'version_increment', 2,
      Int64(High(Integer)) * 100 + 99), 2);
  if RevisionIncrement <> '' then
    RevisionValue := FormatFixed(ParseIncrement(RevisionIncrement, 'revision_increment', 3, MaxDeckRevision), 3);
  if Assigned(NewEditor) then
    ValidateEditor(NewEditor);
  if ChangeBuild and (Pos(#0, NewBuildCommand) > 0) then
    raise EScuError.Create('The build command cannot contain NUL bytes.');
  if ChangePrefix and (Prefix <> DefaultCommentPrefix(CurrentVersion)) then
  begin
    FVersions.SetCommentPrefix(Prefix, Revision);
    FHeader.Strings['comment_prefix'] := Prefix;
    Changed := True;
  end;
  if (VersionValue <> '') and (VersionValue <> FHeader.Strings['version_increment']) then
  begin
    FHeader.Strings['version_increment'] := VersionValue;
    Changed := True;
  end;
  if (RevisionValue <> '') and (RevisionValue <> FHeader.Strings['revision_increment']) then
  begin
    FHeader.Strings['revision_increment'] := RevisionValue;
    Changed := True;
  end;
  if Assigned(NewEditor) and (NewEditor.AsJSON <> Editor.AsJSON) then
  begin
    FHeader.Delete('editor');
    FHeader.Add('editor', NewEditor.Clone);
    Changed := True;
  end;
  if ChangeBuild and (NewBuildCommand <> BuildCommand) then
  begin
    FHeader.Strings['build_command'] := NewBuildCommand;
    Changed := True;
  end;
  if Changed then
    MarkModified;
end;

end.
