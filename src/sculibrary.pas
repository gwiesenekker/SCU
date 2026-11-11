unit ScuLibrary;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, ScuLibraryModel, ScuLibraryStore, ScuVersions, ScuSQLite;

const
  CurrentDeckVersionSelector = 'scu$current_deck_version';
  PreviousDeckVersionSelector = 'scu$previous_deck_version';
  LastModifiedDeckSelector = 'scu$last_modified_deck';
  CurrentVersionSelector = 'scu$current_version';
  PreviousVersionSelector = 'scu$previous_version';

type
  TDeckRevisionFormats = set of (drLibraryRevision, drDeckVersion);

  TLibrarySnapshot = record
    Version: string;
    LibraryRevision: Integer;
  end;

  TDeckSource = record
    Bytes: RawByteString;
    LibraryRevision: Integer;
    ModifiedUTC: string;
    DeckVersion: string;
    CommentPrefix: string;
    Deleted: Boolean;
  end;

  TLibrarySave = ScuLibraryStore.TLibrarySave;
  TLibrarySettingsChange = ScuLibraryModel.TLibrarySettingsChange;

  TDeckLibrary = class
  private
    FStore: TLibraryStore;
    FModified: Boolean;
    FChangeCount: QWord;
    procedure MarkModified;
    function Versions: TVersionHistory;
    function GetRevision: Integer;
    function FindDeckRevision(const Name: string; LastRevision: Integer): Integer;
    function GetHeaderJSON: string;
    function NextDeckNumber(const Name: string; PreviousRevision: Integer): Integer;
    function AppendDeckRevision(const Name: string; var Payload: TJSONObject): Integer;
    function RevisionDeletedAt(Sequence: Integer): Boolean;
    function GetEditorCount: Integer;
    function GetEditorArgument(Index: Integer): string;
    function GetBuildCommand: string;
    function GetVersionCount: Integer;
    function GetVersionEntry(Index: Integer): TVersionEntry;
    function GetLastModifiedDeck: string;
    function DeckVersionAt(Revision: Integer): string;
    function DeckRevisionAt(Revision: Integer): string;
  public
    constructor CreateNew(const Path, InitialVersion: string);
    constructor Load(const Path: string; Database: TSQLiteLibrary);
    constructor CreateRecovered(var Document: TJSONObject);
    destructor Destroy; override;
    procedure Save(Database: TSQLiteLibrary; var Staged: TLibrarySave);
    procedure AcceptSave(const Staged: TLibrarySave);
    function ExportRecoveryJSON: RawByteString;
    function CreateSavedContents(const Staged: TLibrarySave): TJSONObject;
    function HeaderDigest: string;
    function RevisionDigest(Sequence: Integer; Database: TSQLiteLibrary): string;
    function Store(Database: TSQLiteLibrary; const Deck: string; const Source: RawByteString;
      CreateOnly: Boolean = False; const Prefix: string = ''): Integer;
    function Delete(Database: TSQLiteLibrary; const Deck: string): Integer;
    function Extract(Database: TSQLiteLibrary; const Deck: string; LibraryRevision: Integer;
      const SelectedVersion: string = ''; AllowDeleted: Boolean = False): TDeckSource;
    procedure RequireOpenVersion;
    procedure List(LibraryRevision: Integer; Dest: TStrings);
    procedure ListDeckHistory(Database: TSQLiteLibrary; const Deck: string; Dest: TStrings);
    function ListDeckRevisions(const Deck: string; Dest: TStrings; Formats: TDeckRevisionFormats): Integer;
    procedure ChangedDecks(Base, Last: Integer; Dest: TStrings);
    procedure VersionBounds(const Name: string; out Base, Last: Integer);
    procedure ListVersions(Dest: TStrings);
    procedure ListVersionNames(Dest: TStrings; const Deck: string = '');
    function ParseRevision(const Value: string): Integer;
    function ParseDeckSnapshot(const Name, Selector: string): TLibrarySnapshot;
    function ParseLibrarySnapshot(const Selector: string): TLibrarySnapshot;
    function TryDeckSnapshot(const Deck: string; LibraryRevision: Integer;
      out Snapshot: TLibrarySnapshot): Boolean;
    function CurrentSnapshot: TLibrarySnapshot;
    function TryPreviousSnapshot(out Snapshot: TLibrarySnapshot): Boolean;
    function PreviousDeckSnapshot(const Name: string; AtRevision: Integer): TLibrarySnapshot;
    procedure LockVersion(const Description: string);
    procedure StartVersion(const Name: string);
    function CurrentVersion: string;
    function VersionAt(Revision: Integer): string;
    function DefaultCommentPrefix(const Version: string): string;
    procedure Configure(const Settings: TLibrarySettingsChange);
    property VersionCount: Integer read GetVersionCount;
    property VersionHistory[Index: Integer]: TVersionEntry read GetVersionEntry;
    property HeaderJSON: string read GetHeaderJSON;
    property EditorCount: Integer read GetEditorCount;
    property EditorArguments[Index: Integer]: string read GetEditorArgument;
    property BuildCommand: string read GetBuildCommand;
    property LastModifiedDeck: string read GetLastModifiedDeck;
    property DeckVersion[LibraryRevision: Integer]: string read DeckVersionAt;
    property DeckRevision[LibraryRevision: Integer]: string read DeckRevisionAt;
    property RevisionDeleted[Sequence: Integer]: Boolean read RevisionDeletedAt;
    property Revision: Integer read GetRevision;
    property Modified: Boolean read FModified;
    property ChangeCount: QWord read FChangeCount;
  end;

