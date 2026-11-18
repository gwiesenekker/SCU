unit ScuLibrary;

{$mode objfpc}{$H+}

interface

uses
  Classes, Contnrs, FPJSON, ScuLibraryTypes, ScuLibraryQueries, ScuLibraryModel, ScuLibraryStore, ScuVersions, ScuSQLite{$IFDEF WINDOWS}, ScuExportNames{$ENDIF};

const
  CurrentDeckVersionSelector = ScuLibraryTypes.CurrentDeckVersionSelector;
  PreviousDeckVersionSelector = ScuLibraryTypes.PreviousDeckVersionSelector;
  LastModifiedDeckSelector = ScuLibraryTypes.LastModifiedDeckSelector;
  CurrentVersionSelector = ScuLibraryTypes.CurrentVersionSelector;
  LatestVersionSelector = ScuLibraryTypes.LatestVersionSelector;
  PreviousVersionSelector = ScuLibraryTypes.PreviousVersionSelector;
  dsoCreateOnly = ScuLibraryTypes.dsoCreateOnly;
  deoAllowDeleted = ScuLibraryTypes.deoAllowDeleted;
  drLibraryRevision = ScuLibraryTypes.drLibraryRevision;
  drDeckVersion = ScuLibraryTypes.drDeckVersion;

