unit ScuCommands;

{$mode objfpc}{$H+}

interface

uses
  Contnrs;

type
  TParameterKind = (pkString, pkInteger, pkFloat, pkEnum);
  TCompletionKind = (ckNone, ckCommand, ckFile, ckDirectory, ckDeck,
    ckVersion, ckRevision, ckDeckVersion, ckLibraryVersion, ckEnum, ckLibraryFile);

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
    FValues: TObjectList;
    FRequired, FHasDefault, FPromptForDefault: Boolean;
    function GetEnumValue(Index: Integer): TNamedDefinition;
    function GetValue(Index: Integer): string;
    function GetValueCount: Integer;
    function GetValuesText: string;
    function GetKindName: string;
  public
    destructor Destroy; override;
    procedure Validate(const Value: string);
    function CanonicalValue(const Value: string): string;
    property EnumValues[Index: Integer]: TNamedDefinition read GetEnumValue;
    property ValueCount: Integer read GetValueCount;
    property Values[Index: Integer]: string read GetValue;
    property ValuesText: string read GetValuesText;
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

  TExclusiveArgument = record
    ArgumentIndex: Integer;
    Spelling: string;
  end;

  TCommandDefinition = class(TNamedDefinition)
  private
    FArguments: TParameterDefinitions;
    FSummary, FHelpText, FHelpFile: string;
    FHasHelpText, FHasHelpFile: Boolean;
    FExamples: array of TCommandExample;
    FExclusiveGroups: array of array of TExclusiveArgument;
    function GetExampleCount: Integer;
    function GetExample(Index: Integer): TCommandExample;
    function GetExclusiveGroupCount: Integer;
    function GetExclusiveGroupSize(Group: Integer): Integer;
    function GetExclusiveArgument(Group, Member: Integer): TExclusiveArgument;
  public
    constructor Create;
    destructor Destroy; override;
    property Arguments: TParameterDefinitions read FArguments;
    property Summary: string read FSummary;
    property HasHelpText: Boolean read FHasHelpText;
    property HelpText: string read FHelpText;
    property HasHelpFile: Boolean read FHasHelpFile;
    property HelpFile: string read FHelpFile;
    property ExampleCount: Integer read GetExampleCount;
    property Examples[Index: Integer]: TCommandExample read GetExample;
    property ExclusiveGroupCount: Integer read GetExclusiveGroupCount;
    property ExclusiveGroupSize[Group: Integer]: Integer read GetExclusiveGroupSize;
    property ExclusiveArguments[Group, Member: Integer]: TExclusiveArgument read GetExclusiveArgument;
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
    FSourceName: string;
    FLibraryArgument: TParameterDefinition;
    FLibraryDefault: string;
    FBatchArgument: TParameterDefinition;
  public
    constructor Create(const Path: string; UseEmbeddedIfMissing: Boolean = False);
    destructor Destroy; override;
    property Commands: TCommandDefinitions read FCommands;
    property SourceName: string read FSourceName;
    property LibraryArgument: TParameterDefinition read FLibraryArgument;
    property BatchArgument: TParameterDefinition read FBatchArgument;
    property LibraryDefault: string read FLibraryDefault;
  end;

function TryParseYesNo(const Value: string; out Parsed: Boolean): Boolean;

implementation

uses
  SysUtils, Math, FPJSON, ScuErrors, ScuFiles, ScuJSON, ScuEmbeddedCommands;

const
  ParameterKinds: array[TParameterKind] of string = ('string', 'integer', 'float', 'enum');
  CompletionKinds: array[TCompletionKind] of string = ('', 'command', 'file',
    'directory', 'deck', 'version', 'revision', 'deck_version', 'library_version', 'enum', 'library_file');

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

function TParameterDefinition.GetValue(Index: Integer): string;
begin
  Result := EnumValues[Index].Name;
end;

function TParameterDefinition.GetValueCount: Integer;
begin
  Result := 0;
  if Assigned(FValues) then
    Result := FValues.Count;