function DeckName(const Name: string): string;

implementation

uses
  SysUtils, ScuCodec, ScuErrors, ScuSignals, ScuVersionNumbers;

function DeckName(const Name: string): string;
begin
  Result := ScuLibraryModel.DeckName(Name);
end;

constructor TDeckLibrary.CreateNew(const Path, InitialVersion: string);
begin
  inherited Create;
  FStore := TLibraryStore.CreateNew(Path, InitialVersion);
  MarkModified;
end;

constructor TDeckLibrary.Load(const Path: string; Database: TSQLiteLibrary);
begin
  inherited Create;
  FStore := TLibraryStore.Load(Path, Database);
end;

constructor TDeckLibrary.CreateRecovered(var Document: TJSONObject);
begin
  inherited Create;
  FStore := TLibraryStore.CreateRecovered(Document);
  MarkModified;
end;

destructor TDeckLibrary.Destroy;
begin
  FStore.Free;
  inherited Destroy;
end;

procedure TDeckLibrary.MarkModified;
begin
  FModified := True;
  Inc(FChangeCount);
end;

function TDeckLibrary.Versions: TVersionHistory;
begin
  Result := FStore.Header.Versions;
end;

function TDeckLibrary.GetRevision: Integer;
begin
  Result := FStore.Count;
end;

function TDeckLibrary.FindDeckRevision(const Name: string; LastRevision: Integer): Integer;
begin
  for Result := LastRevision downto 1 do
    if FStore[Result - 1].Name = Name then
      Exit;
  Result := 0;
end;

procedure TDeckLibrary.Save(Database: TSQLiteLibrary; var Staged: TLibrarySave);
begin
  if FModified then
    FStore.StageSave(Database, Staged);
end;

procedure TDeckLibrary.AcceptSave(const Staged: TLibrarySave);
begin
  if Staged.StateKey <> '' then
  begin
    FStore.AcceptSave(Staged);
    FModified := False;
  end;
end;

function TDeckLibrary.CreateSavedContents(const Staged: TLibrarySave): TJSONObject;
begin
  Result := FStore.CreateSavedContents(Staged);
end;

function TDeckLibrary.HeaderDigest: string;
begin
  Result := FStore.Header.Digest;
end;

function TDeckLibrary.RevisionDigest(Sequence: Integer; Database: TSQLiteLibrary): string;
begin
  Result := FStore.RevisionDigest(Sequence, Database);
end;

function TDeckLibrary.ExportRecoveryJSON: RawByteString;
begin
  Result := FStore.ExportRecoveryJSON;
