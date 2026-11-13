unit ScuCLI;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuCommand, ScuCommandFiles, ScuCommands, ScuComplete, ScuExecutor, ScuHistory, ScuOutput;

type
  TScuCLI = class
  private
    FCatalog: TCommandCatalog;
    FHistory: TCommandHistory;
    FCompletionLibrary: TCompletionLibrary;
    FLibraryPath, FCatalogDirectory: string;
    FOutput: TScuOutput;
    FExecutor: TScuExecutor;
    FContinueOnError: Boolean;
    FInitialFile: string;
    procedure SelectBatchArguments(Tokens: TStrings; Index: Integer);
    procedure ValidateCatalog(const CatalogPath: string);
    function Definition(const Name: string): TCommandDefinition;
    function SelectLibrary(Tokens: TStrings): Integer;
    function ParseCommand(Tokens: TStrings; CommandIndex: Integer; Spec: TCommandDefinition;
      Interactive: Boolean): TScuCommand;
    procedure CompleteInteractiveLine(const Before, Prefix, After: string; Candidates: TStrings;
      out AppendCharacter: Char);
    procedure ExecuteCommand(Command: TScuCommand);
    function ParseSessionLine(const Line: string; Tokens: TStrings;
      Files: TCommandFiles; BatchLine: Boolean): TScuCommand;
    procedure RunInteractive(Tokens: TStrings);
    procedure RunInteractiveSession(Tokens: TStrings);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

implementation

uses
  SysUtils, BaseUnix, ScuBinder, ScuHelp, ScuInput, ScuErrors,
  ScuCommandRegistry, ScuLibrary, ScuSignals, ScuTerminal, ScuTokenizer, Termio;

const
  CLICommands: array[0..1] of string = ('display_command_list', 'display_command');

function IsCLICommand(const Name: string): Boolean;
var
  CommandName: string;
begin
  for CommandName in CLICommands do
    if CommandName = Name then
      Exit(True);
  Result := False;
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
var
  CatalogPath: string;
begin
  inherited Create;
  FOutput := TTerminalOutput.Create;
  FHistory := TCommandHistory.Create;
  FCompletionLibrary := TCompletionLibrary.Create;
  CatalogPath := CommandFile;
  FCatalogDirectory := ExtractFileDir(CatalogPath);
  FCatalog := TCommandCatalog.Create(CatalogPath);
  ValidateCatalog(CatalogPath);
end;

procedure TScuCLI.ValidateCatalog(const CatalogPath: string);
var
  Index: Integer;
  Name: string;
begin
  try
    for Index := 0 to FCatalog.Commands.Count - 1 do
    begin
      Name := FCatalog.Commands[Index].Name;
      if not IsCLICommand(Name) then
        CommandHandler(Name);
    end;
  except
    on E: EScuError do
      raise EScuError.CreateFmt('Could not load command catalog "%s": %s', [CatalogPath, E.Message]);
  end;
end;

destructor TScuCLI.Destroy;
begin
  FExecutor.Free;
  FHistory.Free;
  FCompletionLibrary.Free;
  FOutput.Free;
  FCatalog.Free;
  inherited Destroy;
end;

function TScuCLI.Definition(const Name: string): TCommandDefinition;
var
  Index: Integer;
begin
  Index := FCatalog.Commands.FindIndex(Name);
  if Index < 0 then
    raise EScuError.CreateFmt('Unknown command "%s". Run scu help.', [Name]);
  Result := FCatalog.Commands[Index];
end;

function TScuCLI.SelectLibrary(Tokens: TStrings): Integer;
var
  First, Name: string;
  EqualsAt: SizeInt;
