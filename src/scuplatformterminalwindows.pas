unit ScuPlatformTerminalWindows;
{$mode objfpc}{$H+}
interface
procedure UseTerminalLocale;
procedure TerminalSize(Handle: THandle; out Columns, Rows: Integer);
function ScalarWidth(Code: Cardinal): Integer;
function IsTerminalInput: Boolean;
implementation
uses Windows, SysUtils, ScuPlatformTerminalWidthWindows;
procedure UseTerminalLocale;
begin
  SetMultiByteConversionCodePage(CP_UTF8);
  SetTextCodePage(Input, CP_UTF8); SetTextCodePage(Output, CP_UTF8); SetTextCodePage(StdErr, CP_UTF8);
end;
procedure TerminalSize(Handle: THandle; out Columns, Rows: Integer);
var Info: TConsoleScreenBufferInfo;
begin
  Columns := 0; Rows := 0;
  if GetConsoleScreenBufferInfo(Handle, Info) then
  begin Columns := Info.srWindow.Right - Info.srWindow.Left + 1; Rows := Info.srWindow.Bottom - Info.srWindow.Top + 1; end;
end;
function ScalarWidth(Code: Cardinal): Integer;
begin Result := UnicodeCellWidth(Code); end;
function IsTerminalInput: Boolean;
var Mode: DWORD;
begin Result := GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), Mode); end;
end.