type
  TDeckStoreOptions = ScuLibraryTypes.TDeckStoreOptions;
  TDeckExtractOptions = ScuLibraryTypes.TDeckExtractOptions;
  TDeckRevisionFormats = ScuLibraryTypes.TDeckRevisionFormats;
  TLibrarySnapshot = ScuLibraryTypes.TLibrarySnapshot;
  TDeckSelection = ScuLibraryTypes.TDeckSelection;
  TDeckSource = ScuLibraryTypes.TDeckSource;
  TDeckListEntry = ScuLibraryTypes.TDeckListEntry;
  TDeckListEntries = ScuLibraryTypes.TDeckListEntries;
  TVersionDeckEntry = ScuLibraryTypes.TVersionDeckEntry;
  TVersionDeckEntries = ScuLibraryTypes.TVersionDeckEntries;
  TDeckHistoryEntry = ScuLibraryTypes.TDeckHistoryEntry;
  TDeckHistoryEntries = ScuLibraryTypes.TDeckHistoryEntries;

  TLibrarySave = ScuLibraryStore.TLibrarySave;
  TLibrarySettingsChange = ScuLibraryModel.TLibrarySettingsChange;

  TDeckLibrary = class
  strict private
    FWorkingSources: TFPHashList;
    {$IFDEF WINDOWS}FWorkingSourceKeys: TExportFileKeys;{$ENDIF}
    FStore: TLibraryStore;
    FQueries: TLibraryQueries;
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
    function GetFilePatternCount: Integer;
    function GetFilePattern(Index: Integer): string;
    function GetBuildCommand: string;
    function GetReleaseDirectory: string;
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
    // The caller owns this configuration snapshot, without version history.
    function CreateHeaderConfiguration: TJSONObject;
    function HeaderDigest: string;
    function RevisionDigest(Sequence: Integer; Database: TSQLiteLibrary): string;
    function Store(Database: TSQLiteLibrary; const Deck: string; const Source: RawByteString;
      Options: TDeckStoreOptions = []; const Prefix: string = ''; const SourcePath: string = ''): Integer;
    function DeckSourcePath(Database: TSQLiteLibrary; const Deck: string): string;
    function DeckFileBacked(Database: TSQLiteLibrary; const Deck: string): Boolean;
    function IsWorkingSourceFile(Database: TSQLiteLibrary; const FileName: string): Boolean;
    function Delete(Database: TSQLiteLibrary; const Deck: string): Integer;
    // Returns metadata with Bytes empty; does not decompress the source.
    function ReadDeckMetadata(Database: TSQLiteLibrary; const Deck: string; LibraryRevision: Integer;
      const SelectedVersion: string = ''; Options: TDeckExtractOptions = []): TDeckSource;
    function Extract(Database: TSQLiteLibrary; const Deck: string; LibraryRevision: Integer;
      const SelectedVersion: string = ''; Options: TDeckExtractOptions = []): TDeckSource;
    procedure RequireOpenVersion;
    function DeckList(LibraryRevision: Integer): TDeckListEntries;
    function VersionDecks(Database: TSQLiteLibrary; const Version: string): TVersionDeckEntries;
    function DeckHistory(Database: TSQLiteLibrary; const Deck: string; Limit: Int64 = 0): TDeckHistoryEntries;
    function ListDeckRevisions(const Deck: string; Dest: TStrings; Formats: TDeckRevisionFormats): Integer;
    procedure ChangedDecks(Base, Last: Integer; Dest: TStrings);
    procedure VersionBounds(const Name: string; out Base, Last: Integer);
    procedure ListVersions(Dest: TStrings);
    procedure ListVersionNames(Dest: TStrings; const Deck: string = '');
    function SelectDeck(const Deck, Version, DeckRevision: string): TDeckSelection;
    procedure ListDeckRevisionNames(const Deck, Version: string; Dest: TStrings);
    function ParseDeckSnapshot(const Name, Selector: string): TLibrarySnapshot;
    function ParseLibrarySnapshot(const Selector: string): TLibrarySnapshot;
    function TryDeckSnapshot(const Deck: string; LibraryRevision: Integer;
      out Snapshot: TLibrarySnapshot): Boolean;
    function CurrentSnapshot: TLibrarySnapshot;
    function TryPreviousSnapshot(out Snapshot: TLibrarySnapshot): Boolean;
    function PreviousDeckSnapshot(const Name: string; AtRevision: Integer): TLibrarySnapshot;
    procedure LockVersion(const Description: string);
    function SuggestedNextVersion: string;
    procedure CreateVersion(const Name: string);
    function CurrentVersion: string;
    function VersionAt(Revision: Integer): string;
    function DefaultCommentPrefix(const Version: string): string;
    procedure Configure(const Settings: TLibrarySettingsChange);
    procedure SetFilePatterns(Patterns: TStrings);
    property VersionCount: Integer read GetVersionCount;
    property VersionHistory[Index: Integer]: TVersionEntry read GetVersionEntry;
    property HeaderJSON: string read GetHeaderJSON;
    property EditorCount: Integer read GetEditorCount;
    property EditorArguments[Index: Integer]: string read GetEditorArgument;
    property FilePatternCount: Integer read GetFilePatternCount;
    property FilePatterns[Index: Integer]: string read GetFilePattern;
    property BuildCommand: string read GetBuildCommand;
    property ReleaseDirectory: string read GetReleaseDirectory;
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
  SysUtils, FGL, ScuCodec, ScuErrors, ScuSignals, ScuVersionNumbers;

function DeckName(const Name: string): string;
begin
  Result := ScuLibraryModel.DeckName(Name);
end;

constructor TDeckLibrary.CreateNew(const Path, InitialVersion: string);
begin
  inherited Create;
  FStore := TLibraryStore.CreateNew(Path, InitialVersion);
  FQueries := TLibraryQueries.Create(FStore);
  MarkModified;
end;

constructor TDeckLibrary.Load(const Path: string; Database: TSQLiteLibrary);
begin
  inherited Create;
  FStore := TLibraryStore.Load(Path, Database);
  FQueries := TLibraryQueries.Create(FStore);
end;

constructor TDeckLibrary.CreateRecovered(var Document: TJSONObject);
begin
  inherited Create;
  FStore := TLibraryStore.CreateRecovered(Document);
  FQueries := TLibraryQueries.Create(FStore);
  MarkModified;
end;

destructor TDeckLibrary.Destroy;
begin
  FWorkingSources.Free;
  {$IFDEF WINDOWS}FWorkingSourceKeys.Free;{$ENDIF}
  FQueries.Free;
  FStore.Free;
  inherited Destroy;
end;

