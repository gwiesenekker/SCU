unit ScuLibraryModel;

{$mode objfpc}{$H+}

interface

uses
  FPJSON, ScuVersions;

const
  MaxDeckRevision = 999;

type
  TLibrarySettingsChange = record
    ChangePrefix, ChangeBuild: Boolean;
    Prefix, BuildCommand, VersionIncrement, RevisionIncrement: string;
    Editor: TJSONArray; // Borrowed during Configure.
  end;

  TLibraryHeader = class
  private
    FSerialized: TJSONObject; // Borrowed from the store's metadata document.
    FVersions: TVersionHistory;
    FEditor: array of string;
    FLastModifiedDeck, FBuildCommand, FVersionIncrement, FRevisionIncrement: string;
    FVersionStep, FRevisionStep: Int64;
    function GetEditorCount: Integer;
    function GetEditorArgument(Index: Integer): string;
  public
    constructor Create(Header: TJSONObject; RevisionCount: Integer; const LastDeck: string);
    destructor Destroy; override;
    function Configure(const Settings: TLibrarySettingsChange; RevisionCount: Integer): Boolean;
    procedure SetLastModifiedDeck(const Deck: string);
    procedure StartVersion(const Name: string; RevisionCount: Integer);
    function CloneJSON: TJSONObject;
    function FormatJSON: string;
    function Digest: string;
    property Versions: TVersionHistory read FVersions;
    property LastModifiedDeck: string read FLastModifiedDeck;
    property BuildCommand: string read FBuildCommand;
    property RevisionStep: Int64 read FRevisionStep;
    property EditorCount: Integer read GetEditorCount;
    property EditorArguments[Index: Integer]: string read GetEditorArgument;
  end;

  TLibraryRevision = class
  private
    FName, FCommentPrefix, FModifiedUTC, FSHA1, FEncoded: string;
    FNumber: Integer;
    FSize: Int64;
    FPayload: TJSONObject;
    FSourceFieldsRead: Boolean;
    function GetLoaded: Boolean;
    function GetCommentPrefix: string;
    function GetModifiedUTC: string;
    function GetSHA1: string;
    function GetCopyMetadataJSON: RawByteString;
    procedure RequireLoaded;
    procedure ReadSourceFields;
  public
    constructor CreateIndex(const Name, Number: string; Sequence: Integer);
    constructor CreatePayload(var Payload: TJSONObject; Sequence: Integer);
    destructor Destroy; override;
    procedure LoadPayload(var Payload: TJSONObject);
    procedure SetLegacyNumber(Value: Integer);
    procedure ValidateRecoveredSource(Sequence: Integer);
    function Decode: RawByteString;
    function CloneJSON: TJSONObject;
    function Serialized: RawByteString;
    property Name: string read FName;
    property Number: Integer read FNumber;
    property Loaded: Boolean read GetLoaded;
    property CommentPrefix: string read GetCommentPrefix;
    property ModifiedUTC: string read GetModifiedUTC;
    property SHA1: string read GetSHA1;
    property CopyMetadataJSON: RawByteString read GetCopyMetadataJSON;
  end;

function NewLibraryMetadata(const Version: string): TJSONObject;
function NewRevisionPayload(const Name, Prefix, SHA1: string; Number: Integer;
  const Source: RawByteString): TJSONObject;
function DeckName(const Name: string): string;

implementation

uses
  SysUtils, DateUtils, ScuCodec, ScuCopyMetadata, ScuClock, ScuErrors, ScuJSON, ScuVersionNumbers;

const
  DefaultVersionIncrement = '0.01';
  DefaultRevisionIncrement = '0.001';
  MaxVersionIncrement = Int64(High(Integer)) * 100 + 99;

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

procedure ValidateEditor(Args: TJSONArray; const Source: string);
var
  Index: Integer;
