unit ScuOutput;

{$mode objfpc}{$H+}

interface

type
  TScuOutput = class abstract
  protected
    function GetColumns: SizeInt; virtual;
  public
    property Columns: SizeInt read GetColumns;
    procedure Write(const Data: RawByteString); virtual; abstract;
    procedure WriteLine(const Text: string);
    procedure Report(const Text: string); virtual; abstract;
    procedure Flush; virtual; abstract;
  end;

  TTerminalOutput = class(TScuOutput)
  public
    procedure Write(const Data: RawByteString); override;
    procedure Report(const Text: string); override;
    procedure Flush; override;
  end;

procedure WriteDiagnostic(const Message: string);

implementation

uses
  SysUtils, {$IFDEF LINUX}BaseUnix,{$ELSE}ScuPlatformOutputWindows,{$ENDIF} ScuErrors, ScuTerminal;

function TScuOutput.GetColumns: SizeInt;
begin
  Result := TerminalColumns(StdOutputHandle);
end;

procedure WriteDiagnostic(const Message: string);
begin
  {$IFDEF WINDOWS}
  try WriteWindowsOutput(StdErrorHandle, Message + #10);
  except on E: EScuError do ; end;
  {$ELSE}
  {$push}{$I-}
  WriteLn(StdErr, Message);
  if IOResult = 0 then
  begin
    Flush(StdErr);
    IOResult;
  end;
  {$pop}
  {$ENDIF}
end;

procedure TScuOutput.WriteLine(const Text: string);
begin
  Write(Text + {$IFDEF WINDOWS}#10{$ELSE}LineEnding{$ENDIF});
end;

procedure TTerminalOutput.Write(const Data: RawByteString);
var
  Bytes: RawByteString;
begin
  {$IFDEF WINDOWS}
  WriteWindowsOutput(StdOutputHandle, Data);
  {$ELSE}
  Bytes := Data;
  SetCodePage(Bytes, TextRec(Output).CodePage, False);
  try
    System.Write(Output, Bytes);
  except
    on E: EInOutError do
    begin
      if fpGetErrNo = ESysEPIPE then
        RaiseSystemError('Could not write command output', ESysEPIPE);
      raise;
    end;
  end;
  {$ENDIF}
end;

procedure TTerminalOutput.Report(const Text: string);
begin
  {$IFDEF WINDOWS}WriteWindowsOutput(StdErrorHandle, Text + #10);{$ELSE}
  WriteLn(StdErr, Text);{$ENDIF}
end;

procedure TTerminalOutput.Flush;
begin
  {$IFDEF LINUX}
  try
    System.Flush(Output);
  except
    on E: EInOutError do
    begin
      if fpGetErrNo = ESysEPIPE then
        RaiseSystemError('Could not write command output', ESysEPIPE);
      raise;
    end;
  end;
  {$ENDIF}
end;

end.