procedure TDeckLibrary.MarkModified;
begin
  FreeAndNil(FWorkingSources);
  {$IFDEF WINDOWS}FreeAndNil(FWorkingSourceKeys);{$ENDIF}
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
  Result := FQueries.FindDeckRevision(Name, LastRevision);
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

function TDeckLibrary.CreateHeaderConfiguration: TJSONObject;
begin
  Result := FStore.Header.CloneConfiguration;
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
  Options: TDeckStoreOptions; const Prefix: string; const SourcePath: string): Integer;
var
  Payload: TJSONObject;
  Previous: TLibraryRevision;
  Name, CommentPrefix, Digest, StoredPath: string;
  PreviousRevision, Number: Integer;
  FileBacked, CreateOnly: Boolean;
begin
  CreateOnly := dsoCreateOnly in Options;
  RequireOpenVersion;
  Name := DeckName(Deck);
  PreviousRevision := FindDeckRevision(Name, Revision);
  if CreateOnly and (PreviousRevision > 0) and not RevisionDeletedAt(PreviousRevision) then
    raise EScuError.CreateFmt('Deck "%s" already exists.', [Name]);
  Previous := nil;
  if PreviousRevision > 0 then
    Previous := FStore.PayloadAt(PreviousRevision - 1, Database);
  StoredPath := SourcePath;
  FileBacked := SourcePath <> '';
  if (StoredPath = '') and Assigned(Previous) and not CreateOnly then
  begin
    StoredPath := Previous.SourcePath;
    FileBacked := Previous.FileBacked and not CreateOnly;
  end;
  if StoredPath = '' then
    StoredPath := Name;
  CommentPrefix := Prefix;
  if (CommentPrefix = '') and Assigned(Previous) then
    CommentPrefix := Previous.CommentPrefix;
  if CommentPrefix = '' then
    CommentPrefix := DefaultCommentPrefix(CurrentVersion);
  ValidateCommentPrefix(CommentPrefix);
  Digest := DeckSHA1(Source);
  if Assigned(Previous) and not Previous.Deleted and
    (FileBacked = Previous.FileBacked) and
    (StoredPath = Previous.SourcePath) and
    (CommentPrefix = Previous.CommentPrefix) and (Digest = Previous.SHA1) and
    (Previous.Decode = Source) then
    Exit(0);
  Number := NextDeckNumber(Name, PreviousRevision);
  Payload := NewRevisionPayload(Name, CommentPrefix, Digest, Number, Source);
  Payload.Add('source_path', UTF8Decode(RawByteString(StoredPath)));
  Payload.Add('source_path_bytes', EncodeBytesHex(StoredPath));
  Payload.Add('file_backed', FileBacked);
  Result := AppendDeckRevision(Name, Payload);
end;

function TDeckLibrary.DeckSourcePath(Database: TSQLiteLibrary; const Deck: string): string;
var
  Sequence: Integer;
begin
  Sequence := FindDeckRevision(DeckName(Deck), Revision);
  if Sequence = 0 then
    Exit(DeckName(Deck));
  Result := FStore.PayloadAt(Sequence - 1, Database).SourcePath;
end;

function TDeckLibrary.DeckFileBacked(Database: TSQLiteLibrary; const Deck: string): Boolean;
var
  Sequence: Integer;
begin
  Sequence := FindDeckRevision(DeckName(Deck), Revision);
  Result := (Sequence > 0) and FStore.PayloadAt(Sequence - 1, Database).FileBacked;
end;

function TDeckLibrary.IsWorkingSourceFile(Database: TSQLiteLibrary; const FileName: string): Boolean;
var
  Entries: TDeckListEntries;
  Entry: TDeckListEntry;
  Path: string;
