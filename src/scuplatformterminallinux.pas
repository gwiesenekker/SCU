unit ScuPlatformTerminalLinux;
{$mode objfpc}{$H+}
interface
procedure UseTerminalLocale;
procedure TerminalSize(Handle: THandle; out Columns, Rows: Integer);
function ScalarWidth(Code: Cardinal): Integer;
function IsTerminalInput: Boolean;
implementation
uses BaseUnix, Termio;
const
  LC_CTYPE = 0;

function setlocale(Category: cint; Locale: PChar): PChar; cdecl; external 'c';
function wcwidth(Character: cuint): cint; cdecl; external 'c';

procedure UseTerminalLocale;
begin
  setlocale(LC_CTYPE, '');
  if wcwidth($754C) < 0 then
    setlocale(LC_CTYPE, 'C.UTF-8');
end;

procedure TerminalSize(Handle: THandle; out Columns, Rows: Integer);
var
  Window: TWinSize;
begin
  Columns := 0;
  Rows := 0;
  if fpIoCtl(Handle, TIOCGWINSZ, @Window) = 0 then
  begin
    Columns := Window.ws_col;
    Rows := Window.ws_row;
  end;
end;

function ScalarWidth(Code: Cardinal): Integer;
begin Result := wcwidth(Code); end;
function IsTerminalInput: Boolean;
begin Result := IsATTY(Input) = 1; end;
end.
