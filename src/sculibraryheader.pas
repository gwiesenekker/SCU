unit ScuLibraryHeader;

{$mode objfpc}{$H+}

interface

uses Classes, FPJSON, ScuVersions;

type
  TLibrarySettingsChange = record
    ChangeTracker, ChangePrefix, ChangeBuild, ChangeReleaseDirectory: Boolean;
    Prefix, BuildCommand, ReleaseDirectory, VersionIncrement, RevisionIncrement, Platform, VersionTracker: string;
    Editor: TJSONArray; // Borrowed during Configure.
  end;

  TLibraryHeader = class
  strict private
    // Borrowed canonical serialization preserves audited field order and extensions.
    // Typed caches are derived here and updated only by this owner's mutators.
    FSerialized: TJSONObject;
    FVersions: TVersionHistory;
    FEditor, FFilePatterns: array of string;
    FLastModifiedDeck, FBuildCommand, FVersionIncrement, FRevisionIncrement: string;
    FTrackerTemplate, FTrackerModified: string;
    FVersionTracker, FReleaseDirectory: string;
    FRevisionStep: Int64;
    function GetEditorCount: Integer;
    function GetEditorArgument(Index: Integer): string;
    function GetFilePatternCount: Integer;
    function GetFilePattern(Index: Integer): string;
  public
    constructor Create(Header: TJSONObject; RevisionCount: Integer; const LastDeck: string);
    destructor Destroy; override;
    function Configure(const Settings: TLibrarySettingsChange; RevisionCount: Integer): Boolean;
    function SetFilePatterns(Patterns: TStrings): Boolean;
    procedure SetLastModifiedDeck(const Deck: string);
    function SuggestedNextVersion: string;
    procedure DeleteVersion(const Name: string; RevisionCount: Integer; DeleteRevisions: Boolean);
    procedure CreateVersion(const Name: string; RevisionCount: Integer);
    function CloneJSON: TJSONObject;
    // The caller owns the configuration copy; version history is excluded.
    function CloneConfiguration: TJSONObject;
    function Digest: string;
    property Versions: TVersionHistory read FVersions;
    property LastModifiedDeck: string read FLastModifiedDeck;
    property BuildCommand: string read FBuildCommand;
    function SetTrackerTemplate(const Value: string): Boolean;
    property TrackerTemplate: string read FTrackerTemplate;
    property TrackerModified: string read FTrackerModified;
    property VersionTracker: string read FVersionTracker;
    property ReleaseDirectory: string read FReleaseDirectory;
    property RevisionStep: Int64 read FRevisionStep;
    property EditorCount: Integer read GetEditorCount;
    property EditorArguments[Index: Integer]: string read GetEditorArgument;
    property FilePatternCount: Integer read GetFilePatternCount;
    property FilePatterns[Index: Integer]: string read GetFilePattern;
  end;


const
  DefaultTrackerTemplate = '#ifndef VERSION_H' + #10 + '#define VERSION_H' + #10#10 +
    '#define PROJECT_VERSION "SCU$VERSION"' + #10#10 + '#endif' + #10;
  HostPlatform = {$IFDEF WINDOWS}'Windows'{$ELSE}{$IFDEF DARWIN}'macOS'{$ELSE}'Linux'{$ENDIF}{$ENDIF};

function NewLibraryMetadata(const Version: string): TJSONObject;

implementation

uses SysUtils, ScuClock, ScuCodec, ScuErrors, ScuJSON, ScuVersionNumbers, ScuLibraryNames;

const
  DefaultVersionIncrement = '0.01';
  DefaultRevisionIncrement = '0.001';

function ParseIncrement(const Value, Name: string; Places: Integer; Maximum: Int64): Int64;
begin
  if not TryParseFixed(Value, Places, Result) or (Result < 1) or (Result > Maximum) then
    raise EScuError.CreateFmt('Expected a positive %s from %s to %s.',
      [Name, FormatFixed(1, Places), FormatFixed(Maximum, Places)]);
end;

function NormalizeVersionIncrement(const Value: string): string;
var
  Dot: SizeInt;
  Whole, Fraction: string;
  Major, Minor: Int64;