begin
  if not Assigned(FWorkingSources) then
  begin
    FWorkingSources := TFPHashList.Create;
    {$IFDEF WINDOWS}
    try
      FWorkingSourceKeys := TExportFileKeys.Create;
    {$ENDIF}
    Entries := DeckList(Revision);
    for Entry in Entries do
      if DeckFileBacked(Database, Entry.Name) then
      begin
        Path := DeckSourcePath(Database, Entry.Name);
        {$IFDEF WINDOWS}Path := FWorkingSourceKeys.Key(Path);{$ENDIF}
        if FWorkingSources.Find(Path) = nil then FWorkingSources.Add(Path, Pointer(1));
      end;
    {$IFDEF WINDOWS}
    except
      FreeAndNil(FWorkingSources);
      FreeAndNil(FWorkingSourceKeys);
      raise;
    end;
    {$ENDIF}
  end;
  Result := FWorkingSources.Find({$IFDEF WINDOWS}FWorkingSourceKeys.Key(FileName){$ELSE}FileName{$ENDIF}) <> nil;
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
  Payload.Add('source_path', UTF8Decode(RawByteString(FStore.PayloadAt(PreviousRevision - 1, Database).SourcePath)));
  Payload.Add('source_path_bytes', EncodeBytesHex(FStore.PayloadAt(PreviousRevision - 1, Database).SourcePath));
  Payload.Add('file_backed', FStore.PayloadAt(PreviousRevision - 1, Database).FileBacked);
  Result := AppendDeckRevision(Name, Payload);
end;

function TDeckLibrary.RevisionDeletedAt(Sequence: Integer): Boolean;
begin
  Result := FQueries.RevisionDeletedAt(Sequence);
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

function TDeckLibrary.ReadDeckMetadata(Database: TSQLiteLibrary; const Deck: string; LibraryRevision: Integer;
  const SelectedVersion: string; Options: TDeckExtractOptions): TDeckSource;
var
  Name: string;
  Entry: TLibraryRevision;
  StoredRevision: Integer;
begin
  Name := DeckName(Deck);
  StoredRevision := FindDeckRevision(Name, LibraryRevision);
  if (StoredRevision = 0) or (not (deoAllowDeleted in Options) and RevisionDeletedAt(StoredRevision)) then
  begin
    if SelectedVersion <> '' then
      raise EScuError.CreateFmt('Deck "%s" does not exist in version %s.', [Name, SelectedVersion]);
    raise EScuError.CreateFmt('Deck "%s" does not exist at revision %d.', [Name, LibraryRevision]);
  end;
  Entry := FStore.PayloadAt(StoredRevision - 1, Database);
  Result.Deleted := Entry.Deleted;
  Result.LibraryRevision := StoredRevision;
  Result.CommentPrefix := Entry.CommentPrefix;
  Result.SourcePath := Entry.SourcePath;
  Result.ModifiedUTC := Entry.ModifiedUTC;
  Result.DeckVersion := DeckVersionAt(StoredRevision);
  Result.Bytes := '';
end;

function TDeckLibrary.Extract(Database: TSQLiteLibrary; const Deck: string; LibraryRevision: Integer;
  const SelectedVersion: string; Options: TDeckExtractOptions): TDeckSource;
begin
  Result := ReadDeckMetadata(Database, Deck, LibraryRevision, SelectedVersion, Options);
  Result.Bytes := FStore.PayloadAt(Result.LibraryRevision - 1, Database).Decode;
end;

function TDeckLibrary.DeckList(LibraryRevision: Integer): TDeckListEntries;
begin
  Result := FQueries.DeckList(LibraryRevision);
end;

function TDeckLibrary.VersionDecks(Database: TSQLiteLibrary; const Version: string): TVersionDeckEntries;
begin
  Result := FQueries.VersionDecks(Database, Version);
end;

function TDeckLibrary.DeckHistory(Database: TSQLiteLibrary; const Deck: string; Limit: Int64): TDeckHistoryEntries;
begin
  Result := FQueries.DeckHistory(Database, Deck, Limit);
end;

procedure TDeckLibrary.ChangedDecks(Base, Last: Integer; Dest: TStrings);
begin
  FQueries.ChangedDecks(Base, Last, Dest);
end;

function TDeckLibrary.ListDeckRevisions(const Deck: string; Dest: TStrings; Formats: TDeckRevisionFormats): Integer;
begin
  Result := FQueries.ListDeckRevisions(Deck, Dest, Formats);
