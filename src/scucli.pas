unit ScuCLI;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, ScuCommand, ScuComplete, ScuExecutor, ScuOutput;

type
  TScuCLI = class
  private
    FDefinitions: TJSONObject;
    FCommands: TJSONArray;
    FLibraryOption, FPromptParameter: TJSONObject;
    FPromptContext: TCompletionContext;
    FLibraryPath: string;
    FOutput: TScuOutput;
    FExecutor: TScuExecutor;
    function Definition(const Name: string): TJSONObject;
    procedure DisplayCommandList;
    procedure DisplayCommand(const Name: string);
    function SelectLibrary(Tokens: TStrings): Integer;
    function ParseCommand(Tokens: TStrings; CommandIndex: Integer; Spec: TJSONObject;
      Interactive: Boolean): TScuCommand;
    procedure CompleteInteractiveLine(const Before, Prefix, After: string; Candidates: TStrings;
      out AppendCharacter: Char);
    procedure CompletePromptValue(const Before, Prefix, After: string; Candidates: TStrings;
      out AppendCharacter: Char);
    procedure ExecuteCommand(Command: TScuCommand);
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
  SysUtils, BaseUnix, ScuIO, ScuJSON, ScuCommands, ScuInput, ScuTerminal, ScuSignals, Termio;

type
  TTerminalOutput = class(TScuOutput)
  public
    procedure Write(const Data: RawByteString); override;
    procedure Report(const Text: string); override;
    procedure Flush; override;
  end;

procedure TTerminalOutput.Write(const Data: RawByteString);
var
  Bytes: RawByteString;
begin
  Bytes := Data;
  SetCodePage(Bytes, TextRec(Output).CodePage, False);
  System.Write(Output, Bytes);
end;

procedure TTerminalOutput.Report(const Text: string);
begin
  WriteLn(StdErr, Text);
end;

procedure TTerminalOutput.Flush;
begin
  System.Flush(Output);
end;

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
  FOutput := TTerminalOutput.Create;
  FDefinitions := ParseObject(ReadBytes(CommandFile, 1024 * 1024));
  PrepareCommandDefinitions(FDefinitions);
  FCommands := TJSONArray(Field(FDefinitions, 'commands', jtArray));
  FLibraryOption := TJSONObject(Field(FDefinitions, 'library_option', jtObject));
end;

destructor TScuCLI.Destroy;
begin
  FExecutor.Free;
  FOutput.Free;
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

function TScuCLI.SelectLibrary(Tokens: TStrings): Integer;
var
  First, Name: string;
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
      if EqualsAt > 0 then
        FLibraryPath := Copy(First, EqualsAt + 1, MaxInt)
      else
      begin
        if Tokens.Count < 2 then
          raise EScuError.CreateFmt('Expected a library name for %s.', [First]);
        FLibraryPath := Tokens[1];
        Result := 2;
      end;
      if FLibraryPath = '' then
        raise EScuError.CreateFmt('Expected a library name for %s.', [First]);
    end
    else if (Copy(First, 1, 1) <> '-') and (FindDefinition(FCommands, First) < 0) then
    begin
      Name := LowerCase(ExtractFileExt(First));
      if not FileExists(First) and (Name <> '.sqlite') and
        (Name <> '.sqlite3') and (Name <> '.db') then
        Definition(First);
      FLibraryPath := First;
      Result := 1;
    end;
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

function TScuCLI.ParseCommand(Tokens: TStrings; CommandIndex: Integer; Spec: TJSONObject;
  Interactive: Boolean): TScuCommand;
