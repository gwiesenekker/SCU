unit ScuSQLiteRevision;

{$mode objfpc}{$H+}

interface

uses
  ScuSQLiteDB, FPJSON;

type
  TRevisionIndexVisitor = procedure(const Deck, DeckRevision: string; Deleted: Boolean) of object;

  TSQLiteRevisionStore = class
  private
    FDatabase: TSQLiteConnection;
    FSchemaVersion: Integer;
  public
    constructor Create(Database: TSQLiteConnection; SchemaVersion: Integer);
    function StateKey: string;
    function ReadSourcePath(Sequence: Integer): RawByteString;
    function MatchesDeckHistory(const Deck: string; const Bytes: RawByteString): Boolean;
    function HasSource(const Deck, DeckVersion, SHA1: string): Boolean;
    function RevisionCount: Integer;
    // The caller owns the returned JSON object.
    function ReadMetadata: TJSONObject;
    function ReadCurrentVersion: string;
    procedure ReadRevisionIndex(Visit: TRevisionIndexVisitor);
    // The caller owns the returned JSON objects.
    function ReadRevision(Sequence: Integer): TJSONObject;
    function ReadRevisionCopyMetadata(Sequence: Integer): RawByteString;
    procedure SaveMetadata(const Payload: RawByteString);
    procedure RemoveVersionTail(KeepCount: Integer; const Version: string);
    procedure AppendRevision(Sequence: Integer;
      const Deck, Version, DeckRevision, Payload, CopyMetadata: RawByteString; Deleted: Boolean);
  end;

implementation

uses
  SysUtils, ScuErrors, ScuCodec, ScuJSON, ScuRevisionJSON, ScuLibraryRevision, ScuSignals;

constructor TSQLiteRevisionStore.Create(Database: TSQLiteConnection; SchemaVersion: Integer);
begin
  inherited Create;
  FDatabase := Database;
  FSchemaVersion := SchemaVersion;
end;

function TSQLiteRevisionStore.StateKey: string;
begin
  Result := FDatabase.Scalar('SELECT identity || '':'' || generation FROM library WHERE id = 1');
end;

function TSQLiteRevisionStore.ReadSourcePath(Sequence: Integer): RawByteString;
var Statement: TSQLiteStatement;
begin
  // Return just the filename; building the ownership index must not retain
  // the compressed sources of every other deck in memory.
  Statement := FDatabase.Prepare('SELECT json_extract(payload, ''$.source_path_bytes''), ' +
    'coalesce(json_extract(payload, ''$.source_path''), deck_name) FROM deck_revisions WHERE sequence=?');
  try
    Statement.Bind(1, Sequence);
    if not Statement.Step then raise EScuError.CreateFmt('Missing deck revision %d.', [Sequence]);
    Result := Statement.Text[0];
    if Result <> '' then Result := DecodeBytesHex(Result, 'Deck source filename')
    else Result := Statement.Text[1];
  finally Statement.Free; end;
end;

function TSQLiteRevisionStore.MatchesDeckHistory(const Deck: string; const Bytes: RawByteString): Boolean;
var Statement: TSQLiteStatement; Payload: TJSONObject; Revision: TLibraryRevision; Sequence: Integer;
begin
  Statement := FDatabase.Prepare('SELECT sequence FROM deck_revisions WHERE deck_name=? AND deleted=0 ' +
    'AND json_extract(payload, ''$.sha1'')=? ORDER BY sequence DESC');
  try
    Statement.Bind(1, Deck);
    Statement.Bind(2, DeckSHA1(Bytes));
    while Statement.Step do
    begin
      CheckSessionInterrupt;
      Sequence := Statement.Integers[0];
      Payload := ReadRevision(Sequence);
      try
        Revision := TLibraryRevision.CreatePayload(Payload, Sequence);
        try
          if (Revision.Name = Deck) and (Revision.Decode = Bytes) then Exit(True);
        finally Revision.Free; end;
      finally Payload.Free; end;
    end;
    Result := False;
  finally Statement.Free; end;
end;

function TSQLiteRevisionStore.HasSource(const Deck, DeckVersion, SHA1: string): Boolean;
var Separator: Integer; Statement: TSQLiteStatement;
begin
  Separator := Pos('-', DeckVersion);
  Statement := FDatabase.Prepare('SELECT json_extract(payload, ''$.sha1'') FROM deck_revisions ' +
    'WHERE deck_name=? AND library_version=? AND deck_revision=? AND deleted=0');
  try
    Statement.Bind(1, Deck);
    Statement.Bind(2, Copy(DeckVersion, 1, Separator - 1));
    Statement.Bind(3, Copy(DeckVersion, Separator + 1, MaxInt));
    Result := Statement.Step and (Statement.Text[0] = SHA1);
  finally Statement.Free; end;
end;

function TSQLiteRevisionStore.RevisionCount: Integer;
var
  Statement: TSQLiteStatement;
  Count: Int64;
begin
  Statement := FDatabase.Prepare('SELECT count(*) FROM deck_revisions');
  try
    if not Statement.Step then
      raise EScuError.CreateFmt('Missing SQLite revision count in "%s".', [FDatabase.Path]);
    Count := Statement.Int64s[0];
    if (Count < 0) or (Count > High(Integer)) then
      raise EScuError.CreateFmt('SQLite revision count %d in "%s" is out of range.', [Count, FDatabase.Path]);
    Result := Count;
  finally
    Statement.Free;
  end;
