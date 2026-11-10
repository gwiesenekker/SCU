unit ScuCLI;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuCommand, ScuCommands, ScuComplete, ScuExecutor, ScuOutput;

type
  TScuCLI = class
  private
    FCatalog: TCommandCatalog;
    FPromptParameter: TParameterDefinition;
    FPromptContext: TCompletionContext;
    FLibraryPath, FCatalogDirectory: string;
    FOutput: TScuOutput;
    FExecutor: TScuExecutor;
    function Definition(const Name: string): TCommandDefinition;
    function SelectLibrary(Tokens: TStrings): Integer;
    function ParseCommand(Tokens: TStrings; CommandIndex: Integer; Spec: TCommandDefinition;
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
  SysUtils, BaseUnix, ScuBinder, ScuHelp, ScuInput, ScuErrors,
  ScuSignals, ScuTerminal, ScuTokenizer, Termio;

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
  CatalogPath := CommandFile;
  FCatalogDirectory := ExtractFileDir(CatalogPath);
  FCatalog := TCommandCatalog.Create(CatalogPath);
end;

destructor TScuCLI.Destroy;
begin
  FExecutor.Free;
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
      FCatalog.LibraryOption.Matches(Name) then
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
    else if (Copy(First, 1, 1) <> '-') and (FCatalog.Commands.FindIndex(First) < 0) then
    begin
      Name := LowerCase(ExtractFileExt(First));
      if not FileExists(First) and (Name <> '.sqlite') and
        (Name <> '.sqlite3') and (Name <> '.db') then
        Definition(First);
      FLibraryPath := First;
      Result := 1;
    end;
  end;
  if Result > 0 then
    FCatalog.LibraryOption.Validate(FLibraryPath);
  if FLibraryPath = '' then
    raise EScuError.Create('Expected a library name.');
end;

function TScuCLI.ParseCommand(Tokens: TStrings; CommandIndex: Integer; Spec: TCommandDefinition;
  Interactive: Boolean): TScuCommand;
var
  Binder: TCommandBinder;
  Index: Integer;
  Value: string;

  function CompleteParameter(Entry: TParameterDefinition; Positional: Boolean; out Argument: string): Boolean;
  var
    ParameterName, Description, Prompt, DefaultValue: string;
    Columns: SizeInt;
    HasDefault: Boolean;
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
    Prompt := FormatTerminalLines(ParameterSyntax(Entry, Positional), Columns) + LineEnding;
    Description := Entry.Description;
    if Description <> '' then
      Prompt := Prompt + FormatTerminalLines(Description, Columns) + LineEnding;
    if HasDefault then
      Prompt := Prompt + FormatTerminalLines('Press Enter to accept the default.', Columns) + LineEnding;
    Prompt := Prompt + ParameterName + '= ';
    FPromptContext := CompletionContext(Binder);
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
        Entry.Validate(Argument);
        Exit(True);
      except
        on E: EScuError do
          FOutput.Report('scu: ' + E.Message);
      end;
    until False;
  end;

begin
  Binder := TCommandBinder.Create(Spec, bmExecution);
  try
    for Index := CommandIndex + 1 to Tokens.Count - 1 do
      Binder.Feed(Tokens[Index]);
    Binder.FinishTokens;
    for Index := 0 to Binder.Count - 1 do
      if not Binder.Supplied[Index] and
        CompleteParameter(Binder.ParameterAt(Index), Index < Binder.Arguments.Count, Value) then
        Binder.Bind(Index, Value, False);
    Result := Binder.CreateCommand;
  finally
    Binder.Free;
  end;
end;

procedure TScuCLI.CompleteInteractiveLine(const Before, Prefix, After: string; Candidates: TStrings;
  out AppendCharacter: Char);
begin
  CompleteLine(FCatalog.Commands, FLibraryPath, Before, Prefix, After, Candidates, AppendCharacter, FExecutor.PendingLibrary);
end;

procedure TScuCLI.CompletePromptValue(const Before, Prefix, After: string; Candidates: TStrings;
  out AppendCharacter: Char);
begin
  AppendCharacter := #0;
  if After <> '' then
    Exit;
  CompleteValue(FCatalog.Commands, FPromptParameter, FPromptContext, FLibraryPath, Before + Prefix, Prefix,
    #0, True, Candidates, AppendCharacter, FExecutor.PendingLibrary);
end;

procedure TScuCLI.ExecuteCommand(Command: TScuCommand);
var
  Columns: SizeInt;
begin
  case Command.Name of
    'display_command_list', 'help', 'display_command':
      begin
        Columns := TerminalColumns(TextRec(Output).Handle);
        if Columns > 0 then
          UseTerminalLocale;
        if Command.Name = 'display_command' then
          RenderCommandHelp(Definition(Command['command_name']), FCatalogDirectory, FOutput, Columns)
        else
          RenderCommandList(FCatalog.Commands, FOutput, Columns);
      end;
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
  Spec: TCommandDefinition;
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
          if (FCatalog.Commands.FindIndex('display_library') < 0) or
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
            if not Assigned(Spec) or not IsSessionExit(Spec.Name) then
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
