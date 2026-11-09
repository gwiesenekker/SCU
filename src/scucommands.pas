unit ScuCommands;

{$mode objfpc}{$H+}

interface

uses
  FPJSON;

procedure PrepareCommandDefinitions(Definitions: TJSONObject);
function DefinitionAt(Entries: TJSONArray; Index: Integer): TJSONObject;
function DefinitionName(Entry: TJSONObject): string;
function DefinitionAliases(Entry: TJSONObject): TJSONArray;
function ExclusiveOptionGroups(Command: TJSONObject): TJSONArray;
function MatchesDefinition(Entry: TJSONObject; const Name: string): Boolean;
function FindDefinition(Entries: TJSONArray; const Name: string): Integer;
function TryParseYesNo(const Value: string; out Parsed: Boolean): Boolean;
procedure ValidateParameter(Entry: TJSONObject; const Value: string);
function ParameterDescription(Entry: TJSONObject): string;
function ParameterRequired(Entry: TJSONObject; Positional: Boolean): Boolean;
function ParameterDefault(Command, Entry: TJSONObject; Positional: Boolean;
  out Value: string): Boolean;

implementation

uses
  SysUtils, Math, ScuIO, ScuJSON;

function DefinitionAt(Entries: TJSONArray; Index: Integer): TJSONObject;
begin
  if not (Entries.Items[Index] is TJSONObject) then
    raise EScuError.Create('Expected a definition object in commands.json.');
  Result := TJSONObject(Entries.Items[Index]);
end;

function DefinitionName(Entry: TJSONObject): string;
begin
  Result := Field(Entry, 'name', jtString).AsString;
end;

function DefinitionAliases(Entry: TJSONObject): TJSONArray;
var
  Aliases: TJSONData;
begin
  Aliases := Entry.Find('aliases');
  if Assigned(Aliases) and not (Aliases is TJSONArray) then
    raise EScuError.CreateFmt('Expected an aliases array for "%s" in commands.json.',
      [DefinitionName(Entry)]);
  Result := TJSONArray(Aliases);
end;

function ExclusiveOptionGroups(Command: TJSONObject): TJSONArray;
var
  Groups: TJSONData;
  Index: Integer;
begin
  Groups := Command.Find('exclusive_options');
  if not Assigned(Groups) then
    Exit(nil);
  Result := TJSONArray(Field(Command, 'exclusive_options', jtArray));
  for Index := 0 to Result.Count - 1 do
    if not (Result.Items[Index] is TJSONArray) then
      raise EScuError.Create('Expected an array of names in exclusive_options.');
end;

function MatchesDefinition(Entry: TJSONObject; const Name: string): Boolean;
var
  Aliases: TJSONArray;
  Index: Integer;
begin
  if SameText(DefinitionName(Entry), Name) then
    Exit(True);
  Aliases := DefinitionAliases(Entry);
  if Assigned(Aliases) then
    for Index := 0 to Aliases.Count - 1 do
      if SameText(Aliases.Strings[Index], Name) then
        Exit(True);
  Result := False;
end;

function FindDefinition(Entries: TJSONArray; const Name: string): Integer;
var
  Index: Integer;
begin
  Result := -1;
  for Index := 0 to Entries.Count - 1 do
    if MatchesDefinition(DefinitionAt(Entries, Index), Name) then
    begin
      if Result >= 0 then
        raise EScuError.CreateFmt('Ambiguous name or alias "%s" in commands.json.', [Name]);
      Result := Index;
    end;
end;

function TryParseYesNo(const Value: string; out Parsed: Boolean): Boolean;
begin
  Parsed := SameText(Value, 'yes') or SameText(Value, 'y');
  Result := Parsed or SameText(Value, 'no') or SameText(Value, 'n');
end;

procedure ValidateParameter(Entry: TJSONObject; const Value: string);
var
  Kind: string;
  Index: SizeInt;
  IntegerValue: Int64;
  FloatValue: Extended;
  Settings: TFormatSettings;
  Valid, Parsed: Boolean;
begin
  Kind := Field(Entry, 'type', jtString).AsString;
  case Kind of
    'string': Exit;
    'boolean':
      begin
        if not TryParseYesNo(Value, Parsed) then
          raise EScuError.CreateFmt('Expected yes/y or no/n for %s.', [DefinitionName(Entry)]);
        Exit;
      end;
    'integer':
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
    'float':
      begin
        Settings := DefaultFormatSettings;
        Settings.DecimalSeparator := '.';
        Settings.ThousandSeparator := #0;
        Valid := (Value = Trim(Value)) and TryStrToFloat(Value, FloatValue, Settings) and
          not IsNan(FloatValue) and not IsInfinite(FloatValue);
      end;
    else
      raise EScuError.CreateFmt('Unknown argument type "%s" for %s in commands.json.',
        [Kind, DefinitionName(Entry)]);
  end;
  if not Valid then
    raise EScuError.CreateFmt('Expected %s value for %s.', [Kind, DefinitionName(Entry)]);
end;

function ParameterDescription(Entry: TJSONObject): string;
var
  Description: TJSONData;
begin
  Description := Entry.Find('description');
  if Assigned(Description) then
    Result := Description.AsString
  else
    Result := '';
end;

function ParameterRequired(Entry: TJSONObject; Positional: Boolean): Boolean;
var
  Rule: TJSONData;
begin
  Rule := Entry.Find('value');
  if not Assigned(Rule) then
    Exit(Positional);
  Result := (Rule.JSONType = jtString) and (Rule.AsString = 'scu$required');
end;

function ParameterDefault(Command, Entry: TJSONObject; Positional: Boolean;
  out Value: string): Boolean;
var
  Defaults, Item: TJSONData;
  Name: string;