begin
  if (Args.Count = 0) or (Args.Items[0].JSONType <> jtString) or (Args.Strings[0] = '') then
    raise EScuError.CreateFmt('%s: The editor must be a JSON array beginning with an executable.', [Source]);
  for Index := 0 to Args.Count - 1 do
    if (Args.Items[Index].JSONType <> jtString) or (Pos(#0, Args.Strings[Index]) > 0) then
      raise EScuError.CreateFmt('%s: Editor arguments must be strings without NUL bytes.', [Source]);
end;

function NewLibraryMetadata(const Version: string): TJSONObject;
var
  Header: TJSONObject;
  Editor, Versions: TJSONArray;
  History: TVersionHistory;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('format', 1);
    Header := TJSONObject.Create;
    Result.Add('header', Header);
    Header.Add('current_version', Version);
    Header.Add('last_modified_deck', '');
    Header.Add('version_increment', DefaultVersionIncrement);
    Header.Add('revision_increment', DefaultRevisionIncrement);
    Header.Add('build_command', '');
    Header.Add('comment_prefix', '//');
    Editor := TJSONArray.Create;
    Header.Add('editor', Editor);
    Editor.Add('vi');
    Versions := TJSONArray.Create;
    Header.Add('versions', Versions);
    History := TVersionHistory.Create(Versions, 0);
    try
      History.Start(Version, '//', 0);
    finally
      History.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

constructor TLibraryHeader.Create(Header: TJSONObject; RevisionCount: Integer; const LastDeck: string);
var
  Entries, Editor: TJSONArray;
  Index: Integer;
begin
  inherited Create;
  FSerialized := Header;
  Entries := TJSONArray(Field(Header, 'versions', jtArray));
  if Entries.Count = 0 then
    raise EScuError.Create('Library has no versions.');
  FVersions := TVersionHistory.Create(Entries, RevisionCount);
  if (Field(Header, 'current_version', jtString).AsString <> FVersions.Current) or
    (Field(Header, 'comment_prefix', jtString).AsString <> FVersions.CommentPrefix(FVersions.Current)) then
    raise EScuError.Create('The library header does not match the current version.');
  Editor := TJSONArray(Field(Header, 'editor', jtArray));
  ValidateEditor(Editor, 'Library header');
  SetLength(FEditor, Editor.Count);
  for Index := 0 to Editor.Count - 1 do
    FEditor[Index] := Editor.Strings[Index];

  // Apply legacy defaults in the historical order before computing audit digests.
  if not Assigned(Header.Find('build_command')) then
    Header.Add('build_command', '');
  FBuildCommand := Field(Header, 'build_command', jtString).AsString;
  if Pos(#0, FBuildCommand) > 0 then
    raise EScuError.Create('The build command cannot contain NUL bytes.');
  if not Assigned(Header.Find('version_increment')) then
    Header.Add('version_increment', DefaultVersionIncrement);
  if not Assigned(Header.Find('revision_increment')) then
    Header.Add('revision_increment', DefaultRevisionIncrement);
  FVersionIncrement := Field(Header, 'version_increment', jtString).AsString;
  FRevisionIncrement := Field(Header, 'revision_increment', jtString).AsString;
  FVersionStep := ParseIncrement(FVersionIncrement, 'version_increment', 2, MaxVersionIncrement);
  FRevisionStep := ParseIncrement(FRevisionIncrement, 'revision_increment', 3, MaxDeckRevision);
  if not Assigned(Header.Find('last_modified_deck')) then
    Header.Add('last_modified_deck', LastDeck);
  FLastModifiedDeck := Field(Header, 'last_modified_deck', jtString).AsString;
  if FLastModifiedDeck <> LastDeck then
    raise EScuError.Create('The last_modified_deck header does not match the revision history.');
end;

destructor TLibraryHeader.Destroy;
begin
  FVersions.Free;
  inherited Destroy;
end;

function TLibraryHeader.GetEditorCount: Integer;
begin
  Result := Length(FEditor);
end;

function TLibraryHeader.GetEditorArgument(Index: Integer): string;
begin
  Result := FEditor[Index];
end;

procedure TLibraryHeader.SetLastModifiedDeck(const Deck: string);
begin
  FSerialized.Strings['last_modified_deck'] := Deck;
  FLastModifiedDeck := Deck;
end;

procedure TLibraryHeader.StartVersion(const Name: string; RevisionCount: Integer);
var
  Next: string;
begin
  Next := Name;
  if Next = '' then
    Next := Versions.NextVersion(FVersionStep);
  Versions.Start(Next, Versions.CommentPrefix(Versions.Current), RevisionCount);
  FSerialized.Strings['current_version'] := Versions.Current;
end;

function TLibraryHeader.CloneJSON: TJSONObject;
begin
  Result := TJSONObject(FSerialized.Clone);
end;

function TLibraryHeader.FormatJSON: string;
begin
  Result := FSerialized.FormatJSON;
end;

function TLibraryHeader.Digest: string;
begin
  Result := AuditSHA256(FSerialized.AsJSON);
end;

function TLibraryHeader.Configure(const Settings: TLibrarySettingsChange; RevisionCount: Integer): Boolean;
var
  VersionValue, RevisionValue: string;
  VersionStep, NewRevisionStep: Int64;
  Index: Integer;
begin
  Result := False;
  VersionValue := FVersionIncrement;
  RevisionValue := FRevisionIncrement;
  VersionStep := FVersionStep;
  NewRevisionStep := FRevisionStep;
  if Settings.VersionIncrement <> '' then
  begin
    VersionStep := ParseIncrement(Settings.VersionIncrement, 'version_increment', 2, MaxVersionIncrement);
    VersionValue := FormatFixed(VersionStep, 2);
  end;
  if Settings.RevisionIncrement <> '' then
  begin
    NewRevisionStep := ParseIncrement(Settings.RevisionIncrement, 'revision_increment', 3, MaxDeckRevision);
    RevisionValue := FormatFixed(NewRevisionStep, 3);
  end;
  if Assigned(Settings.Editor) then
    ValidateEditor(Settings.Editor, 'Invalid value for --editor');
  if Settings.ChangeBuild and (Pos(#0, Settings.BuildCommand) > 0) then
    raise EScuError.Create('The build command cannot contain NUL bytes.');
  if Settings.ChangePrefix and (Settings.Prefix <> Versions.CommentPrefix(Versions.Current)) then
  begin
    Versions.SetCommentPrefix(Settings.Prefix, RevisionCount);
    FSerialized.Strings['comment_prefix'] := Settings.Prefix;
    Result := True;
  end;
  if VersionValue <> FVersionIncrement then
  begin
    FSerialized.Strings['version_increment'] := VersionValue;
    FVersionIncrement := VersionValue;
    FVersionStep := VersionStep;
    Result := True;
  end;
  if RevisionValue <> FRevisionIncrement then
  begin
    FSerialized.Strings['revision_increment'] := RevisionValue;
    FRevisionIncrement := RevisionValue;
    FRevisionStep := NewRevisionStep;
    Result := True;
  end;
  if Assigned(Settings.Editor) and (Settings.Editor.AsJSON <> Field(FSerialized, 'editor', jtArray).AsJSON) then
  begin
    // Replacing the editor historically moves its field to the end of the header.
    FSerialized.Delete('editor');
    FSerialized.Add('editor', Settings.Editor.Clone);
    SetLength(FEditor, Settings.Editor.Count);
    for Index := 0 to Settings.Editor.Count - 1 do
      FEditor[Index] := Settings.Editor.Strings[Index];
    Result := True;
  end;
  if Settings.ChangeBuild and (Settings.BuildCommand <> FBuildCommand) then
  begin
    FSerialized.Strings['build_command'] := Settings.BuildCommand;
    FBuildCommand := Settings.BuildCommand;
    Result := True;
  end;
end;

function ParseDeckNumber(const Value: string; Sequence: Integer): Integer;
var
  Number: Int64;
begin
  if not TryParseFixed(Value, 3, Number) or (Number < 0) or (Number > MaxDeckRevision) then
    raise EScuError.CreateFmt('Invalid deck revision in library revision %d.', [Sequence]);
  Result := Number;
end;

constructor TLibraryRevision.CreateIndex(const Name, Number: string; Sequence: Integer);
begin
  inherited Create;
  FName := Name;
  if FName <> DeckName(FName) then
    raise EScuError.CreateFmt('Invalid deck name in revision %d.', [Sequence]);
  FNumber := ParseDeckNumber(Number, Sequence);
end;

constructor TLibraryRevision.CreatePayload(var Payload: TJSONObject; Sequence: Integer);
begin
  inherited Create;
  FName := Field(Payload, 'deck', jtString).AsString;
  if FName <> DeckName(FName) then
    raise EScuError.CreateFmt('Invalid deck name in revision %d.', [Sequence]);
  FNumber := -1;
  if Assigned(Payload.Find('deck_revision')) then
    FNumber := ParseDeckNumber(Field(Payload, 'deck_revision', jtString).AsString, Sequence);
  FPayload := Payload;
  Payload := nil;
end;

destructor TLibraryRevision.Destroy;
begin
  FPayload.Free;
  inherited Destroy;
end;

procedure TLibraryRevision.RequireLoaded;
begin
  if not Loaded then
    raise EScuError.CreateFmt('Revision payload for deck "%s" has not been loaded.', [Name]);
end;

procedure TLibraryRevision.ReadSourceFields;
var
  Stamp: TDateTime;
  Context: string;
begin
  if FSourceFieldsRead then
    Exit;
  RequireLoaded;
  Context := 'Deck "' + Name + '" revision payload';
  FCommentPrefix := '';
  if Assigned(FPayload.Find('comment_prefix')) then
  begin
    FCommentPrefix := Field(FPayload, 'comment_prefix', jtString, Context).AsString;
    ValidateCommentPrefix(FCommentPrefix);
  end;
  FModifiedUTC := Field(FPayload, 'modified_utc', jtString, Context).AsString;
  if not TryISO8601ToDate(FModifiedUTC, Stamp) or (UtcTimestamp(Stamp) <> FModifiedUTC) then
    raise EScuError.CreateFmt('Invalid modification timestamp for deck "%s".', [Name]);
  FEncoded := Field(FPayload, 'zstd_base64', jtString, Context).AsString;
  FSHA1 := Field(FPayload, 'sha1', jtString, Context).AsString;
  FSize := IntegerField(FPayload, 'size', Context);
  FSourceFieldsRead := True;
end;

procedure TLibraryRevision.LoadPayload(var Payload: TJSONObject);
var
  PayloadNumber: Int64;
  Context: string;
begin
  Context := 'Deck "' + Name + '" revision payload';
  if Loaded then
    raise EScuError.Create('The revision payload is already loaded.');
  if Field(Payload, 'deck', jtString, Context).AsString <> Name then
    raise EScuError.Create('The SQLite deck name does not match its payload.');
  if Assigned(Payload.Find('deck_revision')) and
    (not TryParseFixed(Field(Payload, 'deck_revision', jtString, Context).AsString, 3, PayloadNumber) or
    (PayloadNumber <> FNumber)) then
    raise EScuError.Create('The SQLite deck revision does not match its payload.');
  Field(Payload, 'zstd_base64', jtString, Context);
  FPayload := Payload;
  Payload := nil;
end;

procedure TLibraryRevision.SetLegacyNumber(Value: Integer);
begin
  FNumber := Value;
end;

function TLibraryRevision.GetLoaded: Boolean;
begin
  Result := Assigned(FPayload);
end;

function TLibraryRevision.GetCommentPrefix: string;
begin
  ReadSourceFields;
  Result := FCommentPrefix;
end;

function TLibraryRevision.GetModifiedUTC: string;
begin
  ReadSourceFields;
  Result := FModifiedUTC;
end;

function TLibraryRevision.GetSHA1: string;
begin
  ReadSourceFields;
  Result := FSHA1;
end;

function TLibraryRevision.GetCopyMetadataJSON: RawByteString;
var
  Metadata: TJSONData;
begin
  RequireLoaded;
  Metadata := FPayload.Find('copy_metadata');
  if Assigned(Metadata) then
    Exit(Metadata.AsJSON);
  Result := '';
end;

procedure TLibraryRevision.ValidateRecoveredSource(Sequence: Integer);
var
  Metadata: TJSONObject;
  Source: RawByteString;
begin
  Source := Decode;
  if CommentPrefix = '' then
  begin
    if Assigned(FPayload.Find('copy_metadata')) then
      raise EScuError.CreateFmt('COPY metadata for deck "%s" requires a stored comment prefix.', [Name]);
    Exit;
  end;
  Metadata := ScanCopyMetadata(Source, CommentPrefix);
  try
    if not Assigned(FPayload.Find('copy_metadata')) then
    begin
      FPayload.Add('copy_metadata', Metadata);
      Metadata := nil;
    end
    else if Field(FPayload, 'copy_metadata', jtObject).AsJSON <> Metadata.AsJSON then
      raise EScuError.CreateFmt('COPY metadata does not match recovered revision %d.', [Sequence]);
  finally
    Metadata.Free;
  end;
end;

function TLibraryRevision.Decode: RawByteString;
begin
  ReadSourceFields;
  Result := DecodeDeck(FEncoded, FSHA1, FSize);
end;

function TLibraryRevision.CloneJSON: TJSONObject;
begin
  RequireLoaded;
  Result := TJSONObject(FPayload.Clone);
end;

function TLibraryRevision.Serialized: RawByteString;
begin
  RequireLoaded;
  Result := FPayload.AsJSON;
end;

function NewRevisionPayload(const Name, Prefix, SHA1: string; Number: Integer;
  const Source: RawByteString): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('deck', Name);
    Result.Add('deck_revision', FormatFixed(Number, 3));
    Result.Add('comment_prefix', Prefix);
    Result.Add('size', Length(Source));
    Result.Add('sha1', SHA1);
    Result.Add('modified_utc', UtcTimestamp(UtcNow));
    Result.Add('zstd_base64', EncodeDeck(Source));
    Result.Add('copy_metadata', ScanCopyMetadata(Source, Prefix));
  except
    Result.Free;
    raise;
  end;
end;

end.
