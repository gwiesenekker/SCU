unit ScuTerminalTypes;
{$mode objfpc}{$H+}
interface
const
  TerminalSuspended = -2;
  TerminalResumed = -3;
  TerminalResized = -4;
type
  TTerminalSession = class abstract
  protected
    function GetReady: Boolean; virtual; abstract;
    function GetRawMode: Boolean; virtual; abstract;
  public
    function ReadInput(var Buffer; Size: SizeUInt; Timeout: Integer): SizeInt; virtual; abstract;
    procedure Suspend; virtual; abstract;
    procedure ResumeEditing; virtual; abstract;
    procedure FinishLine; virtual; abstract;
    procedure GetSize(out Columns, Rows: Integer); virtual;
    property Ready: Boolean read GetReady;
    property RawMode: Boolean read GetRawMode;
  end;
implementation
uses ScuTerminal;
procedure TTerminalSession.GetSize(out Columns, Rows: Integer);
begin TerminalSize(StdErrorHandle, Columns, Rows); end;
end.
