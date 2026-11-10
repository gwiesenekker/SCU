unit ScuCLI;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, ScuLibrary, ScuAudit, ScuSQLite;

type
  TBuildRequest = record
    Command, OutputPath: string;
    Checkpoint: TLibrarySnapshot;
    CommentPrefix: string;
  end;

  TScuCLI = class
  private
    FDefinitions: TJSONObject;
    FCommands, FArgumentNames: TJSONArray;
    FLibraryOption, FPromptParameter: TJSONObject;
    FLibraryPath, FCommand: string;
    FArguments, FOptions: TStringList;
    FInteractive, FFromSnapshotOmitted: Boolean;
    FPendingLibrary: TDeckLibrary;
    function Definition(const Name: string): TJSONObject;
    function Option(const Name: string; const Default: string = ''): string;
    function ResolveSnapshot(LibraryFile: TDeckLibrary): TLibrarySnapshot;
    function OutputPath(const Path: string): string;
    function BulkOutputDirectory: string;
    function PrefixOption: string;
    function ExecuteLibrary(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary;
      const OutputDirectory: string; out SnapshotsUsed: TAuditSnapshots; out Build: TBuildRequest): string;
    procedure DisplayCommandList;
    procedure DisplayCommand(const Name: string);
    function SelectLibrary(Tokens: TStrings): Integer;
    procedure ParseCommand(Tokens: TStrings; CommandIndex: Integer; Interactive: Boolean);
    procedure CompleteInteractiveLine(const Before, Prefix, After: string; Candidates: TStrings;
      out AppendCharacter: Char);
    procedure CompletePromptValue(const Before, Prefix, After: string; Candidates: TStrings;
      out AppendCharacter: Char);
    procedure RunCommand;
    procedure RunCommandInDirectory(const OutputDirectory: string);
    procedure BuildProcessGroup(Sender: TObject);
    procedure RunBuild(const Build: TBuildRequest; const AuditPath, Expansion: string);
    procedure RunInteractive(Tokens: TStrings);
    procedure RunInteractiveSession(Tokens: TStrings);
    procedure RecoverPendingLibrary;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

implementation

uses
  SysUtils, BaseUnix, Process, ScuIO, ScuJSON, ScuCodec, ScuExpand, ScuEdit, ScuDiff, ScuCommands,
  ScuInput, ScuComplete, ScuVersions, ScuTerminal, ScuSignals, Termio;

const
  CurrentLibraryVersionSelector = 'scu$current_library_version';
  LibraryDirectorySelector = 'scu$library_directory';
  DeckNameSelector = 'scu$deck_name';

function setpgid(Pid, Group: cint): cint; cdecl; external 'c';

function CommandFile: string;
var
  Buffer: array[0..4095] of Char;
  Count: ssize_t;
begin
  Count := fpReadLink('/proc/self/exe', @Buffer[0], SizeOf(Buffer));
  if (Count < 0) or (Count = SizeOf(Buffer)) then
    raise EScuError.Create('Could not locate the running SCU executable.');
  SetString(Result, PChar(@Buffer[0]), Count);
  Result := IncludeTrailingPathDelimiter(ExtractFileDir(Result)) + 'commands.json';
end;

constructor TScuCLI.Create;
begin
  inherited Create;
  FArguments := TStringList.Create;
  FOptions := TStringList.Create;
  FOptions.CaseSensitive := True;
  FDefinitions := ParseObject(ReadBytes(CommandFile, 1024 * 1024));
  PrepareCommandDefinitions(FDefinitions);
  FCommands := TJSONArray(Field(FDefinitions, 'commands', jtArray));
  FLibraryOption := TJSONObject(Field(FDefinitions, 'library_option', jtObject));
  FArgumentNames := TJSONArray.Create;
end;

destructor TScuCLI.Destroy;
begin
  FPendingLibrary.Free;
  FOptions.Free;
  FArguments.Free;
  FArgumentNames.Free;
  FDefinitions.Free;
  inherited Destroy;
end;

function TScuCLI.Definition(const Name: string): TJSONObject;
var
  Index: Integer;
begin
  Index := FindDefinition(FCommands, Name);
  if Index < 0 then
    raise EScuError.CreateFmt('Unknown command "%s". Run scu help.', [Name]);
  Result := DefinitionAt(FCommands, Index);
end;

function TScuCLI.Option(const Name: string; const Default: string): string;
var
  Index: Integer;
begin
  Index := FOptions.IndexOfName(Name);
  if Index < 0 then
    Result := Default
  else
    Result := FOptions.ValueFromIndex[Index];
end;

function TScuCLI.SelectLibrary(Tokens: TStrings): Integer;
var
  First, Name, LegacyDefault: string;
  EqualsAt: SizeInt;
begin
  FLibraryPath := Field(FLibraryOption, 'default', jtString).AsString;
  Result := 0;
  if Tokens.Count > 0 then
  begin
    First := Tokens[0];
    EqualsAt := Pos('=', First);
    if EqualsAt > 0 then
      Name := Copy(First, 1, EqualsAt - 1)
    else
      Name := First;
    if Copy(Name, 1, 2) = '--' then
      Delete(Name, 1, 2);
    if ((EqualsAt > 0) or (Copy(First, 1, 2) = '--')) and
      MatchesDefinition(FLibraryOption, Name) then
    begin
      Result := 1;
      if (EqualsAt > 0) and (EqualsAt < Length(First)) then
        FLibraryPath := Copy(First, EqualsAt + 1, MaxInt)
      else
      begin
        if Tokens.Count < 2 then
          raise EScuError.CreateFmt('Expected a library name for %s.', [First]);
        FLibraryPath := Tokens[1];
        Result := 2;
      end;
    end
    else if (Copy(First, 1, 1) <> '-') and (FindDefinition(FCommands, First) < 0) then
    begin
      Name := LowerCase(ExtractFileExt(First));
      if not FileExists(First) and (Name <> '.json') and (Name <> '.sqlite') and
        (Name <> '.sqlite3') and (Name <> '.db') then
        Definition(First);
      FLibraryPath := First;
      Result := 1;
    end;
  end;
  if (Result = 0) and Assigned(FLibraryOption.Find('legacy_default')) and not FileExists(FLibraryPath) then
  begin
    LegacyDefault := Field(FLibraryOption, 'legacy_default', jtString).AsString;
    if FileExists(LegacyDefault) then
      FLibraryPath := LegacyDefault;
  end;
  ValidateParameter(FLibraryOption, FLibraryPath);
  if FLibraryPath = '' then
    raise EScuError.Create('Expected a library name.');
end;

function AliasText(Entry: TJSONObject): string;
var
  Aliases: TJSONArray;
  AliasIndex: Integer;
begin
  Result := '';
  Aliases := DefinitionAliases(Entry);
  if Assigned(Aliases) then
    for AliasIndex := 0 to Aliases.Count - 1 do
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + Aliases.Strings[AliasIndex];
    end;
end;

function CommandNames(Entry: TJSONObject): string;
var
  Aliases: string;
