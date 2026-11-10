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

implementation

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
  System.Write(Output, Bytes);
end;

procedure TTerminalOutput.Report(const Text: string);
begin
  WriteLn(StdErr, Text);
end;

procedure TTerminalOutput.Flush;
begin
  System.Flush(Output);
end;

end.
