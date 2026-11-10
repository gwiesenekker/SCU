unit ScuSQLiteCheckpoint;

{$mode objfpc}{$H+}

interface

uses
  ScuSQLiteDB;

type
  TExpansionCheckpoint = record
    Version, OutputDirectory, BuiltUTC: string;
    Revision, BuiltRevision: Int64;
    FullRebuildPending, HasBuildTime, HasBuiltRevision: Boolean;
  end;

  TExpansionCheckpoints = array of TExpansionCheckpoint;

  TSQLiteCheckpointStore = class
  private
    FDatabase: TSQLiteConnection;
  public
    constructor Create(Database: TSQLiteConnection);
    function ReadExpansionCheckpoints: TExpansionCheckpoints;
    function ReadExpansionCheckpoint(const Version, Directory: string; out Revision: Integer;
      out Refresh, BuildPending: Boolean): Boolean;
    function ResetExpansionCheckpoint(const Version, Directory: string): Boolean;
    function InvalidateExpansionOutput(const Version, Directory, Prefix: string): Boolean;
    procedure SaveExpansionCheckpoint(const Version, Directory, Prefix: string; Revision: Integer;
      BuildPending: Boolean);
  end;

implementation

constructor TSQLiteCheckpointStore.Create(Database: TSQLiteConnection);
begin
  inherited Create;
  FDatabase := Database;
end;

function TSQLiteCheckpointStore.ReadExpansionCheckpoints: TExpansionCheckpoints;
var
  Statement: TSQLiteStatement;
  Count: SizeInt;
  Row: TExpansionCheckpoint;
begin
  // Follow each build's expansion outcome back to the command that produced it.
  Statement := FDatabase.Prepare(
    'WITH events AS MATERIALIZED (' +
      'SELECT sequence, substr(line, 1, 64) AS digest, substr(line, 66) AS payload FROM audit_records' +
    '), successful_builds AS MATERIALIZED (' +
      'SELECT build.sequence, json_extract(build.payload, ''$.utc'') AS built_utc, ' +
        'json_extract(build.payload, ''$.output_path'') AS output_directory, ' +
        'json_extract(outcome.payload, ''$.snapshot.version'') AS version, ' +
        'json_extract(outcome.payload, ''$.snapshot.library_revision'') AS revision ' +
      'FROM events AS build ' +
      'JOIN events AS outcome ON outcome.digest = json_extract(build.payload, ''$.expansion'') ' +
      'JOIN events AS attempt ON attempt.digest = json_extract(outcome.payload, ''$.begin'') ' +
      'WHERE json_extract(build.payload, ''$.phase'') = ''build'' ' +
        'AND json_extract(build.payload, ''$.success'') = 1 ' +
        'AND json_extract(attempt.payload, ''$.command'') = ''expand_modified_decks''' +
    ') ' +
    'SELECT checkpoint.version, checkpoint.output_directory, checkpoint.revision, ' +
      'checkpoint.comment_prefix IS NULL, last_build.built_utc, last_build.revision ' +
    'FROM expansion_checkpoints AS checkpoint ' +
    'LEFT JOIN successful_builds AS last_build ON last_build.sequence = (' +
        'SELECT build.sequence FROM successful_builds AS build ' +
        'WHERE build.version = checkpoint.version AND build.output_directory = checkpoint.output_directory ' +
          'AND build.revision <= checkpoint.revision ORDER BY build.sequence DESC LIMIT 1' +
    ') ORDER BY checkpoint.version, checkpoint.output_directory');
  try
    Result := nil;
    Count := 0;
    while Statement.Step do
    begin
      Row.Version := Statement.Text[0];
      Row.OutputDirectory := Statement.Text[1];
      Row.Revision := Statement.Int64s[2];
      Row.FullRebuildPending := Statement.Integers[3] <> 0;
      Row.HasBuildTime := not Statement.IsNull(4);
      Row.BuiltUTC := Statement.Text[4];
      Row.HasBuiltRevision := not Statement.IsNull(5);
      Row.BuiltRevision := Statement.Int64s[5];
      if Count = Length(Result) then
        SetLength(Result, 2 * Count + 1);
      Result[Count] := Row;
      Inc(Count);
    end;
    SetLength(Result, Count);
  finally
    Statement.Free;
  end;
end;

function TSQLiteCheckpointStore.ReadExpansionCheckpoint(const Version, Directory: string;
  out Revision: Integer; out Refresh, BuildPending: Boolean): Boolean;
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('SELECT revision, comment_prefix, build_pending FROM expansion_checkpoints ' +
    'WHERE version = ? AND output_directory = ?');
  try
    Statement.Bind(1, Version);
    Statement.Bind(2, Directory);
    Result := Statement.Step;
    Revision := 0;
    Refresh := False;
    BuildPending := False;
    if Result then
    begin
      Revision := Statement.Integers[0];
      Refresh := Statement.IsNull(1);
      BuildPending := Statement.Integers[2] <> 0;
    end;
  finally
    Statement.Free;
  end;
end;

function TSQLiteCheckpointStore.ResetExpansionCheckpoint(const Version, Directory: string): Boolean;
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('UPDATE expansion_checkpoints SET comment_prefix = NULL ' +
    'WHERE version = ? AND output_directory = ?');
  try
    Statement.Bind(1, Version);
    Statement.Bind(2, Directory);
    Statement.Step;
    Result := FDatabase.Changes <> 0;
  finally
    Statement.Free;
  end;
end;

function TSQLiteCheckpointStore.InvalidateExpansionOutput(const Version, Directory, Prefix: string): Boolean;
var
  Statement: TSQLiteStatement;
begin
  // NULL preserves the last successful revision while requiring a full refresh.
  // A batch with work can also replace files from a different version.
  Statement := FDatabase.Prepare('UPDATE expansion_checkpoints SET comment_prefix = NULL ' +
    'WHERE output_directory = ?2 AND comment_prefix IS NOT NULL AND (' +
    '(version = ?1 AND comment_prefix <> ?3) OR (version <> ?1 AND EXISTS (' +
    'SELECT 1 FROM deck_revisions WHERE library_version = ?1 AND sequence > COALESCE((' +
    'SELECT revision FROM expansion_checkpoints WHERE version = ?1 AND output_directory = ?2 ' +
    'AND comment_prefix = ?3), 0))))');
  try
    Statement.Bind(1, Version);
    Statement.Bind(2, Directory);
    Statement.Bind(3, Prefix);
    Statement.Step;
    Result := FDatabase.Changes <> 0;
  finally
    Statement.Free;
  end;
end;

procedure TSQLiteCheckpointStore.SaveExpansionCheckpoint(const Version, Directory, Prefix: string;
  Revision: Integer; BuildPending: Boolean);
var
  Statement: TSQLiteStatement;
begin
  Statement := FDatabase.Prepare('INSERT INTO expansion_checkpoints ' +
    '(version, output_directory, revision, comment_prefix, build_pending) VALUES (?, ?, ?, ?, ?) ' +
    'ON CONFLICT(version, output_directory) DO UPDATE SET ' +
    'revision = excluded.revision, comment_prefix = excluded.comment_prefix, build_pending = excluded.build_pending');
  try
    Statement.Bind(1, Version);
    Statement.Bind(2, Directory);
    Statement.Bind(3, Revision);
    Statement.Bind(4, Prefix);
    Statement.Bind(5, Ord(BuildPending));
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

end.
