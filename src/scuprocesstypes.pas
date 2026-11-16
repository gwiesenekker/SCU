unit ScuProcessTypes;
{$mode objfpc}{$H+}
interface
uses Classes, ScuLockTypes;
type
  TChildProcessOptions = set of (cpOwnProcessGroup, cpHandlesInterrupt);
  TChildProcessRequest = class
  private
    FArguments, FEnvironment: TStringList;
  public
    Executable, WorkingDirectory, ShellCommand: string;
    NullInput: Boolean;
    OutputLock: THandle;
    CheckInterrupt: TCheckLockInterrupt;
    constructor Create;
    destructor Destroy; override;
    property Arguments: TStringList read FArguments;
    // Overrides merged with the native parent environment on Windows.
    property Environment: TStringList read FEnvironment;
  end;
implementation
constructor TChildProcessRequest.Create;
begin
  inherited Create;
  FArguments := TStringList.Create;
  FEnvironment := TStringList.Create;
  OutputLock := THandle(-1);
end;
destructor TChildProcessRequest.Destroy;
begin
  FArguments.Free;
  FEnvironment.Free;
  inherited Destroy;
end;
end.
