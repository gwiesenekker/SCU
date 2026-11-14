unit ScuLibraryRevision;

{$mode objfpc}{$H+}

interface

uses FPJSON;

type
  TLibraryRevision = class
  strict private
    FName, FCommentPrefix, FModifiedUTC, FSHA1, FEncoded: string;
    FNumber: Integer;
    FSize: Int64;
    FPayload: TJSONObject;
    FSourceFieldsRead, FDeleted: Boolean;
    function GetLoaded: Boolean;
    function GetCommentPrefix: string;
    function GetModifiedUTC: string;
    function GetSHA1: string;
    function GetSourcePath: string;
    function GetFileBacked: Boolean;
    function GetCopyMetadataJSON: RawByteString;
    procedure RequireLoaded;
    procedure ReadSourceFields;
  public
    constructor CreateIndex(const Name, Number: string; Sequence: Integer; Deleted: Boolean = False);
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
    property Deleted: Boolean read FDeleted;
    property Loaded: Boolean read GetLoaded;
    property CommentPrefix: string read GetCommentPrefix;
    property ModifiedUTC: string read GetModifiedUTC;
    property SHA1: string read GetSHA1;
    property SourcePath: string read GetSourcePath;
    property FileBacked: Boolean read GetFileBacked;
    property CopyMetadataJSON: RawByteString read GetCopyMetadataJSON;
  end;


function NewRevisionPayload(const Name, Prefix, SHA1: string; Number: Integer;
  const Source: RawByteString): TJSONObject;
function NewDeletionPayload(const Name, Prefix: string; Number: Integer): TJSONObject;

implementation

uses SysUtils, DateUtils, ScuCodec, ScuClock, ScuErrors, ScuJSON, ScuRevisionJSON,
  ScuVersionNumbers, ScuVersions, ScuLibraryNames;

function ParseDeckNumber(const Value: string; Sequence: Integer): Integer;
var
  Number: Int64;
begin
  if not TryParseFixed(Value, 3, Number) or (Number < 0) or (Number > MaxDeckRevision) then
    raise EScuError.CreateFmt('Invalid deck revision in library revision %d.', [Sequence]);
  Result := Number;
end;

constructor TLibraryRevision.CreateIndex(const Name, Number: string; Sequence: Integer; Deleted: Boolean);
begin
  inherited Create;
  FName := Name;
  if FName <> DeckName(FName) then
    raise EScuError.CreateFmt('Invalid deck name in revision %d.', [Sequence]);
  FNumber := ParseDeckNumber(Number, Sequence);
  FDeleted := Deleted;
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
  FDeleted := RevisionPayloadDeleted(Payload);
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
  if RevisionPayloadDeleted(Payload) <> Deleted then
    raise EScuError.Create('The SQLite deletion flag does not match its payload.');
  Field(Payload, 'zstd_base64', jtString, Context);
  FPayload := Payload;
  Payload := nil;
end;

procedure TLibraryRevision.SetLegacyNumber(Value: Integer);
begin
  if FNumber <> -1 then
    raise EScuError.Create('A stored deck revision number cannot be changed.');
  if (Value < 0) or (Value > MaxDeckRevision) then
    raise EScuError.Create('A legacy deck revision must be between 0.000 and 0.999.');
  FNumber := Value;
end;

function TLibraryRevision.GetLoaded: Boolean;
begin
  Result := Assigned(FPayload);
end;

function TLibraryRevision.GetSourcePath: string;
var RawPath: RawByteString;
begin
  RequireLoaded;
  Result := Name;
  if Assigned(FPayload.Find('source_path_bytes')) then
  begin
    Result := DecodeBytesHex(Field(FPayload, 'source_path_bytes', jtString, 'Deck source filename').AsString, 'Deck source filename');
    ValidateRelativeSourcePath(Result);
    Exit;
  end;
  if Assigned(FPayload.Find('source_path')) then
  begin
    RawPath := Field(FPayload, 'source_path', jtString, 'Deck "' + Name + '" revision payload').AsString;
    SetCodePage(RawPath, CP_UTF8, False);
    Result := RawPath;
    ValidateRelativeSourcePath(Result);
  end;
end;

function TLibraryRevision.GetFileBacked: Boolean;
begin
  RequireLoaded;
  Result := False;
  if Assigned(FPayload.Find('file_backed')) then
    Result := Field(FPayload, 'file_backed', jtBoolean, 'Deck "' + Name + '" revision payload').AsBoolean;
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
begin
  Decode;
end;

function TLibraryRevision.Decode: RawByteString;
begin
  ReadSourceFields;
  Result := DecodeDeck(FEncoded, FSHA1, FSize);
  if Deleted and (Result <> '') then
    raise EScuError.CreateFmt('Deletion revision for deck "%s" contains source.', [Name]);
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
  except
    Result.Free;
    raise;
  end;
end;

function NewDeletionPayload(const Name, Prefix: string; Number: Integer): TJSONObject;
begin
  Result := NewRevisionPayload(Name, Prefix, DeckSHA1(''), Number, '');
  Result.Add('deleted', True);
end;

end.
