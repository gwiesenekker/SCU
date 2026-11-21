unit ScuGuiProcess;
{$mode objfpc}{$H+}
interface
uses Classes, Process, ScuCommand{$IFDEF WINDOWS}, ScuPlatformProcessJobWindows{$ENDIF};
type
  TGuiOutputEvent = procedure(Sender: TObject; const Bytes: RawByteString) of object;
  TGuiFinishedEvent = procedure(Sender: TObject; ExitCode: Integer) of object;
  TGuiCommandProcess = class
  private
    FProcess: TProcess;
    {$IFDEF WINDOWS}FJob: TProcessJob;{$ENDIF}
    FOnOutput: TGuiOutputEvent;
    FOnFinished: TGuiFinishedEvent;
    function GetRunning: Boolean;
  public
    destructor Destroy; override;
    procedure Start(const Executable, LibraryPath: string; Command: TScuCommand);
    procedure Poll;
    property Running: Boolean read GetRunning;
    property OnOutput: TGuiOutputEvent read FOnOutput write FOnOutput;
    property OnFinished: TGuiFinishedEvent read FOnFinished write FOnFinished;
  end;
implementation
uses SysUtils, ScuGuiCommands{$IFDEF WINDOWS}, Windows, ScuPlatformProcessStringsWindows{$ENDIF};
function TGuiCommandProcess.GetRunning: Boolean;
begin Result := Assigned(FProcess); end;
destructor TGuiCommandProcess.Destroy;
begin
  {$IFDEF WINDOWS}
  FJob.Free; // Closing the job retires the command and its descendants.
  {$ELSE}
  if Assigned(FProcess) and FProcess.Running then FProcess.Terminate(143);
  {$ENDIF}
  FProcess.Free;
  inherited Destroy;
end;
procedure TGuiCommandProcess.Start(const Executable, LibraryPath: string; Command: TScuCommand);
begin
  if Running then raise Exception.Create('A command is already running.');
  FProcess := TProcess.Create(nil);
  try
    FProcess.Executable := Executable;
    FProcess.CurrentDirectory := ExtractFileDir(LibraryPath);
    FProcess.Parameters.Add(LibraryPath);
    CommandArguments(Command, FProcess.Parameters);
    FProcess.Options := [poUsePipes, poStderrToOutput];
    {$IFDEF WINDOWS}
    // FPC 3.2.x's Parameters quoting drops embedded JSON quotes. Reuse the
    // native argument encoder so the CLI receives the exact command values.
    FProcess.CommandLine := UTF8Encode(WindowsCommandLine(Executable, FProcess.Parameters));
    FProcess.ApplicationName := Executable;
    FJob := TProcessJob.Create;
    FProcess.Options := FProcess.Options + [poNoConsole, poRunSuspended];
    {$ENDIF}
    FProcess.Execute;
    {$IFDEF WINDOWS}
    FJob.Assign(FProcess.ProcessHandle);
    if FProcess.Resume = -1 then raise Exception.Create('Could not resume GUI command.');
    {$ENDIF}
    FProcess.CloseInput;
  except
    {$IFDEF WINDOWS}
    if Assigned(FProcess) and FProcess.Running then
    begin FProcess.Terminate(1); end;
    FreeAndNil(FJob);
    {$ENDIF}
    FreeAndNil(FProcess); raise;
  end;
end;
procedure TGuiCommandProcess.Poll;
var Buffer: array[0..16383] of Byte; Count, Budget, Code: Integer; Bytes: RawByteString;
begin
  if not Running then Exit;
  {$IFDEF WINDOWS}
  // Retire pipe-inheriting descendants once the command exits, then drain the
  // final buffered bytes. A background child must not keep the GUI busy forever.
  if Assigned(FJob) and not FProcess.Running then
    FreeAndNil(FJob); // Kill-on-close retires descendants without blocking the event loop.
  {$ENDIF}
  // Bound each tick so a noisy compiler cannot starve the window event loop.
  Budget := 256 * 1024;
  while (FProcess.Output.NumBytesAvailable > 0) and (Budget > 0) do
  begin
    Count := FProcess.Output.Read(Buffer, SizeOf(Buffer));
    if Count <= 0 then Break;
    Dec(Budget, Count);
    SetString(Bytes, PAnsiChar(@Buffer[0]), Count);
    if Assigned(FOnOutput) then FOnOutput(Self, Bytes);
  end;
  if not FProcess.Running and (FProcess.Output.NumBytesAvailable = 0) then
  begin
    Code := FProcess.ExitCode;
    {$IFDEF WINDOWS}FreeAndNil(FJob);{$ENDIF}
    FreeAndNil(FProcess);
    if Assigned(FOnFinished) then FOnFinished(Self, Code);
  end;
end;
end.
