unit ScuErrors;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  EScuError = class(Exception);
  EScuSystemError = class(EScuError);
  ECommandCancelled = class(EScuError);

procedure RaiseSystemError(const Action: string; ErrorCode: Integer);

implementation

procedure RaiseSystemError(const Action: string; ErrorCode: Integer);
begin
  raise EScuSystemError.CreateFmt('%s: %s', [Action, SysErrorMessage(ErrorCode)]);
end;

end.
