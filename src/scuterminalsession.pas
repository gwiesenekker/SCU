unit ScuTerminalSession;
{$mode objfpc}{$H+}
interface
uses ScuTerminalTypes,
  {$IFDEF WINDOWS}ScuPlatformTerminalSessionWindows{$ELSE}ScuPlatformTerminalSessionLinux{$ENDIF};
const
  TerminalSuspended = ScuTerminalTypes.TerminalSuspended;
  TerminalResumed = ScuTerminalTypes.TerminalResumed;
  TerminalResized = ScuTerminalTypes.TerminalResized;
type
  TTerminalSession = ScuTerminalTypes.TTerminalSession;
  TRawTerminalSession = TPlatformRawTerminalSession;
implementation
end.
