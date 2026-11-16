unit ScuPlatformTerminalKeysWindows;
{$mode objfpc}{$H+}
interface
uses Windows;
type
  TConsoleKeyEncoder = class
  private FHighSurrogate: WideChar;
  public
    function Encode(const Key: TKeyEventRecord): string;
  end;
implementation
uses SysUtils;
function TConsoleKeyEncoder.Encode(const Key: TKeyEventRecord): string;
var Code: Cardinal; Text: UnicodeString; Index, Count: Integer; Piece: string; Control, Alt, AltGr: Boolean;
begin
  Result := ''; if not Key.bKeyDown then Exit;
  Control := (Key.dwControlKeyState and (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0;
  Alt := (Key.dwControlKeyState and (LEFT_ALT_PRESSED or RIGHT_ALT_PRESSED)) <> 0;
  AltGr := (Key.dwControlKeyState and (RIGHT_ALT_PRESSED or LEFT_CTRL_PRESSED)) = (RIGHT_ALT_PRESSED or LEFT_CTRL_PRESSED);
  Piece := '';
  case Key.wVirtualKeyCode of
    VK_BACK: Piece := #127; VK_RETURN: Piece := #13; VK_TAB: Piece := #9; VK_ESCAPE: Piece := #27;
    VK_LEFT: if Control then Piece := #27'b' else Piece := #27'[D';
    VK_RIGHT: if Control then Piece := #27'f' else Piece := #27'[C';
    VK_UP: Piece := #27'[A'; VK_DOWN: Piece := #27'[B';
    VK_HOME: Piece := #27'[H'; VK_END: Piece := #27'[F';
    VK_DELETE: Piece := #27'[3~';
  end;
  Code := Ord(Key.UnicodeChar);
  if Piece = '' then
  begin
    if (Code >= $D800) and (Code <= $DBFF) then begin FHighSurrogate := Key.UnicodeChar; Exit; end;
    if (Code >= $DC00) and (Code <= $DFFF) and (FHighSurrogate <> #0) then
      Text := UnicodeString(FHighSurrogate) + Key.UnicodeChar
    else if (Code >= $DC00) and (Code <= $DFFF) then Text := WideChar($FFFD)
    else if Code <> 0 then Text := UnicodeString(Key.UnicodeChar)
    else if Control and not AltGr and (Key.wVirtualKeyCode >= Ord('A')) and (Key.wVirtualKeyCode <= Ord('Z')) then
      Text := WideChar(Key.wVirtualKeyCode - Ord('A') + 1)
    else Text := '';
    if (Code = 0) and (Text = '') then Exit;
    Piece := UTF8Encode(Text);
    if Alt and not AltGr and (Piece <> '') then Piece := #27 + Piece;
  end;
  if (FHighSurrogate <> #0) and not ((Code >= $DC00) and (Code <= $DFFF)) then Result := UTF8Encode(UnicodeString(WideChar($FFFD)));
  FHighSurrogate := #0;
  Count := Key.wRepeatCount; if Count = 0 then Count := 1;
  for Index := 1 to Count do Result := Result + Piece;
end;
end.
