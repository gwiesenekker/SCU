unit ScuOutput;

{$mode objfpc}{$H+}

interface

type
  TScuOutput = class abstract
  public
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
  SysUtils, BaseUnix, ScuErrors;

procedure WriteDiagnostic(const Message: string);
begin
  {$push}{$I-}
  WriteLn(StdErr, Message);
  if IOResult = 0 then
  begin
    Flush(StdErr);
    IOResult;
  end;
  {$pop}
end;

procedure TScuOutput.WriteLine(const Text: string);
begin
  Write(Text + LineEnding);
end;

procedure TTerminalOutput.Write(const Data: RawByteString);
var
  Bytes: RawByteString;
begin
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
end;

procedure TTerminalOutput.Report(const Text: string);
begin
  WriteLn(StdErr, Text);
end;

procedure TTerminalOutput.Flush;
begin
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
end;

end.
