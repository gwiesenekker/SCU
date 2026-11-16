unit ScuGuiProcess;
{$mode objfpc}{$H+}
interface
uses Classes, Process, ScuCommand;
type
  TGuiOutputEvent = procedure(Sender: TObject; const Bytes: RawByteString) of object;
  TGuiFinishedEvent = procedure(Sender: TObject; ExitCode: Integer) of object;
  TGuiCommandProcess = class
  private
    FProcess: TProcess;
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
uses SysUtils, ScuGuiCommands;
function TGuiCommandProcess.GetRunning: Boolean;
begin Result := Assigned(FProcess); end;
destructor TGuiCommandProcess.Destroy;
begin
  if Assigned(FProcess) then
  begin
    // Normal close is refused while busy; this is only exceptional shutdown.
    if FProcess.Running then FProcess.Terminate(143);
    FProcess.Free;
  end;
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
    FProcess.Execute;
    FProcess.CloseInput;
  except FreeAndNil(FProcess); raise; end;
end;
procedure TGuiCommandProcess.Poll;
var Buffer: array[0..16383] of Byte; Count, Budget, Code: Integer; Bytes: RawByteString;
begin
  if not Running then Exit;
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
    Code := FProcess.ExitStatus;
    FreeAndNil(FProcess);
    if Assigned(FOnFinished) then FOnFinished(Self, Code);
  end;
end;
end.