end;

destructor TParameterDefinition.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

function TParameterDefinition.GetEnumValue(Index: Integer): TNamedDefinition;
begin
  Result := TNamedDefinition(FValues[Index]);
end;

function TParameterDefinition.CanonicalValue(const Value: string): string;
var
  Index: Integer;
begin
  if FKind = pkEnum then
    for Index := 0 to ValueCount - 1 do
      if EnumValues[Index].Matches(Value) then
        Exit(EnumValues[Index].Name);
  Result := Value;
end;

function TParameterDefinition.GetValuesText: string;
var
  Index, AliasIndex: Integer;
  Entry: TNamedDefinition;
begin
  Result := '[';
  for Index := 0 to ValueCount - 1 do
  begin
    if Index > 0 then
      Result := Result + ', ';
    Entry := EnumValues[Index];
    Result := Result + Entry.Name;
    if Entry.AliasCount > 0 then
    begin
      Result := Result + ' (';
      for AliasIndex := 0 to Entry.AliasCount - 1 do
      begin
        if AliasIndex > 0 then
          Result := Result + ', ';
        Result := Result + Entry.Aliases[AliasIndex];
      end;
      Result := Result + ')';
    end;
  end;
  Result := Result + ']';
end;

procedure TParameterDefinition.Validate(const Value: string);
var
  Index: SizeInt;
  IntegerValue: Int64;
  FloatValue: Extended;
  Settings: TFormatSettings;
  Valid: Boolean;
begin
  case FKind of
    pkString: Exit;
    pkEnum:
      begin
        for Index := 0 to ValueCount - 1 do
          if EnumValues[Index].Matches(Value) then
            Exit;
        raise EScuError.CreateFmt('Expected one of %s for %s.', [ValuesText, Name]);
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
end;

destructor TCommandDefinition.Destroy;
begin
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

function TCommandDefinition.GetExclusiveArgument(Group, Member: Integer): TExclusiveArgument;
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

procedure LoadEnumValues(Entry: TJSONObject; Parameter: TParameterDefinition);
var
  Values: TJSONArray;
  Index, AliasIndex, AliasIndexCheck: Integer;
  Choice, Previous: TNamedDefinition;

  procedure CheckValue(const Value: string);
  var
    Character: Char;
    PreviousIndex: Integer;
  begin
    if (Value = '') or (Trim(Value) <> Value) then
      raise EScuError.CreateFmt('Expected a nonempty enum value without surrounding whitespace for %s.', [Parameter.Name]);
    for Character in Value do
      if Character < #32 then
        raise EScuError.CreateFmt('Enum values must be on one line for %s.', [Parameter.Name]);
    for PreviousIndex := 0 to Parameter.ValueCount - 1 do
    begin
      Previous := Parameter.EnumValues[PreviousIndex];
      if Previous.Matches(Value) then
        raise EScuError.CreateFmt('Duplicate enum value or alias "%s" for %s.', [Value, Parameter.Name]);
    end;
  end;

begin
  Values := TJSONArray(OptionalField(Entry, 'values', jtArray));
  if Parameter.FKind <> pkEnum then
  begin
    if Assigned(Values) then
      raise EScuError.CreateFmt('Allowed values require enum type for %s.', [Parameter.Name]);
    Exit;
  end;
  if not Assigned(Values) or (Values.Count = 0) then
    raise EScuError.CreateFmt('Expected nonempty enum values for %s.', [Parameter.Name]);
  Parameter.FValues := TObjectList.Create(True);
  for Index := 0 to Values.Count - 1 do
  begin
    Choice := TNamedDefinition.Create;
    try
      case Values.Items[Index].JSONType of
        jtString: Choice.FName := Values.Strings[Index];
        jtObject: LoadNames(TJSONObject(Values.Items[Index]), Choice);
        else raise EScuError.CreateFmt('Expected an enum string or definition object for %s.', [Parameter.Name]);
      end;
      CheckValue(Choice.Name);
      for AliasIndex := 0 to Choice.AliasCount - 1 do
      begin
        CheckValue(Choice.Aliases[AliasIndex]);
        if SameText(Choice.Name, Choice.Aliases[AliasIndex]) then
          raise EScuError.CreateFmt('Duplicate enum value or alias "%s" for %s.', [Choice.Aliases[AliasIndex], Parameter.Name]);
        for AliasIndexCheck := 0 to AliasIndex - 1 do
          if SameText(Choice.Aliases[AliasIndexCheck], Choice.Aliases[AliasIndex]) then
            raise EScuError.CreateFmt('Duplicate enum value or alias "%s" for %s.', [Choice.Aliases[AliasIndex], Parameter.Name]);
      end;
      Parameter.FValues.Add(Choice);
      Choice := nil;
    finally
      Choice.Free;
    end;
  end;