begin
  Dot := Pos('.', Value);
  if Dot = 0 then
  begin
    Whole := Value;
    Fraction := '00';
  end
  else
  begin
    Whole := Copy(Value, 1, Dot - 1);
    Fraction := Copy(Value, Dot + 1, MaxInt);
  end;
  if not TryParseFixed(Whole, 0, Major) or (Major > High(Integer)) or
    (Length(Fraction) > MaxVersionPlaces) or not TryParseFixed(Fraction, 0, Minor) or
    ((Major = 0) and (Minor = 0)) then
    raise EScuError.Create('Expected a positive version_increment with at most ' +
      IntToStr(MaxVersionPlaces) + ' fractional digits and a whole part up to ' + IntToStr(High(Integer)) + '.');
  while (Length(Fraction) > 2) and (Fraction[Length(Fraction)] = '0') do
    SetLength(Fraction, Length(Fraction) - 1);
  if Length(Fraction) = 1 then Fraction := Fraction + '0';
  Result := IntToStr(Major) + '.' + Fraction;
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
    Header.Add('platform', HostPlatform);
    Header.Add('version_tracker', '');
    Header.Add('last_modified_deck', '');
    Header.Add('version_increment', DefaultVersionIncrement);
    Header.Add('revision_increment', DefaultRevisionIncrement);
    Header.Add('build_command', '');
    Header.Add('release_directory', 'release');
    Header.Add('file_patterns', TJSONArray.Create);
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
  Entries, Editor, Patterns: TJSONArray;
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
  if Assigned(Header.Find('version_tracker')) then
    FVersionTracker := Field(Header, 'version_tracker', jtString).AsString;
  if FVersionTracker <> '' then ValidateSourceFileName(FVersionTracker);
  FTrackerTemplate := Header.Get('version_tracker_template', DefaultTrackerTemplate);
  FTrackerModified := Header.Get('version_tracker_modified_utc', '');
  FReleaseDirectory := 'release';
  if Assigned(Header.Find('release_directory')) then
    FReleaseDirectory := Field(Header, 'release_directory', jtString).AsString;
  if (Trim(FReleaseDirectory) = '') or (Pos(#0, FReleaseDirectory) > 0) then
    raise EScuError.Create('release_directory must be a nonempty directory path without NUL bytes.');
  if Pos(#0, FBuildCommand) > 0 then
    raise EScuError.Create('The build command cannot contain NUL bytes.');
  if not Assigned(Header.Find('version_increment')) then
    Header.Add('version_increment', DefaultVersionIncrement);
  if not Assigned(Header.Find('revision_increment')) then
    Header.Add('revision_increment', DefaultRevisionIncrement);
  FVersionIncrement := NormalizeVersionIncrement(Field(Header, 'version_increment', jtString).AsString);
  FRevisionIncrement := Field(Header, 'revision_increment', jtString).AsString;
  FRevisionStep := ParseIncrement(FRevisionIncrement, 'revision_increment', 3, MaxDeckRevision);
  if not Assigned(Header.Find('last_modified_deck')) then
    Header.Add('last_modified_deck', LastDeck);
  FLastModifiedDeck := Field(Header, 'last_modified_deck', jtString).AsString;
  if FLastModifiedDeck <> LastDeck then
    raise EScuError.Create('The last_modified_deck header does not match the revision history.');
  // Missing in older libraries: use an empty list without changing audited JSON.
  if Assigned(Header.Find('file_patterns')) then
  begin
    Patterns := TJSONArray(Field(Header, 'file_patterns', jtArray));
    SetLength(FFilePatterns, Patterns.Count);
    for Index := 0 to Patterns.Count - 1 do
    begin
      if Patterns.Items[Index].JSONType <> jtString then
        raise EScuError.Create('Library file_patterns must contain only strings.');
      // Preserve older selections so they can still be opened and edited.
      // New settings and scans enforce the current directory-only policy.
      ValidateRelativeSourcePath(Patterns.Strings[Index]);
      FFilePatterns[Index] := Patterns.Strings[Index];
    end;
  end;
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

function TLibraryHeader.GetFilePatternCount: Integer;
begin
  Result := Length(FFilePatterns);
end;

function TLibraryHeader.GetFilePattern(Index: Integer): string;
begin
  Result := FFilePatterns[Index];
end;

function TLibraryHeader.SetFilePatterns(Patterns: TStrings): Boolean;
var
  Index: Integer;
  Entries: TJSONArray;
begin
  Result := Patterns.Count <> Length(FFilePatterns);
  for Index := 0 to Patterns.Count - 1 do
  begin
    ValidateFilePattern(Patterns[Index]);
    if (Index >= Length(FFilePatterns)) or (Patterns[Index] <> FFilePatterns[Index]) then
      Result := True;
  end;
  if not Result then
    Exit;
  Entries := TJSONArray.Create;
  try
    for Index := 0 to Patterns.Count - 1 do
      Entries.Add(Patterns[Index]);
    if Assigned(FSerialized.Find('file_patterns')) then
      FSerialized.Delete('file_patterns');
    FSerialized.Add('file_patterns', Entries);
    Entries := nil;
  finally
    Entries.Free;
  end;
  SetLength(FFilePatterns, Patterns.Count);
  for Index := 0 to Patterns.Count - 1 do
    FFilePatterns[Index] := Patterns[Index];
end;

procedure TLibraryHeader.SetLastModifiedDeck(const Deck: string);
begin
  FSerialized.Strings['last_modified_deck'] := Deck;
  FLastModifiedDeck := Deck;
end;

function TLibraryHeader.SuggestedNextVersion: string;
begin Result := Versions.NextVersion(FVersionIncrement); end;

procedure TLibraryHeader.CreateVersion(const Name: string; RevisionCount: Integer);
var
  Next: string;
begin
  Next := Name;
  if Next = '' then
    Next := SuggestedNextVersion;
  Versions.Start(Next, Versions.CommentPrefix(Versions.Current), RevisionCount);
  FSerialized.Strings['current_version'] := Versions.Current;
end;

function TLibraryHeader.CloneJSON: TJSONObject;
begin
  Result := TJSONObject(FSerialized.Clone);
end;

function TLibraryHeader.CloneConfiguration: TJSONObject;
var
  Index: Integer;
begin
  Result := TJSONObject.Create;
  try
    for Index := 0 to FSerialized.Count - 1 do
      if FSerialized.Names[Index] <> 'versions' then
        Result.Add(FSerialized.Names[Index], FSerialized.Items[Index].Clone);
    if not Assigned(Result.Find('version_tracker')) then Result.Add('version_tracker', '');
    if not Assigned(Result.Find('platform')) then
      Result.Add('platform', 'unknown');
    if not Assigned(Result.Find('file_patterns')) then
      Result.Add('file_patterns', TJSONArray.Create);
    if not Assigned(Result.Find('release_directory')) then
      Result.Add('release_directory', FReleaseDirectory);
  except
    Result.Free;
    raise;
  end;
end;

function TLibraryHeader.SetTrackerTemplate(const Value: string): Boolean;
begin
  Result := (Value <> FTrackerTemplate) or not Assigned(FSerialized.Find('version_tracker_template'));
  if not Result then Exit;
  FTrackerTemplate := Value;
  FTrackerModified := UtcTimestamp(UtcNow);
  FSerialized.Strings['version_tracker_template'] := Value;
  FSerialized.Strings['version_tracker_modified_utc'] := FTrackerModified;
end;

function TLibraryHeader.Digest: string;
begin
  Result := AuditSHA256(FSerialized.AsJSON);
end;

function TLibraryHeader.Configure(const Settings: TLibrarySettingsChange; RevisionCount: Integer): Boolean;
var
  VersionValue, RevisionValue: string;
  NewRevisionStep: Int64;
  Index: Integer;
begin
  Result := False;
  if Settings.Platform <> '' then
  begin
    if (Settings.Platform <> 'Linux') and (Settings.Platform <> 'Windows') and (Settings.Platform <> 'macOS') then
      raise EScuError.Create('Expected Linux, Windows, or macOS for platform.');
    if FSerialized.Get('platform', 'unknown') <> 'unknown' then
      raise EScuError.CreateFmt('Creation platform is already recorded as %s.', [FSerialized.Strings['platform']]);
  end;
  if Settings.ChangeTracker and (Settings.VersionTracker <> '') then ValidateSourceFileName(Settings.VersionTracker);
  VersionValue := FVersionIncrement;
  RevisionValue := FRevisionIncrement;
  NewRevisionStep := FRevisionStep;
  if Settings.VersionIncrement <> '' then
    VersionValue := NormalizeVersionIncrement(Settings.VersionIncrement);
  if Settings.RevisionIncrement <> '' then
  begin
    NewRevisionStep := ParseIncrement(Settings.RevisionIncrement, 'revision_increment', 3, MaxDeckRevision);
    RevisionValue := FormatFixed(NewRevisionStep, 3);
  end;
  if Assigned(Settings.Editor) then
    ValidateEditor(Settings.Editor, 'Invalid value for --editor');
  if Settings.ChangeBuild and (Pos(#0, Settings.BuildCommand) > 0) then
    raise EScuError.Create('The build command cannot contain NUL bytes.');
  if Settings.ChangeReleaseDirectory and
    ((Trim(Settings.ReleaseDirectory) = '') or (Pos(#0, Settings.ReleaseDirectory) > 0)) then
    raise EScuError.Create('release_directory must be a nonempty directory path without NUL bytes.');
  if Settings.ChangePrefix and (Settings.Prefix <> Versions.CommentPrefix(Versions.Current)) then
  begin
    Versions.SetCommentPrefix(Settings.Prefix, RevisionCount);
    FSerialized.Strings['comment_prefix'] := Settings.Prefix;
    Result := True;
  end;
  if Settings.Platform <> '' then
  begin
    FSerialized.Strings['platform'] := Settings.Platform;
    Result := True;
  end;
  if Settings.ChangeTracker and (Settings.VersionTracker <> FVersionTracker) then
  begin
    FVersionTracker := Settings.VersionTracker;
    FSerialized.Strings['version_tracker'] := FVersionTracker;
    if FVersionTracker <> '' then SetTrackerTemplate(FTrackerTemplate);
    Result := True;
  end;
  if VersionValue <> FVersionIncrement then
  begin
    FSerialized.Strings['version_increment'] := VersionValue;
    FVersionIncrement := VersionValue;
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
  if Settings.ChangeReleaseDirectory and (Settings.ReleaseDirectory <> FReleaseDirectory) then
  begin
    FSerialized.Strings['release_directory'] := Settings.ReleaseDirectory;
    FReleaseDirectory := Settings.ReleaseDirectory;
    Result := True;
  end;
end;

procedure TLibraryHeader.DeleteVersion(const Name: string; RevisionCount: Integer; DeleteRevisions: Boolean);
begin
  Versions.DeleteCurrent(Name, RevisionCount, DeleteRevisions);
  FSerialized.Strings['current_version'] := Versions.Current;
  FSerialized.Strings['comment_prefix'] := Versions.CommentPrefix(Versions.Current);
end;

end.
