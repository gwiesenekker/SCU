program GuiProcessProbe;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} Classes, SysUtils, Process, ScuCommand,
  ScuGuiProcess, ScuGuiPlatform, ScuPlatformPaths{$IFDEF WINDOWS}, Windows{$ENDIF};
type TCapture = class
  Bytes: RawByteString;
  Finished, Code: Integer;
  procedure Output(Sender: TObject; const Data: RawByteString);
  procedure Done(Sender: TObject; ExitCode: Integer);
end;
procedure TCapture.Output(Sender: TObject; const Data: RawByteString);
begin Bytes := Bytes + Data; end;
procedure TCapture.Done(Sender: TObject; ExitCode: Integer);
begin Inc(Finished); Code := ExitCode; end;
var Args: TStringList; Child: TGuiCommandProcess; Capture: TCapture; Command: TScuCommand;
  Parameters: TScuArguments; Data: RawByteString; Deadline: QWord;
  Worker: TProcess; FileStream: TFileStream;
procedure Wait;
begin
  Deadline := GetTickCount64 + 20000;
  while Child.Running do
  begin
    Child.Poll;
    if GetTickCount64 > Deadline then raise Exception.Create('GUI process probe timeout');
    Sleep(1);
  end;
end;
begin
  InitializePlatformPaths;
  Args := TStringList.Create;
  try
    ReadInvocationArguments(Args);
    if Args[0] = 'child' then
    begin
      if Args[1] = 'marker' then
      begin
        Sleep(1500); FileStream := TFileStream.Create(Copy(Args[2], 6, MaxInt), fmCreate);
        FileStream.Free; Halt(0);
      end;
      if Args[1] = 'hold' then
      begin
        Worker := TProcess.Create(nil);
        Worker.Executable := RunningExecutablePath;
        Worker.Parameters.Add('child'); Worker.Parameters.Add('marker'); Worker.Parameters.Add(Args[2]);
        {$IFDEF WINDOWS}Worker.Options := [poNoConsole];{$ENDIF}
        Worker.Execute; Worker.Free;
        WriteLn('ready'); Flush(Output); Sleep(15000); Halt(0);
      end;
      {$IFDEF WINDOWS}
      if GetConsoleWindow <> 0 then begin WriteLn(StdErr, 'Unexpected child console'); Halt(9); end;
      {$ENDIF}
      if Args[1] = 'exit7' then Halt(7);
      WriteLn(Args[2]);
      Data := StringOfChar('X', 512 * 1024); Write(Data); Flush(Output);
      WriteLn(StdErr, 'END 日本'); Halt(0);
    end;
    if Args[0] = 'font' then begin WriteLn(DefaultGuiFont); Halt(0); end;
    if Args[0] = 'directory' then begin EnsureGuiPreferencesDirectory(Args[1]); Halt(0); end;
    Capture := TCapture.Create; Child := TGuiCommandProcess.Create;
    SetLength(Parameters, 1); Parameters[0].Name := 'text';
    Parameters[0].Value := Args[1]; Parameters[0].Provided := True;
    Command := TScuCommand.Create('emit', Parameters);
    try
      Child.OnOutput := @Capture.Output; Child.OnFinished := @Capture.Done;
      if Args[0] = 'failed-start' then
      begin
        try Child.Start(RunningExecutablePath + '.missing', 'child', Command);
        except on E: Exception do WriteLn('rejected'); end;
        if Child.Running then raise Exception.Create('Failed start left a busy process');
      end;
      if Args[0] = 'abort' then
      begin
        Command.Free; Command := TScuCommand.Create('hold', Parameters);
        Child.Start(RunningExecutablePath, 'child', Command);
        Deadline := GetTickCount64 + 10000;
        repeat
          Child.Poll; Sleep(1);
          if GetTickCount64 > Deadline then raise Exception.Create('No child ready marker');
        until Pos('ready', Capture.Bytes) > 0;
        FreeAndNil(Child); Sleep(2000); WriteLn('aborted');
      end
      else
      begin
        if Args[0] = 'backend-build' then
        begin
          Command.Free; Command := nil; SetLength(Parameters, 2);
          Parameters[0].Name := 'deck_name'; Parameters[0].Value := 'main.c'; Parameters[0].Provided := True;
          Parameters[1].Name := 'build'; Parameters[1].Value := 'yes'; Parameters[1].Provided := True;
          Command := TScuCommand.Create('extract_deck', Parameters);
          Child.Start(Args[2], Args[1], Command);
        end
        else Child.Start(RunningExecutablePath, 'child', Command);
        Wait;
        if (Capture.Finished <> 1) or (Capture.Code <> 0) then raise Exception.Create('Invalid completion');
        Write(Capture.Bytes);
        if Args[0] <> 'backend-build' then
        begin
          Command.Free; Command := TScuCommand.Create('exit7', nil);
          Child.Start(RunningExecutablePath, 'child', Command); Wait;
          if (Capture.Finished <> 2) or (Capture.Code <> {$IFDEF WINDOWS}7{$ELSE}(7 shl 8){$ENDIF}) then raise Exception.Create('Exit code not forwarded');
        end;
      end;
    finally Command.Free; Child.Free; Capture.Free; end;
  finally Args.Free; end;
end.
