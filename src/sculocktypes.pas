unit ScuLockTypes;

{$mode objfpc}{$H+}

interface

const
  BuildOutputLockVariable = 'SCU_BUILD_OUTPUT_LOCK_FD';
  WindowsOutputLockName = '.scu-output.lock';

type
  TStopLockWait = function: Boolean;
  TCheckLockInterrupt = procedure;

function IsPlatformOutputLockName(const Name: string): Boolean;

implementation

uses SysUtils;

function IsPlatformOutputLockName(const Name: string): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := SameText(Name, WindowsOutputLockName);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

end.
