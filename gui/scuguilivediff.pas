unit ScuGuiLiveDiff;
{$mode objfpc}{$H+}
interface
uses Classes;
const LiveDeckVersionSelector = 'scu$live_deck_version';
type
  // Inputs are immutable byte snapshots. The worker never touches LCL or SQLite.
  TGuiLiveDiff = class(TThread)
  private
    FOldSource, FNewSource, FText: RawByteString;
    FOldLabel, FNewLabel, FError: string;
    FGeneration: QWord;
  protected
    procedure Execute; override;
  public
    constructor Create(const OldSource, NewSource: RawByteString;
      const OldLabel, NewLabel: string; Generation: QWord);
    property Generation: QWord read FGeneration;
    property Text: RawByteString read FText;
    property Error: string read FError;
  end;
implementation
uses SysUtils, ScuDiff, ScuOutput;
type
  TPreviewOutput = class(TScuOutput)
  private
    FStream: TMemoryStream;
    FTruncated: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Write(const Data: RawByteString); override;
    procedure Report(const Message: string); override;
    procedure Flush; override;
    function Contents: RawByteString;
  end;
constructor TPreviewOutput.Create;
begin inherited Create; FStream := TMemoryStream.Create; end;
destructor TPreviewOutput.Destroy;
begin FStream.Free; inherited Destroy; end;
procedure TPreviewOutput.Write(const Data: RawByteString);
var Count: SizeInt;
begin
  Count := Length(Data);
  if Count > 8 * 1024 * 1024 - FStream.Size then
  begin Count := 8 * 1024 * 1024 - FStream.Size; FTruncated := True; end;
  if Count > 0 then FStream.WriteBuffer(Data[1], Count);
end;
procedure TPreviewOutput.Report(const Message: string);
begin WriteLine(Message); end;
procedure TPreviewOutput.Flush;
begin end;
function TPreviewOutput.Contents: RawByteString;
begin
  SetLength(Result, FStream.Size);
  if FStream.Size > 0 then Move(FStream.Memory^, Result[1], FStream.Size);
  if FTruncated then Result := Result + LineEnding + '[Preview truncated at 8 MiB.]';
end;
constructor TGuiLiveDiff.Create(const OldSource, NewSource: RawByteString;
  const OldLabel, NewLabel: string; Generation: QWord);
begin
  inherited Create(True); FreeOnTerminate := False;
  FOldSource := OldSource; FNewSource := NewSource;
  FOldLabel := OldLabel; FNewLabel := NewLabel; FGeneration := Generation;
  Start;
end;
procedure TGuiLiveDiff.Execute;
var Output: TPreviewOutput;
begin
  Output := TPreviewOutput.Create;
  try
    try
      WriteDeckDiff(FOldSource, FNewSource, FOldLabel, FNewLabel, Output, False, dfUnified);
      FText := Output.Contents;
      if FText = '' then FText := 'No differences.';
    except on E: Exception do FError := E.Message; end;
  finally Output.Free; end;
end;
end.
