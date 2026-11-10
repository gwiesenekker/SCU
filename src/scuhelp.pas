unit ScuHelp;

{$mode objfpc}{$H+}

interface

uses
  FPJSON, ScuOutput;

function ParameterSyntax(Entry: TJSONObject; Positional, HasDefault: Boolean;
  const DefaultValue: string): string;
procedure RenderCommandList(Commands: TJSONArray; Output: TScuOutput; Columns: SizeInt);
procedure RenderCommandHelp(Spec: TJSONObject; const CatalogDirectory: string;
  Output: TScuOutput; Columns: SizeInt);

implementation

uses
  Classes, SysUtils, ScuCommands, ScuIO, ScuJSON, ScuTerminal;

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

procedure RenderCommandList(Commands: TJSONArray; Output: TScuOutput; Columns: SizeInt);
const
  MinDescriptionColumns = 20;
var
  Index: Integer;
  Width, LabelColumns: SizeInt;
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
  Names := TStringList.Create;
  try
    Width := 0;
    for Index := 0 to Commands.Count - 1 do
    begin
      Spec := DefinitionAt(Commands, Index);
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
        Output.WriteLine(WrapTerminalText(LabelText, LineEnding, Columns));
        Output.WriteLine(Indent + WrapTerminalText(Description, LineEnding + Indent, Columns - Length(Indent)));
      end
      else
      begin
        if Columns > 0 then
          Description := WrapTerminalText(Description, LineEnding + Indent, Columns - Width);
        Output.WriteLine(LabelText + StringOfChar(' ', Width - LabelWidth(LabelText)) + Description);
      end;
    end;
  finally
    Names.Free;
  end;
end;

procedure RenderCommandHelp(Spec: TJSONObject; const CatalogDirectory: string;
  Output: TScuOutput; Columns: SizeInt);
var
  Index, MemberIndex: Integer;
  Example: TJSONObject;
  Arguments, Options, Groups, Group, Examples: TJSONArray;
  Help: TJSONData;
  Body: RawByteString;
  GroupText: string;

  procedure ShowText(const Text: string; Indentation: SizeInt = 0);
  begin
    Output.WriteLine(FormatTerminalLines(Text, Columns, Indentation));
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
  ShowText(CommandNames(Spec));
  ShowText(Field(Spec, 'summary', jtString).AsString);
  Help := Spec.Find('help_file');
  if Assigned(Help) then
  begin
    Body := ReadBytes(IncludeTrailingPathDelimiter(CatalogDirectory) + Help.AsString, 1024 * 1024);
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
      Output.WriteLine('  ' + Field(Example, 'command', jtString).AsString);
      ShowText(Field(Example, 'description', jtString).AsString, 4);
    end;
  end;
end;

end.