end;

function TSQLiteRevisionStore.ReadMetadata: TJSONObject;
var
  Metadata: RawByteString;
begin
  Metadata := FDatabase.Scalar('SELECT payload FROM library WHERE id = 1');
  if Metadata = '' then
    raise EScuError.Create('The SQLite library has not been initialized.');
  Result := ParseObject(Metadata, 'SQLite library metadata in "' + FDatabase.Path + '"');
end;

function TSQLiteRevisionStore.ReadCurrentVersion: string;
var
  Metadata: TJSONObject;
begin
  Metadata := ReadMetadata;
  try
    Result := Field(TJSONObject(Field(Metadata, 'header', jtObject)), 'current_version', jtString).AsString;
  finally
    Metadata.Free;
  end;
end;

procedure TSQLiteRevisionStore.ReadRevisionIndex(Visit: TRevisionIndexVisitor);
var
  Statement: TSQLiteStatement;
  Sequence: Int64;
begin
  Sequence := 0;
  if FSchemaVersion >= 6 then
    Statement := FDatabase.Prepare('SELECT sequence, deck_name, deck_revision, deleted FROM deck_revisions ORDER BY sequence')
  else
    Statement := FDatabase.Prepare('SELECT sequence, deck_name, deck_revision, 0 FROM deck_revisions ORDER BY sequence');
  try
    while Statement.Step do
    begin
      Inc(Sequence);
      if Statement.Int64s[0] <> Sequence then
        raise EScuError.Create('Invalid SQLite deck revision sequence.');
      Visit(Statement.Text[1], Statement.Text[2], Statement.Int64s[3] <> 0);
    end;
  finally
    Statement.Free;
  end;
end;

function TSQLiteRevisionStore.ReadRevision(Sequence: Integer): TJSONObject;
var
  Statement: TSQLiteStatement;
  Metadata: TJSONData;
  IndexMetadata: RawByteString;
begin
  if FSchemaVersion >= 6 then
    Statement := FDatabase.Prepare('SELECT payload, copy_metadata, deleted FROM deck_revisions WHERE sequence = ?')
  else if FSchemaVersion >= 5 then
    Statement := FDatabase.Prepare('SELECT payload, copy_metadata, 0 FROM deck_revisions WHERE sequence = ?')
  else
    Statement := FDatabase.Prepare('SELECT payload FROM deck_revisions WHERE sequence = ?');
  try
    Statement.Bind(1, Sequence);
    if not Statement.Step then
      raise EScuError.CreateFmt('SQLite library revision %d is missing.', [Sequence]);
    Result := ParseRevisionPayload(Statement.Text[0], Format('SQLite revision %d payload in "%s"', [Sequence, FDatabase.Path]));
    try
      if FSchemaVersion >= 5 then
      begin
        if RevisionPayloadDeleted(Result) <> (Statement.Int64s[2] <> 0) then
          raise EScuError.CreateFmt('SQLite deletion flag does not match revision %d.', [Sequence]);
        Metadata := Result.Find('copy_metadata');
        IndexMetadata := Statement.Text[1];
        if Assigned(Metadata) and (Metadata.AsJSON <> IndexMetadata) then
          raise EScuError.CreateFmt('SQLite COPY metadata does not match revision %d.', [Sequence]);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    Statement.Free;
  end;
end;

function TSQLiteRevisionStore.ReadRevisionCopyMetadata(Sequence: Integer): RawByteString;
var
  Statement: TSQLiteStatement;
begin
  Result := '';
  if FSchemaVersion < 5 then
    Exit;
  Statement := FDatabase.Prepare('SELECT copy_metadata FROM deck_revisions WHERE sequence = ?');
  try
    Statement.Bind(1, Sequence);
    if Statement.Step then
      Result := Statement.Text[0];
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteRevisionStore.SaveMetadata(const Payload: RawByteString);
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('INSERT INTO library VALUES (1, lower(hex(randomblob(16))), 1, ?) ' +
    'ON CONFLICT(id) DO UPDATE SET generation = generation + 1, payload = excluded.payload');
  try
    Statement.Bind(1, Payload);
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteRevisionStore.RemoveVersionTail(KeepCount: Integer; const Version: string);
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('DELETE FROM deck_revisions WHERE sequence > ? AND library_version = ?');
  try
    Statement.Bind(1, KeepCount);
    Statement.Bind(2, Version);
    Statement.Step;
  finally
    Statement.Free;
  end;
  if RevisionCount <> KeepCount then
    raise EScuError.Create('Stored deck revisions do not match the selected version.');

end;

procedure TSQLiteRevisionStore.AppendRevision(Sequence: Integer;
  const Deck, Version, DeckRevision, Payload, CopyMetadata: RawByteString; Deleted: Boolean);
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('INSERT INTO deck_revisions ' +
    '(sequence, deck_name, library_version, deck_revision, payload, copy_metadata, deleted) VALUES (?, ?, ?, ?, ?, ?, ?)');
  try
    Statement.Bind(1, Sequence);
    Statement.Bind(2, Deck);
    Statement.Bind(3, Version);
    Statement.Bind(4, DeckRevision);
    Statement.Bind(5, Payload);
    if CopyMetadata = '' then
      Statement.BindNull(6)
    else
      Statement.Bind(6, CopyMetadata);
    Statement.Bind(7, Ord(Deleted));
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

end.
