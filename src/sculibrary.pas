unit ScuLibrary;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, ScuLibraryModel, ScuLibraryStore, ScuVersions, ScuSQLite;

const
  CurrentDeckVersionSelector = 'scu$current_deck_version';
  PreviousDeckVersionSelector = 'scu$previous_deck_version';
  LastModifiedDeckSelector = 'scu$last_modified_deck';

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
  end;

  TLibrarySave = ScuLibraryStore.TLibrarySave;
  TLibrarySettingsChange = ScuLibraryModel.TLibrarySettingsChange;

  TDeckLibrary = class
  private
    FStore: TLibraryStore;
    FModified: Boolean;
    function Versions: TVersionHistory;
    function GetRevision: Integer;
    function FindDeckRevision(const Name: string; LastRevision: Integer): Integer;
    function GetHeaderJSON: string;
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
    function Extract(Database: TSQLiteLibrary; const Deck: string; LibraryRevision: Integer;
      const SelectedVersion: string = ''): TDeckSource;
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
    property Revision: Integer read GetRevision;
    property Modified: Boolean read FModified;
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
  FModified := True;
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
  FModified := True;
end;

destructor TDeckLibrary.Destroy;
begin
  FStore.Free;
  inherited Destroy;
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
    Previous := FStore.PayloadAt(PreviousRevision - 1, Database);
  CommentPrefix := Prefix;
  if (CommentPrefix = '') and Assigned(Previous) then
    CommentPrefix := Previous.CommentPrefix;
  if CommentPrefix = '' then
    CommentPrefix := DefaultCommentPrefix(CurrentVersion);
  ValidateCommentPrefix(CommentPrefix);
  Digest := DeckSHA1(Source);
  Number := 0;
  if PreviousRevision > Base then
  begin
    if (CommentPrefix = Previous.CommentPrefix) and (Digest = Previous.SHA1) and
      (Previous.Decode = Source) then
      Exit(0);
    Number := Previous.Number + FStore.Header.RevisionStep;
    if Number > MaxDeckRevision then
      raise EScuError.CreateFmt('Deck "%s" has reached the revision limit. Lock version %s and start a new version.',
        [Name, CurrentVersion]);
  end;
  Payload := NewRevisionPayload(Name, CommentPrefix, Digest, Number, Source);
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
  FModified := True;
  Result := Revision;
end;

function TDeckLibrary.Extract(Database: TSQLiteLibrary; const Deck: string; LibraryRevision: Integer;
  const SelectedVersion: string): TDeckSource;
var
  Name: string;
  Entry: TLibraryRevision;
  StoredRevision: Integer;
begin
  Name := DeckName(Deck);
  StoredRevision := FindDeckRevision(Name, LibraryRevision);
  if StoredRevision = 0 then
  begin
    if SelectedVersion <> '' then
      raise EScuError.CreateFmt('Deck "%s" does not exist in version %s.', [Name, SelectedVersion]);
    raise EScuError.CreateFmt('Deck "%s" does not exist at revision %d.', [Name, LibraryRevision]);
  end;
  Entry := FStore.PayloadAt(StoredRevision - 1, Database);
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
      Dest.Add(Format('%d'#9'%s'#9'%s'#9'%s', [Index + 1, VersionAt(Index + 1),
        FStore.PayloadAt(Index, Database).ModifiedUTC, DeckVersionAt(Index + 1)]));
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
  Index, Latest, FirstRevision: Integer;
begin
  Latest := Revision;
  FirstRevision := 0;
  if Deck <> '' then
  begin
    Name := DeckName(Deck);
    Index := 0;
    while (Index < Latest) and (FStore[Index].Name <> Name) do
      Inc(Index);
    if Index = Latest then
      Exit;
    FirstRevision := Index + 1;
  end;
  Versions.ListNames(Latest, FirstRevision, Dest);
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
  FModified := True;
end;

procedure TDeckLibrary.StartVersion(const Name: string);
begin
  FStore.Header.StartVersion(Name, Revision);
  FModified := True;
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
    FModified := True;
end;

end.
