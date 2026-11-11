unit ScuBuild;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function RunBuildProcess(const Build: TBuildRequest; Interactive: Boolean; OutputLock: THandle): string;

implementation

uses
  SysUtils, BaseUnix, Process, ScuErrors, ScuOutputLock, ScuProcess, ScuSignals;

const
  BuildActiveVariable = 'SCU_BUILD_ACTIVE';

type
  TBuildProcess = class(TProcess)
  private
    FOutputLock: THandle;
    FInteractive: Boolean;
    procedure PrepareChild(Sender: TObject);
  public
    constructor Create(OutputLock: THandle; Interactive: Boolean); reintroduce;
  end;

constructor TBuildProcess.Create(OutputLock: THandle; Interactive: Boolean);
var
  Index: Integer;
begin
  inherited Create(nil);
  FOutputLock := OutputLock;
  FInteractive := Interactive;
  for Index := 1 to GetEnvironmentVariableCount do
    Environment.Add(GetEnvironmentString(Index));
  Environment.Values[BuildActiveVariable] := '1';
  if OutputLock >= 0 then
    Environment.Values[BuildOutputLockVariable] := IntToStr(OutputLock);
  OnForkEvent := @PrepareChild;
end;

procedure TBuildProcess.PrepareChild(Sender: TObject);
begin
  // Only the build child and its descendants inherit the directory descriptor.
  if (FOutputLock >= 0) and (fpFcntl(FOutputLock, F_SETFD, 0) < 0) then
    fpExit(126);
  if FInteractive then
    StartBuildProcessGroup;
end;

function RunBuildProcess(const Build: TBuildRequest; Interactive: Boolean; OutputLock: THandle): string;
var
  Child: TProcess;
  Status: Integer;
  Options: TChildProcessOptions;
begin
  Result := '';
  try
    if GetEnvironmentVariable(BuildActiveVariable) = '1' then
      raise EScuError.Create('Nested SCU builds are disabled. Use build=no in the build command.');
    Child := TBuildProcess.Create(OutputLock, Interactive);
    try
      Child.Executable := '/bin/sh';
      Child.Parameters.Add('-c');
      Child.Parameters.Add('exec </dev/null' + LineEnding + Build.Command);
      Child.Parameters.Add('scu-build');
      Child.Parameters.Add(Build.OutputPath);
      Options := [];
      if Interactive then
        Include(Options, cpOwnProcessGroup);
      Status := WaitForChild(Child, Options);
      if (PendingSignal <> 0) or (Status = 128 + SIGINT) then
        raise EScuError.Create('Build command interrupted.');
      if Status <> 0 then
        raise EScuError.CreateFmt('Build command failed with exit status %d.', [Status]);
    finally
      Child.Free;
    end;
  except
    on E: ECommandCancelled do raise;
    on E: Exception do Result := E.Message;
  end;
end;

end.