end;

procedure TDeckLibrary.VersionBounds(const Name: string; out Base, Last: Integer);
begin
  FQueries.VersionBounds(Name, Base, Last);
end;

procedure TDeckLibrary.ListVersions(Dest: TStrings);
begin
  FQueries.ListVersions(Dest);
end;

procedure TDeckLibrary.ListVersionNames(Dest: TStrings; const Deck: string);
begin
  FQueries.ListVersionNames(Dest, Deck);
end;

function TDeckLibrary.SelectDeck(const Deck, Version, DeckRevision: string): TDeckSelection;
begin
  Result := FQueries.SelectDeck(Deck, Version, DeckRevision);
end;

procedure TDeckLibrary.ListDeckRevisionNames(const Deck, Version: string; Dest: TStrings);
begin
  FQueries.ListDeckRevisionNames(Deck, Version, Dest);
end;

function TDeckLibrary.CurrentSnapshot: TLibrarySnapshot;
begin
  Result := FQueries.CurrentSnapshot;
end;

function TDeckLibrary.DeckVersionAt(Revision: Integer): string;
begin
  Result := FQueries.DeckVersionAt(Revision);
end;

function TDeckLibrary.DeckRevisionAt(Revision: Integer): string;
begin
  Result := FQueries.DeckRevisionAt(Revision);
end;

function TDeckLibrary.ParseLibrarySnapshot(const Selector: string): TLibrarySnapshot;
begin
  Result := FQueries.ParseLibrarySnapshot(Selector);
end;

function TDeckLibrary.TryDeckSnapshot(const Deck: string; LibraryRevision: Integer;
  out Snapshot: TLibrarySnapshot): Boolean;
begin
  Result := FQueries.TryDeckSnapshot(Deck, LibraryRevision, Snapshot);
end;

function TDeckLibrary.ParseDeckSnapshot(const Name, Selector: string): TLibrarySnapshot;
begin
  Result := FQueries.ParseDeckSnapshot(Name, Selector);
end;

function TDeckLibrary.TryPreviousSnapshot(out Snapshot: TLibrarySnapshot): Boolean;
begin
  Result := FQueries.TryPreviousSnapshot(Snapshot);
end;

function TDeckLibrary.PreviousDeckSnapshot(const Name: string; AtRevision: Integer): TLibrarySnapshot;
begin
  Result := FQueries.PreviousDeckSnapshot(Name, AtRevision);
end;

procedure TDeckLibrary.LockVersion(const Description: string);
begin
  Versions.Lock(Description);
  MarkModified;
end;

function TDeckLibrary.SuggestedNextVersion: string;
begin Result := FStore.Header.SuggestedNextVersion; end;

procedure TDeckLibrary.CreateVersion(const Name: string);
begin
  FStore.Header.CreateVersion(Name, Revision);
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
  Result := FQueries.CurrentVersion;
end;

function TDeckLibrary.VersionAt(Revision: Integer): string;
begin
  Result := FQueries.VersionAt(Revision);
end;

function TDeckLibrary.DefaultCommentPrefix(const Version: string): string;
begin
  Result := FQueries.DefaultCommentPrefix(Version);
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

function TDeckLibrary.GetReleaseDirectory: string;
begin
  Result := FStore.Header.ReleaseDirectory;
end;

function TDeckLibrary.GetFilePatternCount: Integer;
begin
  Result := FStore.Header.FilePatternCount;
end;

function TDeckLibrary.GetFilePattern(Index: Integer): string;
begin
  Result := FStore.Header.FilePatterns[Index];
end;

procedure TDeckLibrary.SetFilePatterns(Patterns: TStrings);
begin
  if FStore.Header.SetFilePatterns(Patterns) then
    MarkModified;
end;

procedure TDeckLibrary.Configure(const Settings: TLibrarySettingsChange);
begin
  if FStore.Header.Configure(Settings, Revision) then
    MarkModified;
end;

end.
