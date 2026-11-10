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

implementation

procedure TScuOutput.WriteLine(const Text: string);
begin
  Write(Text + LineEnding);
end;

end.
