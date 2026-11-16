unit ScuPlatformLockInterruptWindows;
{$mode objfpc}{$H+}
interface
type
  TLockInterruptScope = class
  private FActive: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Check;
    function Consume: Boolean;
  end;
implementation
uses ScuPlatformSignalsWindows, ScuErrors;
constructor TLockInterruptScope.Create;
begin inherited Create; AcquireSignalWait; FActive := True; end;
procedure TLockInterruptScope.Check;
begin
  CheckSessionInterrupt;
  if SessionEnding then raise ECommandCancelled.Create('Command cancelled.');
end;
function TLockInterruptScope.Consume: Boolean;
begin
  Result := ClearInterrupt;
  if SessionEnding then raise ECommandCancelled.Create('Command cancelled.');
end;
destructor TLockInterruptScope.Destroy;
begin if FActive then ReleaseSignalWait; inherited Destroy; end;
end.
