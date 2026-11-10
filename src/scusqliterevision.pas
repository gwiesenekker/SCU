unit ScuSQLiteRevision;

{$mode objfpc}{$H+}

interface

uses
  ScuSQLiteDB, FPJSON;

type
  TRevisionIndexVisitor = procedure(const Deck, DeckRevision: string) of object;

  TSQLiteRevisionStore = class
  private
    FDatabase: TSQLiteConnection;
    FSchemaVersion: Integer;
  public
    constructor Create(Database: TSQLiteConnection; SchemaVersion: Integer);
    function StateKey: string;
    function RevisionCount: Integer;
    function ReadMetadata: TJSONObject;
    function ReadCurrentVersion: string;
    procedure ReadRevisionIndex(Visit: TRevisionIndexVisitor);
    function ReadRevision(Sequence: Integer): TJSONObject;
    function ReadCopyMetadata(Revision: Integer): TJSONObject;
    function ReadRevisionCopyMetadata(Sequence: Integer): RawByteString;
    procedure CacheCopyMetadata(Sequence: Integer; const Metadata: RawByteString);
    procedure SaveMetadata(const Payload: RawByteString);
    procedure AppendRevision(Sequence: Integer;
      const Deck, Version, DeckRevision, Payload, CopyMetadata: RawByteString);
  end;

implementation

uses
  SysUtils, ScuErrors, ScuJSON;

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
  Statement := FDatabase.Prepare(
    'SELECT sequence, deck_name, deck_revision FROM deck_revisions ORDER BY sequence');
  try
    while Statement.Step do
    begin
      Inc(Sequence);
      if Statement.Int64s[0] <> Sequence then
        raise EScuError.Create('Invalid SQLite deck revision sequence.');
      Visit(Statement.Text[1], Statement.Text[2]);
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
  if FSchemaVersion >= 5 then
    Statement := FDatabase.Prepare('SELECT payload, copy_metadata FROM deck_revisions WHERE sequence = ?')
  else
    Statement := FDatabase.Prepare('SELECT payload FROM deck_revisions WHERE sequence = ?');
  try
    Statement.Bind(1, Sequence);
    if not Statement.Step then
      raise EScuError.CreateFmt('SQLite library revision %d is missing.', [Sequence]);
    Result := ParseObject(Statement.Text[0], Format('SQLite revision %d payload in "%s"', [Sequence, FDatabase.Path]));
    if FSchemaVersion >= 5 then
    begin
      Metadata := Result.Find('copy_metadata');
      IndexMetadata := Statement.Text[1];
      if Assigned(Metadata) and (Metadata.AsJSON <> IndexMetadata) then
      begin
        Result.Free;
        raise EScuError.CreateFmt('SQLite COPY metadata does not match revision %d.', [Sequence]);
      end;
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

procedure TSQLiteRevisionStore.CacheCopyMetadata(Sequence: Integer; const Metadata: RawByteString);
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('UPDATE deck_revisions SET copy_metadata = ? WHERE sequence = ? AND copy_metadata IS NULL');
  try
    Statement.Bind(1, Metadata);
    Statement.Bind(2, Sequence);
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

function TSQLiteRevisionStore.ReadCopyMetadata(Revision: Integer): TJSONObject;
var
  Statement: TSQLiteStatement;
  Name: string;
begin
  Statement := FDatabase.Prepare('SELECT stored.deck_name, stored.copy_metadata FROM (' +
    'SELECT max(sequence) AS sequence FROM deck_revisions WHERE sequence <= ? GROUP BY deck_name' +
    ') AS visible JOIN deck_revisions AS stored ON stored.sequence = visible.sequence');
  try
    Statement.Bind(1, Revision);
    Result := TJSONObject.Create;
    try
      while Statement.Step do
      begin
        Name := Statement.Text[0];
        if Statement.IsNull(1) then
          Result.Add(Name)
        else
          Result.Add(Name, ParseObject(Statement.Text[1],
            Format('SQLite COPY metadata for deck "%s" in "%s"', [Name, FDatabase.Path])));
      end;
    except
      Result.Free;
      raise;
    end;
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

procedure TSQLiteRevisionStore.AppendRevision(Sequence: Integer;
  const Deck, Version, DeckRevision, Payload, CopyMetadata: RawByteString);
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('INSERT INTO deck_revisions ' +
    '(sequence, deck_name, library_version, deck_revision, payload, copy_metadata) VALUES (?, ?, ?, ?, ?, ?)');
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
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

end.
