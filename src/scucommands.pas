unit ScuCommands;

{$mode objfpc}{$H+}

interface

uses
  Contnrs;

type
  TParameterKind = (pkString, pkInteger, pkFloat, pkBoolean);
  TCompletionKind = (ckNone, ckBoolean, ckCommand, ckFile, ckDirectory, ckDeck,
    ckVersion, ckRevision, ckDeckVersion);

  TNamedDefinition = class
  private
    FName: string;
    FAliases: array of string;
    function GetAlias(Index: Integer): string;
    function GetAliasCount: Integer;
  public
    function Matches(const Spelling: string): Boolean;
    property Name: string read FName;
    property AliasCount: Integer read GetAliasCount;
    property Aliases[Index: Integer]: string read GetAlias;
  end;

  TParameterDefinition = class(TNamedDefinition)
  private
    FKind: TParameterKind;
    FCompletion: TCompletionKind;
    FDescription, FDefaultValue: string;
    FRequired, FHasDefault, FPromptForDefault: Boolean;
    function GetKindName: string;
  public
    procedure Validate(const Value: string);
    property KindName: string read GetKindName;
    property Completion: TCompletionKind read FCompletion;
    property Description: string read FDescription;
    property Required: Boolean read FRequired;
    property HasDefault: Boolean read FHasDefault;
    property DefaultValue: string read FDefaultValue;
    property PromptForDefault: Boolean read FPromptForDefault;
  end;

  TDefinitionList = class
  private
    FItems: TObjectList;
    function GetCount: Integer;
    function GetEntry(Index: Integer): TNamedDefinition;
    procedure Add(Entry: TNamedDefinition);
  public
    constructor Create;
    destructor Destroy; override;
    function FindIndex(const Spelling: string): Integer;
    property Count: Integer read GetCount;
    property Entries[Index: Integer]: TNamedDefinition read GetEntry;
  end;

  TParameterDefinitions = class(TDefinitionList)
  private
    function GetParameter(Index: Integer): TParameterDefinition;
  public
    property Items[Index: Integer]: TParameterDefinition read GetParameter; default;
  end;

  TCommandExample = record
    Command, Description: string;
  end;

  TExclusiveOption = record
    OptionIndex: Integer;
    Spelling: string;
  end;

  TCommandDefinition = class(TNamedDefinition)
  private
    FArguments, FOptions: TParameterDefinitions;
    FSummary, FHelpText, FHelpFile: string;
    FHasHelpText, FHasHelpFile: Boolean;
    FExamples: array of TCommandExample;
    FExclusiveGroups: array of array of TExclusiveOption;
    function GetExampleCount: Integer;
    function GetExample(Index: Integer): TCommandExample;
    function GetExclusiveGroupCount: Integer;
    function GetExclusiveGroupSize(Group: Integer): Integer;
    function GetExclusiveOption(Group, Member: Integer): TExclusiveOption;
  public
    constructor Create;
    destructor Destroy; override;
    property Arguments: TParameterDefinitions read FArguments;
    property Options: TParameterDefinitions read FOptions;
    property Summary: string read FSummary;
    property HasHelpText: Boolean read FHasHelpText;
    property HelpText: string read FHelpText;
    property HasHelpFile: Boolean read FHasHelpFile;
    property HelpFile: string read FHelpFile;
    property ExampleCount: Integer read GetExampleCount;
    property Examples[Index: Integer]: TCommandExample read GetExample;
    property ExclusiveGroupCount: Integer read GetExclusiveGroupCount;
    property ExclusiveGroupSize[Group: Integer]: Integer read GetExclusiveGroupSize;
    property ExclusiveOptions[Group, Member: Integer]: TExclusiveOption read GetExclusiveOption;
  end;

  TCommandDefinitions = class(TDefinitionList)
  private
    function GetCommand(Index: Integer): TCommandDefinition;
  public
    property Items[Index: Integer]: TCommandDefinition read GetCommand; default;
  end;

  TCommandCatalog = class
  private
    FCommands: TCommandDefinitions;
    FLibraryOption: TParameterDefinition;
    FLibraryDefault: string;
  public
    constructor Create(const Path: string);
    destructor Destroy; override;
    property Commands: TCommandDefinitions read FCommands;
    property LibraryOption: TParameterDefinition read FLibraryOption;
    property LibraryDefault: string read FLibraryDefault;
  end;