end;

procedure LoadDefault(Parameter: TParameterDefinition; Value: TJSONData);
begin
  if not Assigned(Value) then
    Exit;
  if Parameter.Required then
    raise EScuError.CreateFmt('Required argument %s cannot have a default value.', [Parameter.Name]);
  if (Parameter.FKind = pkEnum) and (Value.JSONType <> jtString) then
    raise EScuError.CreateFmt('Expected a string default for enum %s.', [Parameter.Name]);
  case Value.JSONType of
    jtString: Parameter.FDefaultValue := Value.AsString;
    jtNumber: Parameter.FDefaultValue := Value.AsJSON;
    else raise EScuError.CreateFmt('Expected a string or number default for %s.', [Parameter.Name]);
  end;
  Parameter.Validate(Parameter.DefaultValue);
  Parameter.FDefaultValue := Parameter.CanonicalValue(Parameter.DefaultValue);
  Parameter.FHasDefault := True;
end;

function LoadParameter(Entry, Defaults: TJSONObject): TParameterDefinition;
var
  Rule, Value: TJSONData;
begin
  Result := TParameterDefinition.Create;
  try
    LoadNames(Entry, Result);
    Result.FKind := ParseParameterKind(Field(Entry, 'type', jtString).AsString, Result.Name);
    LoadEnumValues(Entry, Result);
    Result.FDescription := OptionalText(Entry, 'description');
    Value := OptionalField(Entry, 'completion', jtString);
    if Assigned(Value) then
      Result.FCompletion := ParseCompletionKind(Value.AsString, Result.Name)
    else if Result.FKind = pkEnum then
      Result.FCompletion := ckEnum;
    if ((Result.FKind = pkEnum) and (Result.FCompletion <> ckEnum)) or
      ((Result.FKind <> pkEnum) and (Result.FCompletion = ckEnum)) then
      raise EScuError.CreateFmt('Enum completion requires enum type and values for %s.', [Result.Name]);
    Value := OptionalField(Entry, 'prompt_for_default', jtBoolean);
    Result.FPromptForDefault := not Assigned(Value) or Value.AsBoolean;

    Rule := Entry.Find('value');
    Result.FRequired := False;
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
  List: TParameterDefinitions);
var
  Index: Integer;
begin
  for Index := 0 to Entries.Count - 1 do
    List.Add(LoadParameter(ObjectAt(Entries, Index), Defaults));
end;

procedure LoadExclusiveGroups(Entry: TJSONObject; Definition: TCommandDefinition);
var
  Groups, Group: TJSONArray;
  GroupIndex, MemberIndex, Slot: Integer;
  Spelling: string;