begin
  Result := DefinitionName(Entry);
  Aliases := AliasText(Entry);
  if Aliases <> '' then
    Result := Result + ', ' + Aliases;
end;

function ParameterSyntax(Entry: TJSONObject; Positional, HasDefault: Boolean; const DefaultValue: string): string;
var
  Aliases, Value: string;
begin
  Result := DefinitionName(Entry);
  if not Positional then
    Result := '--' + Result;
  Aliases := AliasText(Entry);
  if Aliases <> '' then
    Result := Result + ' (' + Aliases + ')';
  if HasDefault then
    Value := DefaultValue
  else if ParameterRequired(Entry, Positional) then
    Value := 'scu$required'
  else
    Value := 'scu$optional';
  Result := Result + ' : ' + Field(Entry, 'type', jtString).AsString + ' = ' + Value;
end;

function IsSessionExit(const Command: string): Boolean;
begin
  Result := (Command = 'quit_session') or (Command = 'quit');
end;

procedure TScuCLI.ParseCommand(Tokens: TStrings; CommandIndex: Integer; Interactive: Boolean);
var
  Index, Expected, Slot, OptionSlot, EqualsAt: Integer;
  Value, Key: string;
  Spec: TJSONObject;
  Arguments, Options: TJSONArray;
  PositionalOnly: Boolean;
  Supplied: array of Boolean;

  procedure SetArgument(Position: Integer; const Argument: string);
  begin
    if Supplied[Position] then
      raise EScuError.CreateFmt('Duplicate argument %s.', [FArgumentNames.Strings[Position]]);
    ValidateParameter(DefinitionAt(Arguments, Position), Argument);
    FArguments[Position] := Argument;
    Supplied[Position] := True;
  end;

  procedure SetOption(Position: Integer; const Argument: string);
  var
    Entry: TJSONObject;
    Name: string;
  begin
    Entry := DefinitionAt(Options, Position);
    Name := DefinitionName(Entry);
    if FOptions.IndexOfName(Name) >= 0 then
      raise EScuError.CreateFmt('Duplicate option --%s.', [Name]);
    ValidateParameter(Entry, Argument);
    FOptions.Add(Name + '=' + Argument);
  end;

  function CompleteParameter(Entry: TJSONObject; Positional: Boolean; out Argument: string): Boolean;
  var
    Name, Description, Prompt, DefaultValue: string;
    Columns: SizeInt;
    HasDefault: Boolean;
  begin
    HasDefault := ParameterDefault(Spec, Entry, Positional, DefaultValue);
    if HasDefault and (not Interactive or not Entry.Get('prompt_for_default', True)) then
    begin
      Argument := DefaultValue;
      Exit(True);
    end;
    if not HasDefault and not ParameterRequired(Entry, Positional) then
      Exit(False);

    Name := DefinitionName(Entry);
    if not Interactive then
      raise EScuError.CreateFmt('Missing required argument %s for %s.', [Name, FCommand]);
    Columns := TerminalColumns(TextRec(StdErr).Handle);
    if Columns > 0 then
      UseTerminalLocale;
    Prompt := FormatTerminalLines(ParameterSyntax(Entry, Positional, HasDefault, DefaultValue), Columns) + LineEnding;
    Description := ParameterDescription(Entry);
    if Description <> '' then
      Prompt := Prompt + FormatTerminalLines(Description, Columns) + LineEnding;
    if HasDefault then
      Prompt := Prompt + FormatTerminalLines('Press Enter to accept the default.', Columns) + LineEnding;
    Prompt := Prompt + Name + '= ';
    repeat
      FPromptParameter := Entry;
      try
        if not ReadCommandLine(Prompt, Argument, @CompletePromptValue, False) then
          raise ECommandCancelled.Create('Command cancelled.');
      finally
        FPromptParameter := nil;
      end;
      if Argument = '' then
      begin
        if HasDefault then
        begin
          Argument := DefaultValue;
          Exit(True);
        end;
        Continue;
      end;
      try
        ValidateParameter(Entry, Argument);
        Exit(True);
      except
        on E: EScuError do
          WriteLn(StdErr, 'scu: ', E.Message);
      end;
    until False;
  end;

  function ReadValue(const Name: string): string;
  begin
    Inc(Index);
    if Index >= Tokens.Count then
      raise EScuError.CreateFmt('Expected a value for %s.', [Name]);
    Result := Tokens[Index];
  end;

  function ValueFollows: Boolean;
  var
    Next, Name: string;
    Separator: SizeInt;
  begin
    if Index + 1 >= Tokens.Count then
      Exit(False);
    Next := Tokens[Index + 1];
    if Copy(Next, 1, 2) = '--' then
      Exit(False);
    Separator := Pos('=', Next);
    if Separator <= 1 then
      Exit(True);
    Name := Copy(Next, 1, Separator - 1);
    Result := (FindDefinition(Arguments, Name) < 0) and (FindDefinition(Options, Name) < 0);
  end;

begin
  FArguments.Clear;
  FArgumentNames.Clear;
  FOptions.Clear;
  Spec := Definition(Tokens[CommandIndex]);
  Index := CommandIndex + 1;
  FCommand := DefinitionName(Spec);
  Arguments := TJSONArray(Field(Spec, 'arguments', jtArray));
  Options := TJSONArray(Field(Spec, 'options', jtArray));
  Expected := Arguments.Count;
  SetLength(Supplied, Expected);
  for Slot := 0 to Expected - 1 do
  begin
    FArgumentNames.Add(DefinitionName(DefinitionAt(Arguments, Slot)));
    FArguments.Add('');
  end;
  PositionalOnly := False;

  while Index < Tokens.Count do
  begin
    Value := Tokens[Index];
    EqualsAt := Pos('=', Value);
    if not PositionalOnly and (Value = '--') then
      PositionalOnly := True
    else if not PositionalOnly and (Copy(Value, 1, 2) = '--') then
    begin
      Key := Copy(Value, 3, MaxInt);
      if EqualsAt > 0 then
        Key := Copy(Value, 3, EqualsAt - 3);
      OptionSlot := FindDefinition(Options, Key);
      if OptionSlot < 0 then
        raise EScuError.CreateFmt('Unknown option %s for %s.', [Value, FCommand]);
      if EqualsAt > 0 then
        SetOption(OptionSlot, Copy(Value, EqualsAt + 1, MaxInt))
      else if ParameterRequired(DefinitionAt(Options, OptionSlot), False) and not ValueFollows then
      begin
        Key := DefinitionName(DefinitionAt(Options, OptionSlot));
        if FOptions.IndexOfName(Key) >= 0 then
          raise EScuError.CreateFmt('Duplicate option --%s.', [Key]);
        Inc(Index);
        Continue;
      end
      else
        SetOption(OptionSlot, ReadValue(Value));
    end
    else
    begin
      if not PositionalOnly and (EqualsAt > 1) then
      begin
        Key := Copy(Value, 1, EqualsAt - 1);
        Slot := FindDefinition(Arguments, Key);
        OptionSlot := FindDefinition(Options, Key);
        if (Slot >= 0) and (OptionSlot >= 0) then
          raise EScuError.CreateFmt('Ambiguous argument or option "%s" for %s.', [Key, FCommand]);
        if (Slot >= 0) or (OptionSlot >= 0) then
        begin
          if (EqualsAt = Length(Value)) and ValueFollows then
            Value := ReadValue(Key)
          else
            Value := Copy(Value, EqualsAt + 1, MaxInt);
          if Slot >= 0 then
            SetArgument(Slot, Value)
          else
            SetOption(OptionSlot, Value);
          Inc(Index);
          Continue;
        end;
      end;
      Slot := 0;
      while (Slot < Expected) and Supplied[Slot] do
        Inc(Slot);
      if Slot = Expected then
        raise EScuError.CreateFmt('Too many arguments for %s. Run scu help.', [FCommand]);
      SetArgument(Slot, Value);
    end;
    Inc(Index);
  end;

  FFromSnapshotOmitted := (FCommand = 'diff_deck') and (Expected > 1) and not Supplied[1];
  for Slot := 0 to Expected - 1 do
    if not Supplied[Slot] and CompleteParameter(DefinitionAt(Arguments, Slot), True, Value) then
      SetArgument(Slot, Value);
  for OptionSlot := 0 to Options.Count - 1 do
  begin
    Key := DefinitionName(DefinitionAt(Options, OptionSlot));
    if (FOptions.IndexOfName(Key) < 0) and
      CompleteParameter(DefinitionAt(Options, OptionSlot), False, Value) then
      SetOption(OptionSlot, Value);
  end;