begin
  FLibraryPath := FCatalog.LibraryDefault;
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
      FCatalog.LibraryArgument.Matches(Name) then
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
    else if (Copy(First, 1, 1) <> '-') and (Copy(First, 1, 1) <> '!') and
      (FCatalog.Commands.FindIndex(First) < 0) then
    begin
      Name := LowerCase(ExtractFileExt(First));
      if not FileExists(First) and (Pos(DirectorySeparator, First) = 0) and (Name <> '.sqlite') and
        (Name <> '.sqlite3') and (Name <> '.db') then
        Definition(First);
      FLibraryPath := First;
      Result := 1;
    end;
  end;
  if Result > 0 then
    FCatalog.LibraryArgument.Validate(FLibraryPath);
  if FLibraryPath = '' then
    raise EScuError.Create('Expected a library name.');
end;

procedure TScuCLI.SelectBatchArguments(Tokens: TStrings; Index: Integer);
var
  Name, Value: string;
  EqualsAt: SizeInt;
begin
  while Assigned(FCatalog.BatchArgument) and (Index < Tokens.Count) do
  begin
    Name := Tokens[Index];
    EqualsAt := Pos('=', Name);
    if EqualsAt > 0 then
      Name := Copy(Name, 1, EqualsAt - 1);
    if Copy(Name, 1, 2) = '--' then
      Delete(Name, 1, 2);
    if not FCatalog.BatchArgument.Matches(Name) then
      Exit;
    if EqualsAt > 0 then
      Value := Copy(Tokens[Index], EqualsAt + 1, MaxInt)
    else
    begin
      if Index + 1 >= Tokens.Count then
        raise EScuError.CreateFmt('Expected a value for %s: %s.',
          [FCatalog.BatchArgument.Name, FCatalog.BatchArgument.ValuesText]);
      Value := Tokens[Index + 1];
      Tokens.Delete(Index + 1);
    end;
    FCatalog.BatchArgument.Validate(Value);
    TryParseYesNo(FCatalog.BatchArgument.CanonicalValue(Value), FContinueOnError);
    Tokens.Delete(Index);
  end;
end;

type
  TPromptCompleter = class
  public
    Commands: TCommandDefinitions;
    Parameter: TParameterDefinition;
    Context: TCompletionContext;
    LibraryPath: string;
    LibraryCache: TCompletionLibrary;
    procedure Complete(const Before, Prefix, After: string; Candidates: TStrings;
      out AppendCharacter: Char);
  end;

procedure TPromptCompleter.Complete(const Before, Prefix, After: string; Candidates: TStrings;
  out AppendCharacter: Char);
