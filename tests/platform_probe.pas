program PlatformProbe;

{$mode objfpc}{$H+}

uses SysUtils, DateUtils, ScuClock, ScuPlatformPaths, ScuLibraryPaths;

var Mode: string;
begin
  InitializePlatformPaths;
  try
    Mode := ParamStr(1);
    if Mode = 'now' then WriteLn(UtcTimestamp(UtcNow))
    else if Mode = 'fixed' then
      WriteLn(UtcTimestamp(EncodeDateTime(2026, 11, 16, 12, 34, 56, 789)))
    else if Mode = 'directory' then WriteLn(PlatformCanonicalDirectory(ParamStr(2)))
    else if Mode = 'file' then WriteLn(PlatformCanonicalFile(ParamStr(2)))
    else if Mode = 'running' then WriteLn(RunningExecutablePath)
    else if Mode = 'invocation' then WriteLn(InvocationExecutablePath)
    else if Mode = 'legacy_invocation' then WriteLn(ExpandFileName(ParamStr(0)))
    else if Mode = 'executable_name' then WriteLn(ExecutableName(ParamStr(2)))
    else if Mode = 'history' then WriteLn(HistoryStateRoot)
    else if Mode = 'preferences' then WriteLn(GuiPreferencesPath)
    else if Mode = 'same' then WriteLn(Ord(SameStoragePath(ParamStr(2), ParamStr(3))))
    else if Mode = 'storage' then WriteLn(Ord(IsLibraryStoragePath(ParamStr(2), ParamStr(3))))
    else if Mode = 'library' then WriteLn(NormalizeLibraryName(ParamStr(2)))
    else raise Exception.Create('Unknown platform probe mode: ' + Mode);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(1);
    end;
  end;
end.