end;

procedure TScuCLI.DisplayCommandList;
const
  MinDescriptionColumns = 20;
var
  Index: Integer;
  Columns, Width, LabelColumns: SizeInt;
  LabelText, Description, Indent: string;
  Names: TStringList;
  Spec: TJSONObject;
  Stacked: Boolean;

  function LabelWidth(const Text: string): SizeInt;
  begin
    if Columns = 0 then
      Result := Length(Text)
    else
      Result := TextWidth(Text, 0, Length(Text));
  end;

begin
  Columns := TerminalColumns(TextRec(Output).Handle);
  if Columns > 0 then
    UseTerminalLocale;
  Names := TStringList.Create;
  try
    Width := 0;
    for Index := 0 to FCommands.Count - 1 do
    begin
      Spec := DefinitionAt(FCommands, Index);
      Names.AddObject(DefinitionName(Spec), Spec);
      LabelColumns := LabelWidth(CommandNames(Spec));
      if LabelColumns > Width then
        Width := LabelColumns;
    end;
    Inc(Width, 2);
    Stacked := (Columns > 0) and (Columns - Width < MinDescriptionColumns);
    if Stacked then
    begin
      Indent := '  ';
      if Columns < 3 then
        SetLength(Indent, Columns - 1);
    end
    else if Columns > 0 then
      Indent := StringOfChar(' ', Width);
    Names.Sort;
    for Index := 0 to Names.Count - 1 do
    begin
      Spec := TJSONObject(Names.Objects[Index]);
      LabelText := CommandNames(Spec);
      Description := Field(Spec, 'summary', jtString).AsString;
      if Stacked then
      begin
        WriteLn(WrapTerminalText(LabelText, LineEnding, Columns));
        WriteLn(Indent, WrapTerminalText(Description, LineEnding + Indent, Columns - Length(Indent)));
      end
      else
      begin
        if Columns > 0 then
          Description := WrapTerminalText(Description, LineEnding + Indent, Columns - Width);
        WriteLn(LabelText, StringOfChar(' ', Width - LabelWidth(LabelText)), Description);
      end;
    end;
  finally
    Names.Free;
  end;
end;

procedure TScuCLI.DisplayCommand(const Name: string);
var
  Index, MemberIndex: Integer;
  Columns: SizeInt;
  Spec, Example: TJSONObject;
  Arguments, Options, Groups, Group, Examples: TJSONArray;
  Help: TJSONData;
  Body: RawByteString;
  GroupText: string;

  procedure ShowText(const Text: string; Indentation: SizeInt = 0);
  begin
    WriteLn(FormatTerminalLines(Text, Columns, Indentation));
  end;

  procedure ShowParameter(Entry: TJSONObject; Positional: Boolean);
  var
    DefaultValue, Description: string;
    HasDefault: Boolean;
  begin
    HasDefault := ParameterDefault(Spec, Entry, Positional, DefaultValue);
    ShowText(ParameterSyntax(Entry, Positional, HasDefault, DefaultValue), 2);
    Description := ParameterDescription(Entry);
    if Description <> '' then
      ShowText(Description, 4);
  end;

begin
  Spec := Definition(Name);
  Columns := TerminalColumns(TextRec(Output).Handle);
  if Columns > 0 then
    UseTerminalLocale;
  ShowText(CommandNames(Spec));
  ShowText(Field(Spec, 'summary', jtString).AsString);
  Help := Spec.Find('help_file');
  if Assigned(Help) then
  begin
    Body := ReadBytes(ExtractFileDir(CommandFile) + DirectorySeparator + Help.AsString, 1024 * 1024);
    ShowText(TrimRight(Body));
  end
  else
  begin
    Help := Spec.Find('help');
    if Assigned(Help) then
      ShowText(Help.AsString);
  end;
  Arguments := TJSONArray(Field(Spec, 'arguments', jtArray));
  Options := TJSONArray(Field(Spec, 'options', jtArray));
  ShowText('Arguments');
  if Arguments.Count = 0 then
    ShowText('None', 2);
  for Index := 0 to Arguments.Count - 1 do
    ShowParameter(DefinitionAt(Arguments, Index), True);
  ShowText('Options');
  if Options.Count = 0 then
    ShowText('None', 2);
  for Index := 0 to Options.Count - 1 do
    ShowParameter(DefinitionAt(Options, Index), False);
  Groups := ExclusiveOptionGroups(Spec);
  if Assigned(Groups) and (Groups.Count > 0) then
  begin
    ShowText('Mutually exclusive options (choose at most one per group)');
    for Index := 0 to Groups.Count - 1 do
    begin
      Group := TJSONArray(Groups.Items[Index]);
      GroupText := '';
      for MemberIndex := 0 to Group.Count - 1 do
      begin
        if MemberIndex > 0 then
          GroupText := GroupText + ', ';
        GroupText := GroupText + '--' + Group.Strings[MemberIndex];
      end;
      ShowText(GroupText, 2);
    end;
  end;
  if Assigned(Spec.Find('examples')) then
  begin
    Examples := TJSONArray(Field(Spec, 'examples', jtArray));
    if Examples.Count > 0 then
      ShowText('Examples');
    for Index := 0 to Examples.Count - 1 do
    begin
      Example := DefinitionAt(Examples, Index);
      WriteLn('  ', Field(Example, 'command', jtString).AsString);
      ShowText(Field(Example, 'description', jtString).AsString, 4);
    end;
  end;
end;

function TScuCLI.ResolveSnapshot(LibraryFile: TDeckLibrary): TLibrarySnapshot;
var
  Version: string;
  Base, Revision: Integer;