end;

procedure TDeckLibrary.RequireOpenVersion;
begin
  if Versions.Locked then
    raise EScuError.CreateFmt('Version %s is locked. Start a new version first.', [CurrentVersion]);
end;

function TDeckLibrary.Store(Database: TSQLiteLibrary; const Deck: string; const Source: RawByteString;
  CreateOnly: Boolean; const Prefix: string): Integer;
var
  Payload: TJSONObject;
  Previous: TLibraryRevision;
  Name, CommentPrefix, Digest: string;
  PreviousRevision, Number: Integer;
begin
  RequireOpenVersion;
  Name := DeckName(Deck);
  PreviousRevision := FindDeckRevision(Name, Revision);
  if CreateOnly and (PreviousRevision > 0) and not RevisionDeletedAt(PreviousRevision) then
    raise EScuError.CreateFmt('Deck "%s" already exists.', [Name]);
  Previous := nil;
  if PreviousRevision > 0 then
    Previous := FStore.PayloadAt(PreviousRevision - 1, Database);
  CommentPrefix := Prefix;
  if (CommentPrefix = '') and Assigned(Previous) then
    CommentPrefix := Previous.CommentPrefix;
  if CommentPrefix = '' then
    CommentPrefix := DefaultCommentPrefix(CurrentVersion);
  ValidateCommentPrefix(CommentPrefix);
  Digest := DeckSHA1(Source);
  if Assigned(Previous) and not Previous.Deleted and
    (VersionAt(PreviousRevision) = CurrentVersion) and
    (CommentPrefix = Previous.CommentPrefix) and (Digest = Previous.SHA1) and
    (Previous.Decode = Source) then
    Exit(0);
  Number := NextDeckNumber(Name, PreviousRevision);
  Payload := NewRevisionPayload(Name, CommentPrefix, Digest, Number, Source);
  Result := AppendDeckRevision(Name, Payload);
end;

function TDeckLibrary.NextDeckNumber(const Name: string; PreviousRevision: Integer): Integer;
var
  Base, Last: Integer;
begin
  VersionBounds(CurrentVersion, Base, Last);
  Result := 0;
  if PreviousRevision > Base then
    Result := FStore[PreviousRevision - 1].Number + FStore.Header.RevisionStep;
  if Result > MaxDeckRevision then
    raise EScuError.CreateFmt('Deck "%s" has reached the revision limit. Lock version %s and start a new version.',
      [Name, CurrentVersion]);
end;

function TDeckLibrary.Delete(Database: TSQLiteLibrary; const Deck: string): Integer;
var
  Name, Prefix: string;
  PreviousRevision: Integer;
  Payload: TJSONObject;
begin
  RequireOpenVersion;
  Name := DeckName(Deck);
  PreviousRevision := FindDeckRevision(Name, Revision);
  if (PreviousRevision = 0) or RevisionDeletedAt(PreviousRevision) then
    raise EScuError.CreateFmt('Deck "%s" does not exist in version %s.', [Name, CurrentVersion]);
  Prefix := FStore.PayloadAt(PreviousRevision - 1, Database).CommentPrefix;
  if Prefix = '' then
    Prefix := DefaultCommentPrefix(CurrentVersion);
  Payload := NewDeletionPayload(Name, Prefix, NextDeckNumber(Name, PreviousRevision));
  Result := AppendDeckRevision(Name, Payload);
end;

function TDeckLibrary.RevisionDeletedAt(Sequence: Integer): Boolean;
begin
  Result := FStore[Sequence - 1].Deleted;
end;

function TDeckLibrary.AppendDeckRevision(const Name: string; var Payload: TJSONObject): Integer;
begin
  try
    CheckSessionInterrupt;
    FStore.Append(Payload);
  finally
    Payload.Free;
  end;
  try
    FStore.Header.SetLastModifiedDeck(Name);
  except
    FStore.RemoveLast;
    raise;
  end;
  MarkModified;
  Result := Revision;
end;

