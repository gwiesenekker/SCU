unit ScuLegacyCatalog;

{$mode objfpc}{$H+}

interface

uses
  FPJSON;

procedure PrepareCommandDefinitions(Definitions: TJSONObject);

implementation

uses
  SysUtils, ScuErrors, ScuJSON;

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
      begin
        if Legacy.Items[Index].JSONType <> jtString then
          raise EScuError.Create('Expected an argument name in commands.json.');
        Name := Legacy.Items[Index].AsString;
      end;
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
        LibraryOption.Add('default', 'library.sqlite');
      end;
    else
      raise EScuError.Create('Unsupported commands.json format.');
  end;
end;

end.