begin
  if FOptions.IndexOfName('version') >= 0 then
  begin
    if FOptions.IndexOfName('revision') >= 0 then
      raise EScuError.Create('Choose either --version or --revision.');
    Version := Option('version');
    if ((FCommand = 'extract_deck') or (FCommand = 'expand_deck')) and (Pos('-', Version) > 0) then
      Exit(LibraryFile.ParseDeckSnapshot(DeckName(FArguments[0]), Version));
    LibraryFile.VersionBounds(Version, Base, Revision);
  end
  else if FOptions.IndexOfName('revision') >= 0 then
  begin
    Revision := LibraryFile.ParseRevision(Option('revision'));
    Version := LibraryFile.VersionAt(Revision);
  end
  else
    Exit(LibraryFile.CurrentSnapshot);
  Result.Version := Version;
  Result.LibraryRevision := Revision;
end;

function TScuCLI.OutputPath(const Path: string): string;
begin
  Result := CanonicalFile(Path);
  if (Result = FLibraryPath) or (Result = FLibraryPath + '.audit') or
    (Result = FLibraryPath + '.lock') or (Result = FLibraryPath + '-journal') or
    (Result = FLibraryPath + '-wal') or (Result = FLibraryPath + '-shm') then
    raise EScuError.Create('The output path would overwrite a library or audit file.');
  RegularFileExists(Result);
end;

function TScuCLI.PrefixOption: string;
begin
  Result := Option('comment-prefix');
  if FOptions.IndexOfName('comment-prefix') >= 0 then
    ValidateCommentPrefix(Result);
end;

function TScuCLI.BulkOutputDirectory: string;
begin
  Result := FArguments[1];
  if (FCommand = 'expand_modified_decks') and SameText(Result, LibraryDirectorySelector) then
    Result := ExtractFileDir(CanonicalFile(FLibraryPath));
end;

function TScuCLI.ExecuteLibrary(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary;
  const OutputDirectory: string; out SnapshotsUsed: TAuditSnapshots; out Build: TBuildRequest): string;
var
  Source, OtherSource: TDeckSource;
  Bytes: RawByteString;
  Expander: TDeckExpander;
  Names, Destinations: TStringList;
  Name, Path, Version, VersionIncrement, RevisionIncrement, Prefix, Directory, MissingDeckVersion: string;
  Revision, Base, Index, CheckpointRevision: Integer;
  Previous, FromSnapshot, ToSnapshot: TLibrarySnapshot;
  Editor: TJSONData;
  ChangePrefix, ChangeBuild, SaveRequested, UsePriorDeckRevision, Refresh, BuildPending: Boolean;

  function ResolveLastModifiedDeck: string;
  begin
    Result := LibraryFile.LastModifiedDeck;
    if Result = '' then
      raise EScuError.Create('No deck has been modified in this library.');
  end;

  function DeckWriteReport(const Deck: string; StoredRevision: Integer): string;
  begin
    if StoredRevision = 0 then
      Exit('No changes to ' + Deck);
    Result := Format('%s version %s revision %s, deck version %s',
      [Deck, LibraryFile.VersionAt(StoredRevision), LibraryFile.DeckRevision[StoredRevision],
        LibraryFile.DeckVersion[StoredRevision]]);
  end;

  procedure ReportSnapshot(const LabelText: string; const Snapshot: TLibrarySnapshot);
  begin
    WriteLn(StdErr, LabelText, ' version ', Snapshot.Version, ', library revision ',
      Snapshot.LibraryRevision, '.');
  end;

  procedure ScheduleBuild(const Target: string);
  var
    Enabled: Boolean;
  begin
    if not TryParseYesNo(Option('build', 'no'), Enabled) then
      raise EScuError.Create('Expected yes/y or no/n for build.');
    if Enabled and (LibraryFile.BuildCommand <> '') then
    begin
      Build.Command := LibraryFile.BuildCommand;
      Build.OutputPath := Target;
    end;
  end;

