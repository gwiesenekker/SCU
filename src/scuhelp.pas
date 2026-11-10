unit ScuHelp;

{$mode objfpc}{$H+}

interface

uses
  ScuCommands, ScuOutput;

function ParameterSyntax(Entry: TParameterDefinition; Positional: Boolean): string;
procedure RenderCommandList(Commands: TCommandDefinitions; Output: TScuOutput; Columns: SizeInt);
procedure RenderCommandHelp(Spec: TCommandDefinition; const CatalogDirectory: string;
  Output: TScuOutput; Columns: SizeInt);

implementation

uses
  Classes, SysUtils, ScuFiles, ScuTerminal;

function AliasText(Entry: TNamedDefinition): string;
var
  AliasIndex: Integer;
begin
  Result := '';
  for AliasIndex := 0 to Entry.AliasCount - 1 do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Entry.Aliases[AliasIndex];
  end;
end;

function CommandNames(Entry: TCommandDefinition): string;
var
  Aliases: string;
begin
  Result := Entry.Name;
  Aliases := AliasText(Entry);
  if Aliases <> '' then
    Result := Result + ', ' + Aliases;
end;

function ParameterSyntax(Entry: TParameterDefinition; Positional: Boolean): string;
var
  Aliases, Value: string;
begin
  Result := Entry.Name;
  if not Positional then
    Result := '--' + Result;
  Aliases := AliasText(Entry);
  if Aliases <> '' then
    Result := Result + ' (' + Aliases + ')';
  if Entry.HasDefault then
    Value := Entry.DefaultValue
  else if Entry.Required then
    Value := 'scu$required'
  else
    Value := 'scu$optional';
  Result := Result + ' : ' + Entry.KindName + ' = ' + Value;
end;

procedure RenderCommandList(Commands: TCommandDefinitions; Output: TScuOutput; Columns: SizeInt);
const
  MinDescriptionColumns = 20;
var
  Index: Integer;
  Width, LabelColumns: SizeInt;
  LabelText, Description, Indent: string;
  Names: TStringList;
  Spec: TCommandDefinition;
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
      Spec := Commands[Index];
      Names.AddObject(Spec.Name, Spec);
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
      Spec := TCommandDefinition(Names.Objects[Index]);
      LabelText := CommandNames(Spec);
      Description := Spec.Summary;
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

procedure RenderCommandHelp(Spec: TCommandDefinition; const CatalogDirectory: string;
  Output: TScuOutput; Columns: SizeInt);
var
  Index, MemberIndex: Integer;
  Example: TCommandExample;
  Body: RawByteString;
  GroupText: string;

  procedure ShowText(const Text: string; Indentation: SizeInt = 0);
  begin
    Output.WriteLine(FormatTerminalLines(Text, Columns, Indentation));
  end;

  procedure ShowParameter(Entry: TParameterDefinition; Positional: Boolean);
  begin
    ShowText(ParameterSyntax(Entry, Positional), 2);
    if Entry.Description <> '' then
      ShowText(Entry.Description, 4);
  end;

begin
  ShowText(CommandNames(Spec));
  ShowText(Spec.Summary);
  if Spec.HasHelpFile then
  begin
    Body := ReadBytes(IncludeTrailingPathDelimiter(CatalogDirectory) + Spec.HelpFile, 1024 * 1024);
    ShowText(TrimRight(Body));
  end
  else if Spec.HasHelpText then
    ShowText(Spec.HelpText);
  ShowText('Arguments');
  if Spec.Arguments.Count = 0 then
    ShowText('None', 2);
  for Index := 0 to Spec.Arguments.Count - 1 do
    ShowParameter(Spec.Arguments[Index], True);
  ShowText('Options');
  if Spec.Options.Count = 0 then
    ShowText('None', 2);
  for Index := 0 to Spec.Options.Count - 1 do
    ShowParameter(Spec.Options[Index], False);
  if Spec.ExclusiveGroupCount > 0 then
  begin
    ShowText('Mutually exclusive options (choose at most one per group)');
    for Index := 0 to Spec.ExclusiveGroupCount - 1 do
    begin
      GroupText := '';
      for MemberIndex := 0 to Spec.ExclusiveGroupSize[Index] - 1 do
      begin
        if MemberIndex > 0 then
          GroupText := GroupText + ', ';
        GroupText := GroupText + '--' + Spec.ExclusiveOptions[Index, MemberIndex].Spelling;
      end;
      ShowText(GroupText, 2);
    end;
  end;
  if Spec.ExampleCount > 0 then
    ShowText('Examples');
  for Index := 0 to Spec.ExampleCount - 1 do
  begin
    Example := Spec.Examples[Index];
    Output.WriteLine('  ' + Example.Command);
    ShowText(Example.Description, 4);
  end;
end;

end.