begin
  Groups := TJSONArray(OptionalField(Entry, 'exclusive_arguments', jtArray));
  if not Assigned(Groups) then
    Exit;
  SetLength(Definition.FExclusiveGroups, Groups.Count);
  for GroupIndex := 0 to Groups.Count - 1 do
  begin
    if not (Groups.Items[GroupIndex] is TJSONArray) then
      raise EScuError.Create('Expected an array of names in exclusive_arguments.');
    Group := TJSONArray(Groups.Items[GroupIndex]);
    SetLength(Definition.FExclusiveGroups[GroupIndex], Group.Count);
    for MemberIndex := 0 to Group.Count - 1 do
    begin
      if Group.Items[MemberIndex].JSONType <> jtString then
        raise EScuError.Create('Expected an argument name in exclusive_arguments.');
      Spelling := Group.Strings[MemberIndex];
      Slot := Definition.Arguments.FindIndex(Spelling);
      if Slot < 0 then
        raise EScuError.CreateFmt('Unknown argument "%s" in exclusive_arguments for %s.',
          [Spelling, Definition.Name]);
      Definition.FExclusiveGroups[GroupIndex][MemberIndex].ArgumentIndex := Slot;
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
    if (Slot < 0) or (Definition.Arguments[Slot].Name <> Name) then
      raise EScuError.CreateFmt('Unknown parameter "%s" in default_values for %s.', [Name, Definition.Name]);
  end;
end;

function LoadCommand(Entry: TJSONObject): TCommandDefinition;
var
  Defaults: TJSONObject;
begin
  Result := TCommandDefinition.Create;
  try
    if Assigned(Entry.Find('options')) then
      raise EScuError.Create('Use a single arguments list; options is not supported in commands.json.');
    LoadNames(Entry, Result);
    Result.FSummary := OptionalText(Entry, 'summary');
    Result.FHelpText := OptionalText(Entry, 'help');
    Result.FHelpFile := OptionalText(Entry, 'help_file');
    Result.FHasHelpText := Assigned(Entry.Find('help'));
    Result.FHasHelpFile := Assigned(Entry.Find('help_file'));
    Defaults := TJSONObject(OptionalField(Entry, 'default_values', jtObject));
    LoadParameters(TJSONArray(Field(Entry, 'arguments', jtArray)), Defaults, Result.Arguments);
    CheckDefaultNames(Defaults, Result);
    LoadExclusiveGroups(Entry, Result);
    LoadExamples(Entry, Result);
  except
    Result.Free;
    raise;
  end;
end;

constructor TCommandCatalog.Create(const Path: string; UseEmbeddedIfMissing: Boolean);
var
  Definitions, LibraryEntry: TJSONObject;
  Entries: TJSONArray;
  Index: Integer;
  Bytes: RawByteString;
begin
  inherited Create;
  FSourceName := Path;
  FCommands := TCommandDefinitions.Create;
  try
    if UseEmbeddedIfMissing and not FileEntryExists(Path) then
    begin
      FSourceName := 'embedded commands.json';
      Bytes := EmbeddedCommandsJSON;
    end
    else Bytes := ReadBytes(Path, 1024 * 1024);
    Definitions := ParseObject(Bytes);
    try
      if IntegerField(Definitions, 'format') <> 4 then
        raise EScuError.Create('Unsupported commands.json format. Expected format 4.');
      LibraryEntry := TJSONObject(Field(Definitions, 'library_argument', jtObject));
      FLibraryArgument := LoadParameter(LibraryEntry, nil);
      FLibraryDefault := Field(LibraryEntry, 'default', jtString).AsString;
      FLibraryArgument.Validate(FLibraryDefault);
      if Assigned(Definitions.Find('batch_argument')) then
        FBatchArgument := LoadParameter(TJSONObject(Field(Definitions, 'batch_argument', jtObject)), nil);
      Entries := TJSONArray(Field(Definitions, 'commands', jtArray));
      for Index := 0 to Entries.Count - 1 do
        FCommands.Add(LoadCommand(ObjectAt(Entries, Index)));
    finally
      Definitions.Free;
    end;
  except
    on E: ECommandCancelled do raise;
    on E: Exception do
      raise EScuError.CreateFmt('Could not load command catalog "%s": %s', [FSourceName, E.Message]);
  end;
end;

destructor TCommandCatalog.Destroy;
begin
  FBatchArgument.Free;
  FLibraryArgument.Free;
  FCommands.Free;
  inherited Destroy;
end;

end.