begin
  Result := '';
  Build := Default(TBuildRequest);
  if (FArguments.Count > 0) and (FArgumentNames.Strings[0] = 'deck_name') and
    SameText(FArguments[0], LastModifiedDeckSelector) then
  begin
    SnapshotsUsed.ResolvedDeck := ResolveLastModifiedDeck;
    FArguments[0] := SnapshotsUsed.ResolvedDeck;
  end;
  case FCommand of
    'save_library', 'quit_session', 'quit':
      begin
        SaveRequested := True;
        if IsSessionExit(FCommand) and (FArguments.Count > 0) and
          not TryParseYesNo(FArguments[0], SaveRequested) then
          raise EScuError.Create('Expected yes/y or no/n for save_library.');
        if not SaveRequested then
          Result := 'Discarded unsaved library changes.'
        else if LibraryFile.Modified then
        begin
          LibraryFile.Save;
          SnapshotsUsed.Selected := LibraryFile.CurrentSnapshot;
          Result := 'Saved library.';
        end
        else
          Result := 'No unsaved library changes.';
      end;
    'display_expansion_checkpoints':
      begin
        if not Assigned(Database) then
          raise EScuError.Create('Expansion checkpoints require a SQLite library.');
        Names := TStringList.Create;
        try
          Database.ListExpansionCheckpoints(Names);
          if Names.Count = 0 then
            Result := 'No expansion checkpoints.'
          else
          begin
            WriteLn('Version'#9'Output directory'#9'Last built library revision'#9'Status'#9 +
              'Last successful build (UTC)'#9'Checkpoint library revision');
            for Name in Names do
              WriteLn(Name);
          end;
        finally
          Names.Free;
        end;
      end;
    'reset_expansion_checkpoint':
      begin
        if not Assigned(Database) then
          raise EScuError.Create('Expansion checkpoints require a SQLite library.');
        Version := FArguments[0];
        LibraryFile.VersionBounds(Version, Base, Revision);
        if Database.ResetExpansionCheckpoint(Version, OutputDirectory) then
          Result := Format('Reset expansion checkpoint for version %s in "%s".', [Version, OutputDirectory])
        else
          Result := Format('No expansion checkpoint for version %s in "%s".', [Version, OutputDirectory]);
      end;
    'display_library':
      begin
        SnapshotsUsed.Selected := LibraryFile.CurrentSnapshot;
        Version := 'none';
        if LibraryFile.TryPreviousSnapshot(Previous) then
          Version := Previous.Version;
        Result := Format('Library "%s", current version %s, previous locked version %s.',
          [FLibraryPath, SnapshotsUsed.Selected.Version, Version]);
      end;
    'show_library':
      WriteLn(LibraryFile.HeaderJSON);
    'configure_library', 'configure':
      begin
        ChangePrefix := FOptions.IndexOfName('comment-prefix') >= 0;
        ChangeBuild := FOptions.IndexOfName('build_command') >= 0;
        VersionIncrement := Option('version_increment');
        RevisionIncrement := Option('revision_increment');
        if ((FOptions.IndexOfName('version_increment') >= 0) and (VersionIncrement = '')) or
          ((FOptions.IndexOfName('revision_increment') >= 0) and (RevisionIncrement = '')) then
          raise EScuError.Create('Expected a positive increment.');
        Editor := nil;
        try
          if FOptions.IndexOfName('editor') >= 0 then
          begin
            Editor := ParseJSON(Option('editor'));
            if not (Editor is TJSONArray) then
              raise EScuError.Create('The editor must be a JSON array of strings.');
          end;
          if not ChangePrefix and not ChangeBuild and (Editor = nil) and
            (VersionIncrement = '') and (RevisionIncrement = '') then
            raise EScuError.Create('Specify at least one library setting.');
          LibraryFile.Configure(ChangePrefix, PrefixOption, TJSONArray(Editor), VersionIncrement,
            RevisionIncrement, ChangeBuild, Option('build_command'));
          Result := 'Updated library header';
        finally
          Editor.Free;
        end;
      end;
    'edit_deck':
      begin
        Name := DeckName(FArguments[0]);
        Result := DeckWriteReport(Name, EditDeck(LibraryFile, Name));
      end;
    'create_deck', 'store_deck':
      begin
        LibraryFile.RequireOpenVersion;
        Name := DeckName(FArguments[0]);
        Bytes := '';
        if (FCommand = 'store_deck') or (FArguments[1] <> '') then
          Bytes := ReadBytes(FArguments[1], MaxDeckSize);
        Revision := LibraryFile.Store(Name, Bytes, FCommand = 'create_deck', PrefixOption);
        Result := DeckWriteReport(Name, Revision);
      end;
    'lock_version':
      begin
        LibraryFile.LockVersion;
        Result := 'Locked version ' + LibraryFile.CurrentVersion;
      end;
    'start_version':
      begin
        LibraryFile.StartVersion(FArguments[0]);
        Result := 'Started version ' + LibraryFile.CurrentVersion;
      end;
    'display_deck_list', 'list_versions', 'display_deck':
      begin
        Names := TStringList.Create;
        try
          if FCommand = 'list_versions' then
            LibraryFile.ListVersions(Names)
          else if FCommand = 'display_deck' then
            LibraryFile.ListDeckHistory(FArguments[0], Names)
          else
          begin
            SnapshotsUsed.Selected := ResolveSnapshot(LibraryFile);
            LibraryFile.List(SnapshotsUsed.Selected.LibraryRevision, Names);
            Names.Sort;
          end;
          for Name in Names do
            WriteLn(Name);
          if FCommand = 'display_deck_list' then
            ReportSnapshot('Using', SnapshotsUsed.Selected);
        finally
          Names.Free;
        end;
      end;
    'diff_deck':
      begin
        Name := DeckName(FArguments[0]);
        UsePriorDeckRevision := FFromSnapshotOmitted and SameText(FArguments[1], PreviousDeckVersionSelector);
        if not UsePriorDeckRevision then
        begin
          FromSnapshot := LibraryFile.ParseDeckSnapshot(Name, FArguments[1]);
          SnapshotsUsed.FromDeckVersion := LibraryFile.DeckVersion[FromSnapshot.LibraryRevision];
        end;
        ToSnapshot := LibraryFile.ParseDeckSnapshot(Name, FArguments[2]);
        SnapshotsUsed.ToDeckVersion := LibraryFile.DeckVersion[ToSnapshot.LibraryRevision];
        if UsePriorDeckRevision then
        begin
          FromSnapshot := LibraryFile.PreviousDeckSnapshot(Name, ToSnapshot.LibraryRevision);
          SnapshotsUsed.FromDeckVersion := LibraryFile.DeckVersion[FromSnapshot.LibraryRevision];
        end;
        Source := LibraryFile.Extract(Name, FromSnapshot.LibraryRevision);
        OtherSource := LibraryFile.Extract(Name, ToSnapshot.LibraryRevision);
        WriteDeckDiff(Source.Bytes, OtherSource.Bytes,
          Name + '@' + SnapshotsUsed.FromDeckVersion, Name + '@' + SnapshotsUsed.ToDeckVersion);
        WriteLn(StdErr, 'From deck version ', SnapshotsUsed.FromDeckVersion, '.');
        WriteLn(StdErr, 'To deck version ', SnapshotsUsed.ToDeckVersion, '.');
      end;
    'extract_deck', 'expand_deck':
      begin
        SnapshotsUsed.Selected := ResolveSnapshot(LibraryFile);
        MissingDeckVersion := '';
        if FOptions.IndexOfName('revision') < 0 then
          MissingDeckVersion := SnapshotsUsed.Selected.Version;
        Path := FArguments[1];
        if SameText(Path, DeckNameSelector) then
          Path := DeckName(FArguments[0])
        else if SameText(Path, LastModifiedDeckSelector) then
          Path := ResolveLastModifiedDeck;
        Path := OutputPath(Path);
        if FCommand = 'expand_deck' then
        begin
          Expander := TDeckExpander.Create(LibraryFile, SnapshotsUsed.Selected.LibraryRevision,
            SnapshotsUsed.Selected.Version, PrefixOption, MissingDeckVersion);
          try
            Bytes := Expander.Expand(FArguments[0]);
          finally
            Expander.Free;
          end;
        end
        else
        begin
          Source := LibraryFile.Extract(FArguments[0], SnapshotsUsed.Selected.LibraryRevision, MissingDeckVersion);
          Bytes := Source.Bytes;
        end;
        CheckSessionInterrupt;
        AtomicWrite(Path, Bytes, True, True);
        if FCommand = 'expand_deck' then
          ScheduleBuild(Path);
        ReportSnapshot('Using', SnapshotsUsed.Selected);
      end;
    'extract_modified_decks', 'expand_modified_decks':
      begin
        Version := FArguments[0];
        if (FCommand = 'expand_modified_decks') and SameText(Version, CurrentLibraryVersionSelector) then
          Version := LibraryFile.CurrentVersion;
        Directory := OutputDirectory;
        if Directory = '' then
          Directory := BulkOutputDirectory
        else if LibraryFile.Modified then
          raise EScuError.Create('Save the SQLite library before running expand_modified_decks.');
        LibraryFile.VersionBounds(Version, Base, Revision);
        if not DirectoryExists(Directory) then
          raise EScuError.Create('The output directory must already exist.');
        SnapshotsUsed.Selected.Version := Version;
        SnapshotsUsed.Selected.LibraryRevision := Revision;
        BuildPending := False;
        if OutputDirectory <> '' then
          if Database.ReadExpansionCheckpoint(Version, Directory, CheckpointRevision, Refresh, BuildPending) then
          begin
            if (CheckpointRevision < Base) or (CheckpointRevision > Revision) then
              raise EScuError.Create('The expansion checkpoint is outside the selected version.');
            if Refresh then
              Base := 0
            else
              Base := CheckpointRevision;
          end;
        Names := nil;
        Destinations := nil;
        Expander := nil;
        try
          Names := TStringList.Create;
          Names.CaseSensitive := True;
          Names.Sorted := True;
          Names.Duplicates := dupIgnore;
          LibraryFile.ChangedDecks(Base, Revision, Names);
          if FCommand = 'expand_modified_decks' then
          begin
            Prefix := PrefixOption;
            Expander := TDeckExpander.Create(LibraryFile, Revision, Version, Prefix);
            if OutputDirectory <> '' then
              Expander.IncludeCopyDependents(Names);
          end;
          Destinations := TStringList.Create;
          for Name in Names do
            Destinations.Add(OutputPath(IncludeTrailingPathDelimiter(Directory) + Name));
          for Index := 0 to Names.Count - 1 do
          begin
            if Assigned(Expander) then
              Bytes := Expander.Expand(Names[Index])
            else
            begin
              Source := LibraryFile.Extract(Names[Index], Revision);
              Bytes := Source.Bytes;
            end;
            CheckSessionInterrupt;
            AtomicWrite(Destinations[Index], Bytes, True, True);
          end;
          if Assigned(Expander) and ((Names.Count > 0) or BuildPending) then
          begin
            if OutputDirectory = '' then
              ScheduleBuild(ExtractFileDir(Destinations[0]))
            else
            begin
              ScheduleBuild(Directory);
              if Build.Command <> '' then
              begin
                Build.Checkpoint := SnapshotsUsed.Selected;
                Build.CommentPrefix := Prefix;
              end
              else if (Names.Count > 0) and (LibraryFile.BuildCommand = '') then
                Database.SaveExpansionCheckpoint(Version, Directory, Prefix, Revision, True);
            end;
          end;
          Result := Format('Wrote %d deck(s) for version %s', [Names.Count, Version]);
        finally
          Expander.Free;
          Destinations.Free;
          Names.Free;
        end;
      end;
    else
      raise EScuError.CreateFmt('No implementation for command "%s".', [FCommand]);
  end;
end;

procedure TScuCLI.BuildProcessGroup(Sender: TObject);
begin
  if setpgid(0, 0) <> 0 then
    fpExit(126);
end;

procedure TScuCLI.RunBuild(const Build: TBuildRequest; const AuditPath, Expansion: string);
var
  Child: TProcess;
  Lock: TLibraryLock;
  Audit: TAuditLog;
  Database: TSQLiteLibrary;
  Failure: string;
begin
  Failure := '';
  try
    Child := TProcess.Create(nil);
    try
      Child.Executable := '/bin/sh';
      Child.Parameters.Add('-c');
      Child.Parameters.Add('exec </dev/null' + LineEnding + Build.Command);
      Child.Parameters.Add('scu-build');
      Child.Parameters.Add(Build.OutputPath);
      if FInteractive then
        Child.OnForkEvent := @BuildProcessGroup;
      WaitForChild(Child, FInteractive);
      if SessionSignal <> 0 then
        raise EScuError.Create('Build command interrupted.');
      if ChildExitStatus(Child) <> 0 then
        raise EScuError.CreateFmt('Build command failed with exit status %d.', [ChildExitStatus(Child)]);
    finally
      Child.Free;
    end;
  except
    on E: Exception do Failure := E.Message;
  end;

  try
    Lock := TLibraryLock.Create(FLibraryPath + '.lock');
    try
      Database := nil;
      try
        if (Build.Checkpoint.Version <> '') or IsSQLiteLibrary(FLibraryPath) then
        begin
          Database := TSQLiteLibrary.Create(FLibraryPath, False, False);
          Database.BeginTransaction(False);
          Database.EnsureSchema(False);
          Audit := TAuditLog.Create(Database, Expansion);
        end
        else
          Audit := TAuditLog.Create(AuditPath, False, False, Expansion);
        try
          if (Failure = '') and (Build.Checkpoint.Version <> '') then
            Database.SaveExpansionCheckpoint(Build.Checkpoint.Version, Build.OutputPath,
              Build.CommentPrefix, Build.Checkpoint.LibraryRevision, False);
          Audit.RecordBuild(Expansion, Build.Command, Build.OutputPath, Failure = '', Failure);
          if Assigned(Database) then
            Database.Commit;
        finally
          Audit.Free;
        end;
      finally
        Database.Free;
      end;
    finally
      Lock.Free;
    end;
  except
    on E: Exception do
    begin
      if Failure <> '' then
        Failure := Failure + ' ';
      Failure := Failure + 'Could not record build outcome: ' + E.Message;
    end;
  end;
  if Failure <> '' then
    raise EScuError.Create(Failure);
end;

procedure TScuCLI.RunCommand;
var
  Directory, Path: string;
  Lock: TLibraryLock;
begin
  if FCommand = 'expand_deck' then
  begin
    Path := FArguments[1];
    if (Path = '') or SameText(Path, DeckNameSelector) or SameText(Path, LastModifiedDeckSelector) then
      Directory := GetCurrentDir
    else
      Directory := ExtractFileDir(ExpandFileName(Path));
  end
  else if (FCommand = 'expand_modified_decks') or (FCommand = 'reset_expansion_checkpoint') then
    Directory := BulkOutputDirectory
  else
  begin
    RunCommandInDirectory('');
    Exit;
  end;
  if not DirectoryExists(Directory) then
    raise EScuError.Create('The output directory must already exist.');
  Directory := CanonicalDirectory(Directory);
  Lock := TLibraryLock.CreateForDirectory(Directory);
  try
    if (FCommand <> 'expand_deck') and IsSQLiteLibrary(CanonicalFile(FLibraryPath)) then
      RunCommandInDirectory(Directory)
    else
      RunCommandInDirectory('');
  finally
    Lock.Free;
  end;
end;

procedure TScuCLI.RunCommandInDirectory(const OutputDirectory: string);
var
  Lock, TransferLock: TLibraryLock;
  Audit: TAuditLog;
  Database: TSQLiteLibrary;
  LibraryFile: TDeckLibrary;
  LibraryExists, Verifying, Initializing, Importing, Exporting, Committed, PendingSave: Boolean;
  AuditPath, Checkpoint, Detail, Expansion, TransferPath, ExpansionVersion: string;
  SnapshotsUsed: TAuditSnapshots;
  Build: TBuildRequest;
  PreviousAuditRecords: Int64;
  Contents: TJSONObject;

  procedure RaiseMissingLibrary;
  begin
    raise EScuError.CreateFmt('Library "%s" does not exist. Use initialize_library to create it.',
      [FLibraryPath]);
  end;

  procedure ExportLibrary;
  var
    TempDir, TempAudit: string;
    Stream: TFileStream;
    Document: RawByteString;
  begin
    if RegularFileExists(TransferPath) or RegularFileExists(TransferPath + '.audit') then
      raise EScuError.Create('The JSON export destination or its audit log already exists.');
    Document := LibraryFile.ExportJSON;
    TempDir := MakeTempDirectory('scu-export');
    TempAudit := IncludeTrailingPathDelimiter(TempDir) + 'audit';
    try
      Stream := TFileStream.Create(TempAudit, fmCreate);
      try
        Database.ExportAudit(Stream, PreviousAuditRecords);
        Stream.Position := 0;
        AtomicWrite(TransferPath + '.audit', Stream, False);
      finally
        Stream.Free;
      end;
      try
        AtomicWrite(TransferPath, Document, False);
      except
        if not FileExists(TransferPath) then
          DeleteFile(TransferPath + '.audit');
        raise;
      end;
    finally
      DeleteFile(TempAudit);
      RemoveDir(TempDir);
    end;
  end;

begin
  if (FCommand = 'display_command_list') or (FCommand = 'help') then
  begin
    DisplayCommandList;
    Exit;
  end;
  if FCommand = 'display_command' then
  begin
    DisplayCommand(FArguments[0]);
    Exit;
  end;
  if IsSessionExit(FCommand) and not FInteractive then
    raise EScuError.CreateFmt('%s is only available in interactive mode.', [FCommand]);
  FLibraryPath := CanonicalFile(FLibraryPath);
  Verifying := FCommand = 'verify_audit';
  Initializing := (FCommand = 'initialize_library') or (FCommand = 'init');
  Importing := FCommand = 'import_library';
  Exporting := FCommand = 'export_library';
  Build := Default(TBuildRequest);
  Lock := nil;
  TransferLock := nil;
  Database := nil;
  Audit := nil;
  LibraryFile := nil;
  Committed := False;
  try
    // Always lock a JSON transfer path before the SQLite library path.
    if Importing or Exporting then
    begin
      TransferPath := OutputPath(FArguments[0]);
      OutputPath(TransferPath + '.audit');
      TransferLock := TLibraryLock.Create(OutputPath(TransferPath + '.lock'));
    end;
    Lock := TLibraryLock.Create(FLibraryPath + '.lock');
    Checkpoint := Option('head');
    if (FOptions.IndexOfName('head') >= 0) and not IsHexDigest(Checkpoint, 64) then
      raise EScuError.Create('Expected a lowercase SHA-256 audit head.');
    LibraryExists := RegularFileExists(FLibraryPath);
    AuditPath := FLibraryPath + '.audit';
    if IsSQLiteLibrary(FLibraryPath) then
    begin
      if FCommand = 'repair_audit' then
        raise EScuError.Create('repair_audit applies to JSON library audit files.');
      if not LibraryExists and not (Initializing or Importing) then
        RaiseMissingLibrary;
      Database := TSQLiteLibrary.Create(FLibraryPath, Initializing or Importing, Verifying);
      Database.BeginTransaction(Verifying);
      Database.EnsureSchema(Initializing or Importing);
      LibraryExists := Database.StateKey <> '';
      Audit := TAuditLog.Create(Database, Checkpoint, Verifying or Importing);
    end
    else
    begin
      if Importing or Exporting then
        raise EScuError.Create('JSON import and export require a selected SQLite library.');
      if not LibraryExists and not Initializing and not Verifying and not RegularFileExists(AuditPath) then
        RaiseMissingLibrary;
      Audit := TAuditLog.Create(AuditPath, Initializing and not LibraryExists, Verifying, Checkpoint,
        FCommand = 'repair_audit');
    end;
    if (LibraryExists or Assigned(FPendingLibrary)) and (Audit.Records = 0) then
      raise EScuError.Create('The audit log for the existing library is empty.');
    if Verifying then
    begin
      if Audit.SavedHeaderDigest <> '' then
      begin
        if not LibraryExists then
          RaiseMissingLibrary;
        LibraryFile := TDeckLibrary.Create(FLibraryPath, '', False, Database);
        Audit.VerifyContents(LibraryFile);
      end;
      WriteLn('records=', Audit.Records, ' interrupted=', Audit.Interrupted, ' head=', Audit.Head);
      Exit;
    end;
    if (FCommand = 'expand_modified_decks') and (OutputDirectory <> '') and LibraryExists and
      not Assigned(FPendingLibrary) then
    begin
      ExpansionVersion := FArguments[0];
      if SameText(ExpansionVersion, CurrentLibraryVersionSelector) then
        ExpansionVersion := Database.CurrentVersion;
      if Database.InvalidateExpansionOutput(ExpansionVersion, OutputDirectory, PrefixOption) then
      begin
        // Output files cannot roll back with SQLite. Invalidate before writing
        // files for a different version or prefix, even if expansion fails.
        Database.Commit;
        Database.BeginTransaction(False);
      end;
    end;
    if Importing and not LibraryExists then
    begin
      if not RegularFileExists(TransferPath) or IsSQLiteLibrary(TransferPath) then
        raise EScuError.Create('Expected an existing JSON library to import.');
      if RegularFileExists(TransferPath + '.audit') then
        Audit.ImportFile(TransferPath + '.audit');
    end;
    PreviousAuditRecords := Audit.Records;
    Audit.BeginCommand(FCommand, FArgumentNames, FArguments, FOptions);
    if Assigned(Database) then
      Database.Execute('SAVEPOINT scu_operation');
    SnapshotsUsed := Default(TAuditSnapshots);
    try
      if FCommand = 'repair_audit' then
        Detail := Format('Removed %d incomplete audit byte(s).', [Audit.RepairedBytes])
      else if Initializing then
      begin
        if LibraryExists or Audit.Initialized then
          raise EScuError.Create('A library already exists or was previously initialized here.');
        LibraryFile := TDeckLibrary.Create(FLibraryPath, '1.0', False, Database);
        LibraryFile.Save;
        Detail := 'Initialized version ' + LibraryFile.CurrentVersion;
      end
      else if Importing then
      begin
        if LibraryExists then
          raise EScuError.Create('The destination library already exists.');
        LibraryFile := TDeckLibrary.Create(TransferPath);
        Audit.VerifyContents(LibraryFile);
        LibraryFile.ImportInto(Database);
        SnapshotsUsed.Selected := LibraryFile.CurrentSnapshot;
        Detail := 'Imported JSON library.';
      end
      else
      begin
        if not Exporting then
          LibraryFile := FPendingLibrary;
        if not Assigned(LibraryFile) then
        begin
          if not LibraryExists then
            RaiseMissingLibrary;
          LibraryFile := TDeckLibrary.Create(FLibraryPath, '', FInteractive, Database);
        end
        else
          LibraryFile.AttachDatabase(Database);
        if Exporting then
        begin
          ExportLibrary;
          SnapshotsUsed.Selected := LibraryFile.CurrentSnapshot;
          Detail := 'Exported JSON library and audit log.';
        end
        else
        begin
          Detail := ExecuteLibrary(LibraryFile, Database, OutputDirectory, SnapshotsUsed, Build);
          if SessionSignal <> SIGHUP then
            Flush(Output);
          if Assigned(Database) and not FInteractive then
            LibraryFile.Save;
        end;
      end;
    except
      on E: Exception do
      begin
        if Assigned(Database) and not LibraryExists and (Initializing or Importing) then
          raise;
        try
          if Assigned(Database) then
            Database.Execute('ROLLBACK TO scu_operation');
          Audit.EndCommand(False, E.Message, SnapshotsUsed, Assigned(FPendingLibrary));
          if Assigned(Database) then
            Database.Commit;
        except
          on AuditError: Exception do
            raise EScuError.CreateFmt('%s Also could not save the audit outcome: %s',
              [E.Message, AuditError.Message]);
        end;
        raise;
      end;
    end;
    try
      PendingSave := FInteractive and Assigned(LibraryFile) and LibraryFile.Modified and
        not Initializing and not IsSessionExit(FCommand) and (FCommand <> 'save_library');
      Contents := nil;
      try
        if Assigned(LibraryFile) then
          Contents := LibraryFile.SavedContents;
        Audit.EndCommand(True, Detail, SnapshotsUsed, PendingSave, Contents);
      finally
        Contents.Free;
      end;
      if Assigned(Database) then
        Database.Commit;
      Committed := True;
      if Build.Command <> '' then
        Expansion := Audit.Head;
    except
      on E: Exception do
        raise EScuError.Create('Could not commit the command outcome: ' + E.Message);
    end;
    if (Detail <> '') and (SessionSignal <> SIGHUP) then
      WriteLn(Detail);
    if FCommand = 'display_library' then
      WriteLn(LibraryFile.HeaderJSON);
  finally
    if Assigned(LibraryFile) then
    begin
      LibraryFile.FinishDatabaseSave(Committed);
      if FInteractive and LibraryFile.Modified and not (Initializing or Importing or Exporting) then
        FPendingLibrary := LibraryFile
      else
      begin
        if LibraryFile = FPendingLibrary then
          FPendingLibrary := nil;
        LibraryFile.Free;
      end;
    end;
    Audit.Free;
    Database.Free;
    Lock.Free;
    TransferLock.Free;
  end;
  if Build.Command <> '' then
  begin
    Flush(Output);
    RunBuild(Build, AuditPath, Expansion);
  end;
end;

procedure TScuCLI.CompleteInteractiveLine(const Before, Prefix, After: string; Candidates: TStrings;
  out AppendCharacter: Char);
begin
  CompleteLine(FCommands, FLibraryPath, Before, Prefix, After, Candidates, AppendCharacter, FPendingLibrary);
end;

procedure TScuCLI.CompletePromptValue(const Before, Prefix, After: string; Candidates: TStrings;
  out AppendCharacter: Char);
var
  Context: TCompletionContext;
  Index: Integer;
begin
  AppendCharacter := #0;
  if After <> '' then
    Exit;
  Context.Version := Option('version');
  Context.Revision := Option('revision');
  for Index := 0 to FArgumentNames.Count - 1 do
    RecordCompletionValue(Context, FArgumentNames.Strings[Index], FArguments[Index]);
  CompleteValue(FCommands, FPromptParameter, Context, FLibraryPath, Before + Prefix, Prefix,
    #0, True, Candidates, AppendCharacter, FPendingLibrary);
end;

procedure TScuCLI.RunInteractive(Tokens: TStrings);
var
  Previous: TSessionSignalHandlers;
begin
  StartSessionSignals(Previous);
  try
    RunInteractiveSession(Tokens);
  finally
    RestoreSessionSignals(Previous);
  end;
end;

procedure TScuCLI.RecoverPendingLibrary;
var
  Path: string;
  Data: RawByteString;
begin
  if not Assigned(FPendingLibrary) then
    Exit;
  try
    Data := FPendingLibrary.ExportRecoveryJSON;
    Path := FLibraryPath + '.recovery-' + IntToStr(fpGetPid) + '.json';
    try
      AtomicWrite(Path, Data, False);
    except
      on E: Exception do
      begin
        Path := IncludeTrailingPathDelimiter(MakeTempDirectory('scu-recovery')) + 'library.json';
        AtomicWrite(Path, Data, False);
      end;
    end;
    WriteDiagnostic('scu: Saved pending changes in ' + Path);
  except
    on E: Exception do
      WriteDiagnostic('scu: Could not recover pending changes: ' + E.Message);
  end;
end;

procedure TScuCLI.RunInteractiveSession(Tokens: TStrings);
var
  Line, Prompt: string;
  OpeningLibrary, EndOfInput, SawCommand: Boolean;
begin
  FInteractive := True;
  Prompt := '';
  if IsATTY(Input) = 1 then
    Prompt := 'scu> ';
  OpeningLibrary := Prompt <> '';
  EndOfInput := False;
  SawCommand := False;
  repeat
    try
      if SessionSignal = SIGINT then
      begin
        SessionSignal := 0;
        raise ECommandCancelled.Create('Command cancelled.');
      end;
      if OpeningLibrary and (SessionSignal = 0) then
      begin
        OpeningLibrary := False;
        if (FindDefinition(FCommands, 'display_library') < 0) or
          not FileExists(FLibraryPath) then
          Continue;
        Tokens.Clear;
        Tokens.Add('display_library');
        ParseCommand(Tokens, 0, True);
      end
      else if (SessionSignal = 0) and ReadCommandLine(Prompt, Line, @CompleteInteractiveLine) then
      begin
        FCommand := '';
        try
          TokenizeCommand(Line, Tokens);
          if Tokens.Count = 0 then
            Continue;
          SawCommand := True;
          ParseCommand(Tokens, 0, Prompt <> '');
        finally
          if not IsSessionExit(FCommand) then
            RememberCommand(Line);
        end;
      end
      else
      begin
        if (SessionSignal = SIGTERM) or (SessionSignal = SIGQUIT) then
        begin
          ExitCode := 128 + SessionSignal;
          Exit;
        end;
        if SessionSignal = SIGINT then
          Continue;
        EndOfInput := (Prompt = '') or (SessionSignal = SIGHUP) or (IsATTY(Input) <> 1);
        if EndOfInput and (SessionSignal = 0) and not SawCommand and not FileExists(FLibraryPath) then
          raise EScuError.CreateFmt('Library "%s" does not exist. Use initialize_library to create it.',
            [FLibraryPath]);
        FCommand := 'quit_session';
        FOptions.Clear;
        FArgumentNames.Clear;
        FArgumentNames.Add('save_library');
        FArguments.Clear;
        FArguments.Add('yes');
      end;
      if IsSessionExit(FCommand) and not Assigned(FPendingLibrary) then
        Exit;
      RunCommand;
      if IsSessionExit(FCommand) then
        Exit;
    except
      on E: ECommandCancelled do
      begin
        if SessionSignal = SIGINT then
          SessionSignal := 0;
        WriteDiagnostic(E.Message);
      end;
      on E: Exception do
      begin
        WriteDiagnostic('scu: ' + E.Message);
        if EndOfInput and (SessionSignal = SIGHUP) then
          RecoverPendingLibrary;
        ExitCode := 1;
      end;
    end;
    if SessionSignal <> SIGHUP then
      Flush(Output);
  until EndOfInput;
end;

procedure TScuCLI.Run;
var
  Tokens: TStringList;
  Index, CommandIndex: Integer;
begin
  Tokens := TStringList.Create;
  try
    for Index := 1 to ParamCount do
      Tokens.Add(ParamStr(Index));
    CommandIndex := SelectLibrary(Tokens);
    if CommandIndex = Tokens.Count then
      RunInteractive(Tokens)
    else
    begin
      ParseCommand(Tokens, CommandIndex, False);
      RunCommand;
    end;
  finally
    Tokens.Free;
  end;
end;

end.