begin
  Name := DefinitionName(Entry);
  Item := Entry.Find('value');
  if Assigned(Item) and (Item.JSONType = jtString) and
    ((Item.AsString = 'scu$required') or (Item.AsString = 'scu$optional')) then
    Item := nil;
  if not Assigned(Item) then
  begin
    Defaults := Command.Find('default_values');
    if not Assigned(Defaults) then
      Exit(False);
    if not (Defaults is TJSONObject) then
      raise EScuError.Create('Expected a default_values object in commands.json.');
    Item := TJSONObject(Defaults).Find(Name);
  end;
  if not Assigned(Item) then
    Exit(False);
  if ParameterRequired(Entry, Positional) then
    raise EScuError.CreateFmt('Required argument %s cannot have a default value.', [Name]);
  case Item.JSONType of
    jtString: Value := Item.AsString;
    jtNumber: Value := Item.AsJSON;
    jtBoolean:
      begin
        if Field(Entry, 'type', jtString).AsString <> 'boolean' then
          raise EScuError.CreateFmt('Boolean default requires boolean type for %s.', [Name]);
        if Item.AsBoolean then
          Value := 'yes'
        else
          Value := 'no';
      end;
    else raise EScuError.CreateFmt('Expected a string, number, or Boolean default for %s.', [Name]);
  end;
  ValidateParameter(Entry, Value);
  Result := True;
end;

procedure ConvertParameters(Command, SharedAliases: TJSONObject; const Key: string;
  IsOption: Boolean);
var
  Legacy: TJSONData;
  Definitions, Aliases: TJSONArray;
  Parameter: TJSONObject;
  Index, AliasIndex: Integer;
  Name, NamedSpelling: string;
begin
  if IsOption then
    Legacy := Field(Command, Key, jtObject)
  else
    Legacy := Field(Command, Key, jtArray);
  Definitions := TJSONArray.Create;
  try
    for Index := 0 to Legacy.Count - 1 do
    begin
      Parameter := TJSONObject.Create;
      Definitions.Add(Parameter);
      if IsOption then
        Name := TJSONObject(Legacy).Names[Index]
      else
        Name := Legacy.Items[Index].AsString;
      Parameter.Add('name', Name);
      Parameter.Add('type', 'string');
      Aliases := TJSONArray.Create;
      Parameter.Add('aliases', Aliases);
      NamedSpelling := StringReplace(Name, '-', '_', [rfReplaceAll]);
      if NamedSpelling <> Name then
        Aliases.Add(NamedSpelling);
      if Assigned(SharedAliases) then
        for AliasIndex := 0 to SharedAliases.Count - 1 do
          if SameText(SharedAliases.Items[AliasIndex].AsString, NamedSpelling) then
            Aliases.Add(SharedAliases.Names[AliasIndex]);
    end;
    Command.Delete(Key);
    Command.Add(Key, Definitions);
  except
    Definitions.Free;
    raise;
  end;
end;

procedure UpgradeParameters(Entries: TJSONArray);
var
  Index: Integer;
  Entry: TJSONObject;
  Rule: string;
begin
  for Index := 0 to Entries.Count - 1 do
  begin
    Entry := DefinitionAt(Entries, Index);
    // Format 2 used value as a display label on options.
    Entry.Delete('value');
    if Assigned(Entry.Find('presence')) then
    begin
      Rule := Field(Entry, 'presence', jtString).AsString;
      if (Rule <> 'scu$required') and (Rule <> 'scu$optional') then
        raise EScuError.CreateFmt('Invalid presence rule for %s in commands.json.',
          [DefinitionName(Entry)]);
      Entry.Delete('presence');
      Entry.Add('value', Rule);
    end;
  end;
end;

procedure PrepareCommandDefinitions(Definitions: TJSONObject);
var
  LibraryOption, SharedAliases, Command: TJSONObject;
  Commands, Aliases: TJSONArray;
  Index: Integer;
begin
  case IntegerField(Definitions, 'format') of
    3: Exit;
    2:
      begin
        Commands := TJSONArray(Field(Definitions, 'commands', jtArray));
        for Index := 0 to Commands.Count - 1 do
        begin
          Command := DefinitionAt(Commands, Index);
          UpgradeParameters(TJSONArray(Field(Command, 'arguments', jtArray)));
          UpgradeParameters(TJSONArray(Field(Command, 'options', jtArray)));
        end;
      end;
    1:
      begin
        SharedAliases := nil;
        if Assigned(Definitions.Find('argument_aliases')) then
          SharedAliases := TJSONObject(Field(Definitions, 'argument_aliases', jtObject));
        Commands := TJSONArray(Field(Definitions, 'commands', jtArray));
        for Index := 0 to Commands.Count - 1 do
        begin
          Command := DefinitionAt(Commands, Index);
          ConvertParameters(Command, SharedAliases, 'arguments', False);
          ConvertParameters(Command, SharedAliases, 'options', True);
          if DefinitionName(Command) = 'help' then
          begin
            Aliases := DefinitionAliases(Command);
            if not Assigned(Aliases) then
            begin
              Aliases := TJSONArray.Create;
              Command.Add('aliases', Aliases);
            end;
            Aliases.Add('-h');
            Aliases.Add('--help');
          end;
        end;
        LibraryOption := TJSONObject.Create;
        Definitions.Add('library_option', LibraryOption);
        LibraryOption.Add('name', 'library');
        LibraryOption.Add('type', 'string');
        Aliases := TJSONArray.Create;
        LibraryOption.Add('aliases', Aliases);
        Aliases.Add('library_name');
        Aliases.Add('ln');
        LibraryOption.Add('default', 'library.json');
      end;
    else
      raise EScuError.Create('Unsupported commands.json format.');
  end;
end;

end.
