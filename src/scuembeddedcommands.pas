unit ScuEmbeddedCommands;
{$mode objfpc}{$H+}
interface
function EmbeddedCommandsJSON: RawByteString;
implementation
uses Classes{$IFDEF MSWINDOWS}, Windows{$ENDIF};
{$R scucommands.res}
function EmbeddedCommandsJSON: RawByteString;
var Stream: TResourceStream;
begin
  Stream := TResourceStream.Create(HInstance, 'SCU_COMMANDS', RT_RCDATA);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[1], Length(Result));
  finally Stream.Free; end;
end;
end.