function TryParseYesNo(const Value: string; out Parsed: Boolean): Boolean;

implementation

uses
  SysUtils, Math, FPJSON, ScuErrors, ScuFiles, ScuJSON, ScuLegacyCatalog;

const
  ParameterKinds: array[TParameterKind] of string = ('string', 'integer', 'float', 'boolean');
  CompletionKinds: array[TCompletionKind] of string = ('', 'boolean', 'command', 'file',
    'directory', 'deck', 'version', 'revision', 'deck_version');

function TryParseYesNo(const Value: string; out Parsed: Boolean): Boolean;
begin
  Parsed := SameText(Value, 'yes') or SameText(Value, 'y');
  Result := Parsed or SameText(Value, 'no') or SameText(Value, 'n');
end;

function TNamedDefinition.GetAlias(Index: Integer): string;
begin
  Result := FAliases[Index];
end;

function TNamedDefinition.GetAliasCount: Integer;
begin
  Result := Length(FAliases);
end;

function TNamedDefinition.Matches(const Spelling: string): Boolean;
var
  Alias: string;
begin
  if SameText(Name, Spelling) then
    Exit(True);
  for Alias in FAliases do
    if SameText(Alias, Spelling) then
      Exit(True);
  Result := False;
end;

function TParameterDefinition.GetKindName: string;
begin
  Result := ParameterKinds[FKind];
end;

procedure TParameterDefinition.Validate(const Value: string);
var
  Index: SizeInt;
  IntegerValue: Int64;
  FloatValue: Extended;
  Settings: TFormatSettings;
  Valid, Parsed: Boolean;
begin
  case FKind of
    pkString: Exit;
    pkBoolean:
      begin
        if not TryParseYesNo(Value, Parsed) then
          raise EScuError.CreateFmt('Expected yes/y or no/n for %s.', [Name]);
        Exit;
      end;
    pkInteger:
      begin
        Index := 1;
        if (Value <> '') and (Value[1] in ['+', '-']) then
          Inc(Index);
        Valid := Index <= Length(Value);
        while Valid and (Index <= Length(Value)) do
        begin
          Valid := Value[Index] in ['0'..'9'];
          Inc(Index);
        end;
        Valid := Valid and TryStrToInt64(Value, IntegerValue);
      end;
    pkFloat:
      begin
        Settings := DefaultFormatSettings;
        Settings.DecimalSeparator := '.';
        Settings.ThousandSeparator := #0;
        Valid := (Value = Trim(Value)) and TryStrToFloat(Value, FloatValue, Settings) and
          not IsNan(FloatValue) and not IsInfinite(FloatValue);
      end;
  end;
  if not Valid then
    raise EScuError.CreateFmt('Expected %s value for %s.', [KindName, Name]);
end;

constructor TDefinitionList.Create;
begin
  inherited Create;
  FItems := TObjectList.Create(True);
end;

destructor TDefinitionList.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

function TDefinitionList.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TDefinitionList.GetEntry(Index: Integer): TNamedDefinition;
begin
  Result := TNamedDefinition(FItems[Index]);
end;