function TDeckLibrary.Extract(Database: TSQLiteLibrary; const Deck: string; LibraryRevision: Integer;
  const SelectedVersion: string; AllowDeleted: Boolean): TDeckSource;
var
  Name: string;
  Entry: TLibraryRevision;
  StoredRevision: Integer;
begin
  Name := DeckName(Deck);
  StoredRevision := FindDeckRevision(Name, LibraryRevision);
  if (StoredRevision = 0) or (not AllowDeleted and RevisionDeletedAt(StoredRevision)) then
  begin
    if SelectedVersion <> '' then
      raise EScuError.CreateFmt('Deck "%s" does not exist in version %s.', [Name, SelectedVersion]);
    raise EScuError.CreateFmt('Deck "%s" does not exist at revision %d.', [Name, LibraryRevision]);
  end;
  Entry := FStore.PayloadAt(StoredRevision - 1, Database);
  Result.Deleted := Entry.Deleted;
  Result.LibraryRevision := StoredRevision;
  Result.CommentPrefix := Entry.CommentPrefix;
  Result.ModifiedUTC := Entry.ModifiedUTC;
  Result.DeckVersion := DeckVersionAt(StoredRevision);
  Result.Bytes := Entry.Decode;
end;

procedure TDeckLibrary.List(LibraryRevision: Integer; Dest: TStrings);
var
  Seen: TStringList;
  Index: Integer;
  Name: string;
begin
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.CaseSensitive := True;
    for Index := LibraryRevision - 1 downto 0 do
    begin
      Name := FStore[Index].Name;
      if Seen.IndexOf(Name) >= 0 then
        Continue;
      Seen.Add(Name);
      if not FStore[Index].Deleted then
        Dest.Add(Name + #9 + DeckVersionAt(Index + 1));
    end;
  finally
    Seen.Free;
  end;
end;

procedure TDeckLibrary.ListDeckHistory(Database: TSQLiteLibrary; const Deck: string; Dest: TStrings);
var
  Name: string;
  Index, InitialCount: Integer;
  Entry: TLibraryRevision;
begin
  Name := DeckName(Deck);
  InitialCount := Dest.Count;
  for Index := Revision - 1 downto 0 do
  begin
    Entry := FStore[Index];
    if Entry.Name = Name then
    begin
      Dest.Add(Format('%d'#9'%s'#9'%s'#9'%s', [Index + 1, VersionAt(Index + 1),
        FStore.PayloadAt(Index, Database).ModifiedUTC, DeckVersionAt(Index + 1)]));
      if Entry.Deleted then
        Dest[Dest.Count - 1] := Dest[Dest.Count - 1] + #9 + 'deleted';
    end;
  end;
  if Dest.Count = InitialCount then
    raise EScuError.CreateFmt('Deck "%s" does not exist.', [Name]);
end;

procedure TDeckLibrary.ChangedDecks(Base, Last: Integer; Dest: TStrings);
var
  Index: Integer;
begin
  for Index := Base to Last - 1 do
    Dest.Add(FStore[Index].Name);
end;

function TDeckLibrary.ListDeckRevisions(const Deck: string; Dest: TStrings; Formats: TDeckRevisionFormats): Integer;
var
  Name: string;
  Index: Integer;
begin
  Name := DeckName(Deck);
  Result := 0;
  for Index := 0 to Revision - 1 do
    if FStore[Index].Name = Name then
    begin
      Inc(Result);
      if drLibraryRevision in Formats then
        Dest.Add(IntToStr(Index + 1));
      if drDeckVersion in Formats then
        Dest.Add(DeckVersionAt(Index + 1));
    end;
end;

procedure TDeckLibrary.VersionBounds(const Name: string; out Base, Last: Integer);
begin
  Versions.Bounds(Name, Revision, Base, Last);
end;

procedure TDeckLibrary.ListVersions(Dest: TStrings);
begin
  Versions.List(Revision, Dest);
end;

procedure TDeckLibrary.ListVersionNames(Dest: TStrings; const Deck: string);
var
  Name: string;
  Index, Base, Last, Found: Integer;