var
  Index, Expected, Slot, OptionSlot, EqualsAt: Integer;
  Value, Key, Name: string;
  Arguments, Options: TJSONArray;
  PositionalOnly: Boolean;
  BoundArguments: TScuArguments;
  BoundOptions: TStringList;

  procedure SetArgument(Position: Integer; const Argument: string; Provided: Boolean = True);
  begin
    if BoundArguments[Position].Provided then
      raise EScuError.CreateFmt('Duplicate argument %s.', [BoundArguments[Position].Name]);
    ValidateParameter(DefinitionAt(Arguments, Position), Argument);
    BoundArguments[Position].Value := Argument;
    BoundArguments[Position].Provided := Provided;
  end;

  procedure SetOption(Position: Integer; const Argument: string);
  var
    Entry: TJSONObject;
    Name: string;
  begin
    Entry := DefinitionAt(Options, Position);
    Name := DefinitionName(Entry);
    if BoundOptions.IndexOfName(Name) >= 0 then
      raise EScuError.CreateFmt('Duplicate option --%s.', [Name]);
    ValidateParameter(Entry, Argument);
    BoundOptions.Add(Name + '=' + Argument);
  end;

  function CompleteParameter(Entry: TJSONObject; Positional: Boolean; out Argument: string): Boolean;
  var
    ParameterName, Description, Prompt, DefaultValue: string;
    Columns: SizeInt;
    HasDefault: Boolean;
    Binding: TScuArgument;
  begin
    HasDefault := ParameterDefault(Spec, Entry, Positional, DefaultValue);
    if HasDefault and (not Interactive or not Entry.Get('prompt_for_default', True)) then
    begin
      Argument := DefaultValue;
      Exit(True);
    end;
    if not HasDefault and not ParameterRequired(Entry, Positional) then
      Exit(False);

    ParameterName := DefinitionName(Entry);
    if not Interactive then
      raise EScuError.CreateFmt('Missing required argument %s for %s.', [ParameterName, Name]);
    Columns := TerminalColumns(TextRec(StdErr).Handle);
    if Columns > 0 then
      UseTerminalLocale;
    Prompt := FormatTerminalLines(ParameterSyntax(Entry, Positional, HasDefault, DefaultValue), Columns) + LineEnding;
    Description := ParameterDescription(Entry);
    if Description <> '' then
      Prompt := Prompt + FormatTerminalLines(Description, Columns) + LineEnding;
    if HasDefault then
      Prompt := Prompt + FormatTerminalLines('Press Enter to accept the default.', Columns) + LineEnding;
    Prompt := Prompt + ParameterName + '= ';
    FPromptContext := Default(TCompletionContext);
    FPromptContext.Version := BoundOptions.Values['version'];
    FPromptContext.Revision := BoundOptions.Values['revision'];
    for Binding in BoundArguments do
      RecordCompletionValue(FPromptContext, Binding.Name, Binding.Value);
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
  Index := CommandIndex + 1;
  Name := DefinitionName(Spec);
  Arguments := TJSONArray(Field(Spec, 'arguments', jtArray));
  Options := TJSONArray(Field(Spec, 'options', jtArray));
  Expected := Arguments.Count;
  SetLength(BoundArguments, Expected);
  for Slot := 0 to Expected - 1 do
    BoundArguments[Slot].Name := DefinitionName(DefinitionAt(Arguments, Slot));

  BoundOptions := TStringList.Create;
  try
    BoundOptions.CaseSensitive := True;
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
          raise EScuError.CreateFmt('Unknown option %s for %s.', [Value, Name]);
        if EqualsAt > 0 then
          SetOption(OptionSlot, Copy(Value, EqualsAt + 1, MaxInt))
        else if ParameterRequired(DefinitionAt(Options, OptionSlot), False) and not ValueFollows then
        begin
          Key := DefinitionName(DefinitionAt(Options, OptionSlot));
          if BoundOptions.IndexOfName(Key) >= 0 then
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
            raise EScuError.CreateFmt('Ambiguous argument or option "%s" for %s.', [Key, Name]);
          if (Slot >= 0) or (OptionSlot >= 0) then
          begin
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
        while (Slot < Expected) and BoundArguments[Slot].Provided do
          Inc(Slot);
        if Slot = Expected then
          raise EScuError.CreateFmt('Too many arguments for %s. Run scu help.', [Name]);
        SetArgument(Slot, Value);
      end;
      Inc(Index);
    end;

    for Slot := 0 to Expected - 1 do
      if not BoundArguments[Slot].Provided and CompleteParameter(DefinitionAt(Arguments, Slot), True, Value) then
        SetArgument(Slot, Value, False);
    for OptionSlot := 0 to Options.Count - 1 do
    begin
      Key := DefinitionName(DefinitionAt(Options, OptionSlot));
      if (BoundOptions.IndexOfName(Key) < 0) and
        CompleteParameter(DefinitionAt(Options, OptionSlot), False, Value) then
        SetOption(OptionSlot, Value);
    end;
    Result := TScuCommand.Create(Name, BoundArguments, BoundOptions);
  finally
    BoundOptions.Free;
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