function TDefinitionList.FindIndex(const Spelling: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if Entries[Index].Matches(Spelling) then
      Exit(Index);
  Result := -1;
end;

procedure CheckSpelling(List: TDefinitionList; const Spelling: string);
begin
  if List.FindIndex(Spelling) >= 0 then
    raise EScuError.CreateFmt('Ambiguous name or alias "%s" in commands.json.', [Spelling]);
end;

procedure CheckNames(List: TDefinitionList; Entry: TNamedDefinition);
var
  Index: Integer;
begin
  CheckSpelling(List, Entry.Name);
  for Index := 0 to Entry.AliasCount - 1 do
    CheckSpelling(List, Entry.Aliases[Index]);
end;

procedure TDefinitionList.Add(Entry: TNamedDefinition);
begin
  try
    CheckNames(Self, Entry);
    FItems.Add(Entry);
  except
    Entry.Free;
    raise;
  end;
end;

function TParameterDefinitions.GetParameter(Index: Integer): TParameterDefinition;
begin
  Result := TParameterDefinition(Entries[Index]);
end;

constructor TCommandDefinition.Create;
begin
  inherited Create;
  FArguments := TParameterDefinitions.Create;
  FOptions := TParameterDefinitions.Create;
end;

destructor TCommandDefinition.Destroy;
begin
  FOptions.Free;
  FArguments.Free;
  inherited Destroy;
end;

function TCommandDefinition.GetExampleCount: Integer;
begin
  Result := Length(FExamples);
end;

function TCommandDefinition.GetExample(Index: Integer): TCommandExample;
begin
  Result := FExamples[Index];
end;

function TCommandDefinition.GetExclusiveGroupCount: Integer;
begin
  Result := Length(FExclusiveGroups);
end;

function TCommandDefinition.GetExclusiveGroupSize(Group: Integer): Integer;
begin
  Result := Length(FExclusiveGroups[Group]);
end;

function TCommandDefinition.GetExclusiveOption(Group, Member: Integer): TExclusiveOption;
begin
  Result := FExclusiveGroups[Group][Member];
end;

function TCommandDefinitions.GetCommand(Index: Integer): TCommandDefinition;
begin
  Result := TCommandDefinition(Entries[Index]);
end;

function OptionalField(Entry: TJSONObject; const Key: string; Kind: TJSONType): TJSONData;
begin
  Result := Entry.Find(Key);
  if Assigned(Result) and (Result.JSONType <> Kind) then
    raise EScuError.CreateFmt('Invalid JSON field "%s".', [Key]);
end;

function OptionalText(Entry: TJSONObject; const Key: string): string;
var
  Value: TJSONData;
begin
  Value := OptionalField(Entry, Key, jtString);
  if Assigned(Value) then
    Exit(Value.AsString);
  Result := '';
end;

function ObjectAt(Entries: TJSONArray; Index: Integer): TJSONObject;
begin
  if not (Entries.Items[Index] is TJSONObject) then
    raise EScuError.Create('Expected a definition object in commands.json.');
  Result := TJSONObject(Entries.Items[Index]);
end;

procedure LoadNames(Entry: TJSONObject; Definition: TNamedDefinition);
var
  Aliases: TJSONArray;
  Index: Integer;
begin
  Definition.FName := Field(Entry, 'name', jtString).AsString;
  if Definition.Name = '' then
    raise EScuError.Create('A command or parameter name cannot be empty.');
  Aliases := TJSONArray(OptionalField(Entry, 'aliases', jtArray));
  if not Assigned(Aliases) then
    Exit;
  SetLength(Definition.FAliases, Aliases.Count);
  for Index := 0 to Aliases.Count - 1 do
  begin
    if (Aliases.Items[Index].JSONType <> jtString) or (Aliases.Strings[Index] = '') then
      raise EScuError.CreateFmt('Expected a nonempty alias string for "%s".', [Definition.Name]);
    Definition.FAliases[Index] := Aliases.Strings[Index];
  end;
end;

function ParseParameterKind(const Kind, Name: string): TParameterKind;
begin
  for Result := Low(TParameterKind) to High(TParameterKind) do
    if ParameterKinds[Result] = Kind then
      Exit;
  raise EScuError.CreateFmt('Unknown argument type "%s" for %s in commands.json.', [Kind, Name]);
end;

function ParseCompletionKind(const Kind, Name: string): TCompletionKind;
begin
  for Result := Low(TCompletionKind) to High(TCompletionKind) do
    if CompletionKinds[Result] = Kind then
      Exit;
  raise EScuError.CreateFmt('Unknown completion kind "%s" for %s in commands.json.', [Kind, Name]);
end;

procedure LoadDefault(Parameter: TParameterDefinition; Value: TJSONData);
begin
  if not Assigned(Value) then
    Exit;
  if Parameter.Required then
    raise EScuError.CreateFmt('Required argument %s cannot have a default value.', [Parameter.Name]);
  case Value.JSONType of
    jtString: Parameter.FDefaultValue := Value.AsString;
    jtNumber: Parameter.FDefaultValue := Value.AsJSON;
    jtBoolean:
      begin
        if Parameter.FKind <> pkBoolean then
          raise EScuError.CreateFmt('Boolean default requires boolean type for %s.', [Parameter.Name]);
        if Value.AsBoolean then
          Parameter.FDefaultValue := 'yes'
        else
          Parameter.FDefaultValue := 'no';
      end;
    else raise EScuError.CreateFmt('Expected a string, number, or Boolean default for %s.', [Parameter.Name]);
  end;
  Parameter.Validate(Parameter.DefaultValue);
  Parameter.FHasDefault := True;
end;

function LoadParameter(Entry, Defaults: TJSONObject; Positional: Boolean): TParameterDefinition;
var
  Rule, Value: TJSONData;
begin
  Result := TParameterDefinition.Create;
  try
    LoadNames(Entry, Result);
    Result.FKind := ParseParameterKind(Field(Entry, 'type', jtString).AsString, Result.Name);
    Result.FDescription := OptionalText(Entry, 'description');
    Value := OptionalField(Entry, 'completion', jtString);
    if Assigned(Value) then
      Result.FCompletion := ParseCompletionKind(Value.AsString, Result.Name)
    else if Result.FKind = pkBoolean then
      Result.FCompletion := ckBoolean;
    Value := OptionalField(Entry, 'prompt_for_default', jtBoolean);
    Result.FPromptForDefault := not Assigned(Value) or Value.AsBoolean;

    Rule := Entry.Find('value');
    Result.FRequired := Positional;
    if Assigned(Rule) then
    begin
      Result.FRequired := (Rule.JSONType = jtString) and (Rule.AsString = 'scu$required');
      if Result.FRequired or ((Rule.JSONType = jtString) and (Rule.AsString = 'scu$optional')) then
        Rule := nil;
    end;
    if not Assigned(Rule) and Assigned(Defaults) then
      Rule := Defaults.Find(Result.Name);
    LoadDefault(Result, Rule);
  except
    Result.Free;
    raise;
  end;
end;

procedure LoadParameters(Entries: TJSONArray; Defaults: TJSONObject;
  List: TParameterDefinitions; Positional: Boolean);
var
  Index: Integer;
begin
  for Index := 0 to Entries.Count - 1 do
    List.Add(LoadParameter(ObjectAt(Entries, Index), Defaults, Positional));
end;

procedure LoadExclusiveGroups(Entry: TJSONObject; Definition: TCommandDefinition);
var
  Groups, Group: TJSONArray;
  GroupIndex, MemberIndex, Slot: Integer;
  Spelling: string;
begin
  Groups := TJSONArray(OptionalField(Entry, 'exclusive_options', jtArray));
  if not Assigned(Groups) then
    Exit;
  SetLength(Definition.FExclusiveGroups, Groups.Count);
  for GroupIndex := 0 to Groups.Count - 1 do
  begin
    if not (Groups.Items[GroupIndex] is TJSONArray) then
      raise EScuError.Create('Expected an array of names in exclusive_options.');
    Group := TJSONArray(Groups.Items[GroupIndex]);
    SetLength(Definition.FExclusiveGroups[GroupIndex], Group.Count);
    for MemberIndex := 0 to Group.Count - 1 do
    begin
      if Group.Items[MemberIndex].JSONType <> jtString then
        raise EScuError.Create('Expected an option name in exclusive_options.');
      Spelling := Group.Strings[MemberIndex];
      Slot := Definition.Options.FindIndex(Spelling);
      if Slot < 0 then
        raise EScuError.CreateFmt('Unknown option "%s" in exclusive_options for %s.',
          [Spelling, Definition.Name]);
      Definition.FExclusiveGroups[GroupIndex][MemberIndex].OptionIndex := Slot;
      Definition.FExclusiveGroups[GroupIndex][MemberIndex].Spelling := Spelling;
    end;
  end;
end;

procedure LoadExamples(Entry: TJSONObject; Definition: TCommandDefinition);
var
  Entries: TJSONArray;
  Example: TJSONObject;
  Index: Integer;
begin
  Entries := TJSONArray(OptionalField(Entry, 'examples', jtArray));
  if not Assigned(Entries) then
    Exit;
  SetLength(Definition.FExamples, Entries.Count);
  for Index := 0 to Entries.Count - 1 do
  begin
    Example := ObjectAt(Entries, Index);
    Definition.FExamples[Index].Command := Field(Example, 'command', jtString).AsString;
    Definition.FExamples[Index].Description := Field(Example, 'description', jtString).AsString;
  end;
end;

procedure CheckDefaultNames(Defaults: TJSONObject; Definition: TCommandDefinition);
var
  Index, Slot: Integer;
  Name: string;
begin
  if not Assigned(Defaults) then
    Exit;
  for Index := 0 to Defaults.Count - 1 do
  begin
    Name := Defaults.Names[Index];
    Slot := Definition.Arguments.FindIndex(Name);
    if (Slot >= 0) and (Definition.Arguments[Slot].Name = Name) then
      Continue;
    Slot := Definition.Options.FindIndex(Name);
    if (Slot < 0) or (Definition.Options[Slot].Name <> Name) then
      raise EScuError.CreateFmt('Unknown parameter "%s" in default_values for %s.', [Name, Definition.Name]);
  end;
end;

function LoadCommand(Entry: TJSONObject): TCommandDefinition;
var
  Defaults: TJSONObject;
  Index: Integer;
begin
  Result := TCommandDefinition.Create;
  try
    LoadNames(Entry, Result);
    Result.FSummary := OptionalText(Entry, 'summary');
    Result.FHelpText := OptionalText(Entry, 'help');
    Result.FHelpFile := OptionalText(Entry, 'help_file');
    Result.FHasHelpText := Assigned(Entry.Find('help'));
    Result.FHasHelpFile := Assigned(Entry.Find('help_file'));
    Defaults := TJSONObject(OptionalField(Entry, 'default_values', jtObject));
    LoadParameters(TJSONArray(Field(Entry, 'arguments', jtArray)), Defaults, Result.Arguments, True);
    LoadParameters(TJSONArray(Field(Entry, 'options', jtArray)), Defaults, Result.Options, False);
    for Index := 0 to Result.Options.Count - 1 do
      CheckNames(Result.Arguments, Result.Options[Index]);
    CheckDefaultNames(Defaults, Result);
    LoadExclusiveGroups(Entry, Result);
    LoadExamples(Entry, Result);
  except
    Result.Free;
    raise;
  end;
end;

constructor TCommandCatalog.Create(const Path: string);
var
  Definitions, LibraryEntry: TJSONObject;
  Entries: TJSONArray;
  Index: Integer;
begin
  inherited Create;
  FCommands := TCommandDefinitions.Create;
  try
    Definitions := ParseObject(ReadBytes(Path, 1024 * 1024));
    try
      PrepareCommandDefinitions(Definitions);
      LibraryEntry := TJSONObject(Field(Definitions, 'library_option', jtObject));
      FLibraryOption := LoadParameter(LibraryEntry, nil, False);
      FLibraryDefault := Field(LibraryEntry, 'default', jtString).AsString;
      FLibraryOption.Validate(FLibraryDefault);
      Entries := TJSONArray(Field(Definitions, 'commands', jtArray));
      for Index := 0 to Entries.Count - 1 do
        FCommands.Add(LoadCommand(ObjectAt(Entries, Index)));
    finally
      Definitions.Free;
    end;
  except
    on E: Exception do
      raise EScuError.CreateFmt('Could not load command catalog "%s": %s', [Path, E.Message]);
  end;
end;

destructor TCommandCatalog.Destroy;
begin
  FLibraryOption.Free;
  FCommands.Free;
  inherited Destroy;
end;

end.