begin
  if Deck = '' then
  begin
    Versions.ListNames(Revision, 0, Dest);
    Exit;
  end;
  Name := DeckName(Deck);
  for Index := 0 to Versions.Count - 1 do
  begin
    Versions.Bounds(Versions.Entries[Index].Name, Revision, Base, Last);
    Found := FindDeckRevision(Name, Last);
    if (Found > 0) and not RevisionDeletedAt(Found) then
      Dest.Add(Versions.Entries[Index].Name);
  end;
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
  Result := FormatFixed(FStore[Revision - 1].Number, 3);
end;

function TDeckLibrary.ParseLibrarySnapshot(const Selector: string): TLibrarySnapshot;
var
  Base: Integer;
begin
  if SameText(Selector, CurrentVersionSelector) then
    Exit(CurrentSnapshot);
  if SameText(Selector, PreviousVersionSelector) then
  begin
    if not TryPreviousSnapshot(Result) then
      raise EScuError.CreateFmt('No locked version precedes current version %s.', [CurrentVersion]);
    Exit;
  end;
  VersionBounds(Selector, Base, Result.LibraryRevision);
  Result.Version := Selector;
end;

function TDeckLibrary.TryDeckSnapshot(const Deck: string; LibraryRevision: Integer;
  out Snapshot: TLibrarySnapshot): Boolean;
begin
  Snapshot := Default(TLibrarySnapshot);
  Snapshot.LibraryRevision := FindDeckRevision(DeckName(Deck), LibraryRevision);
  Result := (Snapshot.LibraryRevision <> 0) and not RevisionDeletedAt(Snapshot.LibraryRevision);
  if Result then
    Snapshot.Version := VersionAt(Snapshot.LibraryRevision)
  else
    Snapshot := Default(TLibrarySnapshot);
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
    if (FStore[Index - 1].Number = Number) and
      (FStore[Index - 1].Name = Name) then
    begin
      Result.LibraryRevision := Index;
      Exit;
    end;
  raise EScuError.CreateFmt('Deck "%s" has no deck version "%s".', [Name, Selector]);
end;

function TDeckLibrary.TryPreviousSnapshot(out Snapshot: TLibrarySnapshot): Boolean;
begin
  Result := Versions.TryPrevious(Snapshot.Version, Snapshot.LibraryRevision);
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

procedure TDeckLibrary.LockVersion(const Description: string);
begin
  Versions.Lock(Description);
  MarkModified;
end;

procedure TDeckLibrary.StartVersion(const Name: string);
begin
  FStore.Header.StartVersion(Name, Revision);
  MarkModified;
end;

function TDeckLibrary.GetVersionCount: Integer;
begin
  Result := Versions.Count;
end;

function TDeckLibrary.GetVersionEntry(Index: Integer): TVersionEntry;
begin
  Result := Versions.Entries[Index];
end;

function TDeckLibrary.CurrentVersion: string;
begin
  Result := Versions.Current;
end;

function TDeckLibrary.VersionAt(Revision: Integer): string;
begin
  Result := Versions.AtRevision(Revision);
end;

function TDeckLibrary.DefaultCommentPrefix(const Version: string): string;
begin
  Result := Versions.CommentPrefix(Version);
end;

function TDeckLibrary.GetHeaderJSON: string;
begin
  Result := FStore.Header.FormatJSON;
end;

function TDeckLibrary.GetLastModifiedDeck: string;
begin
  Result := FStore.Header.LastModifiedDeck;
end;

function TDeckLibrary.GetEditorCount: Integer;
begin
  Result := FStore.Header.EditorCount;
end;

function TDeckLibrary.GetEditorArgument(Index: Integer): string;
begin
  Result := FStore.Header.EditorArguments[Index];
end;

function TDeckLibrary.GetBuildCommand: string;
begin
  Result := FStore.Header.BuildCommand;
end;

procedure TDeckLibrary.Configure(const Settings: TLibrarySettingsChange);
begin
  if FStore.Header.Configure(Settings, Revision) then
    MarkModified;
end;

end.