procedure TScuCLI.CompleteInteractiveLine(const Before, Prefix, After: string; Candidates: TStrings;
  out AppendCharacter: Char);
begin
  CompleteLine(FCommands, FLibraryPath, Before, Prefix, After, Candidates, AppendCharacter, FExecutor.PendingLibrary);
end;

procedure TScuCLI.CompletePromptValue(const Before, Prefix, After: string; Candidates: TStrings;
  out AppendCharacter: Char);
begin
  AppendCharacter := #0;
  if After <> '' then
    Exit;
  CompleteValue(FCommands, FPromptParameter, FPromptContext, FLibraryPath, Before + Prefix, Prefix,
    #0, True, Candidates, AppendCharacter, FExecutor.PendingLibrary);
end;

procedure TScuCLI.ExecuteCommand(Command: TScuCommand);
begin
  case Command.Name of
    'display_command_list', 'help': DisplayCommandList;
    'display_command': DisplayCommand(Command.Arguments[0].Value);
    else FExecutor.Execute(Command);
  end;
end;

procedure TScuCLI.RunInteractive(Tokens: TStrings);
var
  Previous: TSessionSignalHandlers;
begin
  StartSessionSignals(Previous);
  try
    RunInteractiveSession(Tokens);
  finally
    if SessionSignal in [SIGTERM, SIGQUIT] then
      ExitCode := 128 + SessionSignal;
    RestoreSessionSignals(Previous);
  end;
end;

procedure TScuCLI.RecoverPendingLibrary;
var
  Path: string;
begin
  try
    Path := FExecutor.RecoverPendingLibrary;
    if Path <> '' then
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
  Command: TScuCommand;
  Spec: TJSONObject;
begin
  Prompt := '';
  if IsATTY(Input) = 1 then
    Prompt := 'scu> ';
  OpeningLibrary := Prompt <> '';
  EndOfInput := False;
  SawCommand := False;
  Command := nil;
  try
    repeat
      FreeAndNil(Command);
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
          Command := ParseCommand(Tokens, 0, Definition(Tokens[0]), True);
        end
        else if (SessionSignal = 0) and ReadCommandLine(Prompt, Line, @CompleteInteractiveLine) then
        begin
          Spec := nil;
          try
            TokenizeCommand(Line, Tokens);
            if Tokens.Count = 0 then
              Continue;
            SawCommand := True;
            Spec := Definition(Tokens[0]);
            Command := ParseCommand(Tokens, 0, Spec, Prompt <> '');
          finally
            if not Assigned(Spec) or not IsSessionExit(DefinitionName(Spec)) then
              RememberCommand(Line);
          end;
        end
        else
        begin
          if SessionSignal = SIGINT then
            Continue;
          EndOfInput := (Prompt = '') or SessionEnding or (IsATTY(Input) <> 1);
          if EndOfInput and (SessionSignal = 0) and not SawCommand and not FileExists(FLibraryPath) then
            raise EScuError.CreateFmt('Library "%s" does not exist. Use initialize_library to create it.',
              [FLibraryPath]);
          Command := TScuCommand.CreateSessionExit;
        end;
        if Command.SessionExit and not Assigned(FExecutor.PendingLibrary) then
          Exit;
        ExecuteCommand(Command);
        if Command.SessionExit then
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
          if EndOfInput and SessionEnding then
            RecoverPendingLibrary;
          ExitCode := 1;
        end;
      end;
      if not SessionEnding then
        Flush(Output);
    until EndOfInput;
  finally
    Command.Free;
  end;
end;

procedure TScuCLI.Run;
var
  Tokens: TStringList;
  Index, CommandIndex: Integer;
  Command: TScuCommand;
begin
  Tokens := TStringList.Create;
  try
    for Index := 1 to ParamCount do
      Tokens.Add(ParamStr(Index));
    CommandIndex := SelectLibrary(Tokens);
    FExecutor := TScuExecutor.Create(FLibraryPath, CommandIndex = Tokens.Count, FOutput);
    if CommandIndex = Tokens.Count then
      RunInteractive(Tokens)
    else
    begin
      Command := ParseCommand(Tokens, CommandIndex, Definition(Tokens[CommandIndex]), False);
      try
        ExecuteCommand(Command);
      finally
        Command.Free;
      end;
    end;
  finally
    Tokens.Free;
  end;
end;

end.