begin
  AppendCharacter := #0;
  if After <> '' then
    Exit;
  CompleteValue(Commands, Parameter, Context, LibraryPath, Before + Prefix, Prefix,
    #0, True, Candidates, AppendCharacter, LibraryCache, nil);
end;

function TScuCLI.ParseCommand(Tokens: TStrings; CommandIndex: Integer; Spec: TCommandDefinition;
  Interactive: Boolean): TScuCommand;
var
  Binder: TCommandBinder;
  Index: Integer;
  Value: string;

  function CompleteParameter(Entry: TParameterDefinition; out Argument: string): Boolean;
  var
    ParameterName, Description, Prompt, DefaultValue: string;
    Columns: SizeInt;
    HasDefault: Boolean;
    Completer: TPromptCompleter;
  begin
    HasDefault := Entry.HasDefault;
    DefaultValue := Entry.DefaultValue;
    if HasDefault and (not Interactive or not Entry.PromptForDefault) then
    begin
      Argument := DefaultValue;
      Exit(True);
    end;
    if not HasDefault and not Entry.Required then
      Exit(False);

    ParameterName := Entry.Name;
    if not Interactive then
      raise EScuError.CreateFmt('Missing required argument %s for %s.', [ParameterName, Binder.Name]);
    Columns := TerminalColumns(TextRec(StdErr).Handle);
    if Columns > 0 then
      UseTerminalLocale;
    Prompt := FormatTerminalLines(ParameterSyntax(Entry), Columns) + LineEnding;
    Description := Entry.Description;
    if Description <> '' then
      Prompt := Prompt + FormatTerminalLines(Description, Columns) + LineEnding;
    if HasDefault then
      Prompt := Prompt + FormatTerminalLines('Press Enter to accept the default.', Columns) + LineEnding;
    Prompt := Prompt + ParameterName + '= ';
    Completer := TPromptCompleter.Create;
    try
      Completer.Commands := FCatalog.Commands;
      Completer.Parameter := Entry;
      Completer.Context := CompletionContext(Binder);
      Completer.LibraryPath := FLibraryPath;
      Completer.LibraryCache := FCompletionLibrary;
      repeat
        if not ReadCommandLine(Prompt, Argument, @Completer.Complete) then
          raise ECommandCancelled.Create('Command cancelled.');
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
          Entry.Validate(Argument);
          Exit(True);
        except
          on E: EScuError do
            FOutput.Report('scu: ' + E.Message);
        end;
      until False;
    finally
      Completer.Free;
    end;
  end;

begin
  Binder := TCommandBinder.Create(Spec, bmExecution);
  try
    for Index := CommandIndex + 1 to Tokens.Count - 1 do
      Binder.Feed(Tokens[Index]);
    Binder.FinishTokens;
    for Index := 0 to Binder.Count - 1 do
      if not Binder.Supplied[Index] and
        CompleteParameter(Binder.ParameterAt(Index), Value) then
        Binder.Bind(Index, Value, False);
    Result := Binder.CreateCommand;
  finally
    Binder.Free;
  end;
end;

procedure TScuCLI.CompleteInteractiveLine(const Before, Prefix, After: string; Candidates: TStrings;
  out AppendCharacter: Char);
begin
  CompleteLine(FCatalog.Commands, FLibraryPath, Before, Prefix, After, Candidates, AppendCharacter,
    FCompletionLibrary, nil);
end;

procedure TScuCLI.ExecuteCommand(Command: TScuCommand);
var
  Columns: SizeInt;
begin
  if IsCLICommand(Command.Name) then
  begin
    Columns := TerminalColumns(TextRec(Output).Handle);
    if Columns > 0 then
      UseTerminalLocale;
    if Command.Name = 'display_command' then
      RenderCommandHelp(Definition(Command['command_name']), FCatalogDirectory, FOutput, Columns)
    else
      RenderCommandList(FCatalog.Commands, FOutput, Columns);
  end
  else
    FExecutor.Execute(Command);
  // A normal return confirms completion. Only an actual cancellation exception
  // can describe the command as cancelled.
  ClearInterrupt;
end;

procedure TScuCLI.RunInteractive(Tokens: TStrings);
var
  Previous: TSessionSignalHandlers;
begin
  StartSessionSignals(Previous);
  try
    RunInteractiveSession(Tokens);
  finally
    if PendingSignal in [SIGTERM, SIGQUIT] then
      ExitCode := 128 + PendingSignal;
    RestoreSessionSignals(Previous);
  end;
end;

function TScuCLI.ParseSessionLine(const Line: string; Tokens: TStrings;
  Files: TCommandFiles; BatchLine: Boolean): TScuCommand;
var
  Spec: TCommandDefinition;
begin
  Result := nil;
  if (Line <> '') and (Line[1] = '!') then
  begin
    if not BatchLine then
      FHistory.Remember(Line);
    TokenizeCommand(Copy(Line, 2, MaxInt), Tokens);
    if Tokens.Count <> 1 then
      raise EScuError.Create('Expected one command filename after !. Quote filenames containing spaces.');
    Files.Push(Tokens[0]);
    Exit;
  end;
  Spec := nil;
  try
    TokenizeCommand(Line, Tokens);
    if Tokens.Count = 0 then
      Exit;
    Spec := Definition(Tokens[0]);
    Result := ParseCommand(Tokens, 0, Spec, not BatchLine);
  finally
    if not BatchLine and (Line <> '') and
      (not Assigned(Spec) or not IsSessionExit(Spec.Name)) then
      FHistory.Remember(Line);
  end;
end;

procedure TScuCLI.RunInteractiveSession(Tokens: TStrings);
var
  Line, Prompt, Location: string;
  OpeningLibrary, EndOfInput, SawCommand, BatchLine, HasLine: Boolean;
  Files: TCommandFiles;
  Command: TScuCommand;
  procedure StopBatch;
  begin
    if not BatchLine or FContinueOnError then
      Exit;
    Files.Clear;
    if Prompt <> '' then
      Exit;
    EndOfInput := True;
  end;

begin
  Prompt := '';
  if IsATTY(Input) = 1 then
    Prompt := 'scu> ';
  OpeningLibrary := Prompt <> '';
  EndOfInput := False;
  SawCommand := False;
  Command := nil;
  Files := TCommandFiles.Create;
  try
    if FInitialFile <> '' then
      Files.Push(FInitialFile);
    repeat
      FreeAndNil(Command);
      BatchLine := (Prompt = '') or Files.Active;
      Location := '';
      try
        if ClearInterrupt then
          raise ECommandCancelled.Create('Command cancelled.');
        if OpeningLibrary and (PendingSignal = 0) then
        begin
          OpeningLibrary := False;
          if (FCatalog.Commands.FindIndex('display_library') < 0) or
            not FileExists(FLibraryPath) then
            Continue;
          Tokens.Clear;
          Tokens.Add('display_library');
          Command := ParseCommand(Tokens, 0, Definition(Tokens[0]), True);
        end
        else
        begin
          HasLine := False;
          if PendingSignal = 0 then
          begin
            HasLine := Files.ReadLine(Line, Location);
            BatchLine := (Prompt = '') or HasLine;
            if not HasLine then
              HasLine := ReadCommandLine(Prompt, Line, @CompleteInteractiveLine, FHistory);
          end;
          if HasLine then
          begin
            Line := Trim(Line);
            if (Line <> '') and (Line[1] <> '!') then
              SawCommand := True;
            Command := ParseSessionLine(Line, Tokens, Files, BatchLine);
            if not Assigned(Command) then
              Continue;
          end
          else
          begin
            if PendingSignal = SIGINT then
              Continue;
            EndOfInput := (Prompt = '') or SessionEnding or (IsATTY(Input) <> 1);
            if EndOfInput and (PendingSignal = 0) and not SawCommand and not FileExists(FLibraryPath) then
              raise EScuError.CreateFmt('Library "%s" does not exist. Use initialize_library to create it.',
                [FLibraryPath]);
            Command := TScuCommand.CreateSessionExit;
          end;
        end;
        if Command.SessionExit then
          Exit;
        ExecuteCommand(Command);
        if Command.SessionExit then
          Exit;
      except
        on E: ECommandCancelled do
        begin
          ClearInterrupt;
          WriteDiagnostic(E.Message);
          if BatchLine then
            ExitCode := 1;
          StopBatch;
        end;
        on E: Exception do
        begin
          if Location <> '' then
            WriteDiagnostic('scu: ' + Location + ': ' + E.Message)
          else
            WriteDiagnostic('scu: ' + E.Message);
          ExitCode := 1;
          StopBatch;
        end;
      end;
      if not SessionEnding then
        Flush(Output);
    until EndOfInput;
  finally
    Files.Free;
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
    if Assigned(FCatalog.BatchArgument) and FCatalog.BatchArgument.HasDefault then
      TryParseYesNo(FCatalog.BatchArgument.DefaultValue, FContinueOnError);
    SelectBatchArguments(Tokens, 0);
    CommandIndex := SelectLibrary(Tokens);
    SelectBatchArguments(Tokens, CommandIndex);
    if (CommandIndex < Tokens.Count) and (Copy(Tokens[CommandIndex], 1, 1) = '!') then
    begin
      FInitialFile := Copy(Tokens[CommandIndex], 2, MaxInt);
      if FInitialFile = '' then
      begin
        Inc(CommandIndex);
        if CommandIndex < Tokens.Count then
          FInitialFile := Tokens[CommandIndex];
      end;
      if (FInitialFile = '') or (CommandIndex <> Tokens.Count - 1) then
        raise EScuError.Create('Expected one command filename after !.');
      Tokens.Clear;
      CommandIndex := 0;
    end;
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
