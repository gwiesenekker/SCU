unit ScuReleaseMacros;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuLibrary;

type
  TReleaseMacros = class
  strict private
    FVersion: string;
    FOutput: TMemoryStream;
    FLegacyCopy: Boolean;
    procedure Append(const Data: RawByteString);
    procedure AppendSlice(const Data: RawByteString; Index, Count: SizeInt);
    procedure ExpandMacros(const Line: RawByteString; LineStart, LineEnd: SizeInt; const Stored: TDeckSource);
  public
    constructor Create(const Version: string);
    destructor Destroy; override;
    function Expand(const Source: TDeckSource): RawByteString;
    property LegacyCopy: Boolean read FLegacyCopy;
  end;

implementation

uses
  ScuErrors, ScuSignals, ScuDirectives;

type
  TMacro = (NoMacro, ModifiedDate, ModifiedTime, ModifiedDateTime, DeckVersion, LibraryVersion);
const
  MacroNames: array[ModifiedDate..LibraryVersion] of string =
    ('SCU$DATE', 'SCU$TIME', 'SCU$DATE_TIME', 'SCU$DECK_VERSION', 'SCU$VERSION');
  MaxExpansionSize = 64 * 1024 * 1024;

function MacroAt(const Line: RawByteString; Index, LineStart, LineEnd: SizeInt;
  out TokenLength: SizeInt): TMacro;
var
  Candidate: TMacro;
begin
  if (Index + 3 > LineEnd) or
    ((Index > LineStart) and IsIdentifierChar(Line[Index - 1])) then
    Exit(NoMacro);
  case Line[Index] of
    'S':
      if (Line[Index + 1] <> 'C') or (Line[Index + 2] <> 'U') or (Line[Index + 3] <> '$') then
        Exit(NoMacro);
    else Exit(NoMacro);
  end;
  for Candidate := Low(MacroNames) to High(MacroNames) do
    if HasToken(Line, Index, LineEnd, MacroNames[Candidate]) then
    begin
      TokenLength := Length(MacroNames[Candidate]);
      Exit(Candidate);
    end;
  Result := NoMacro;
end;

constructor TReleaseMacros.Create(const Version: string);
begin
  inherited Create;
  FVersion := Version;
  FOutput := TMemoryStream.Create;
end;

destructor TReleaseMacros.Destroy;
begin
  FOutput.Free;
  inherited Destroy;
end;

procedure TReleaseMacros.Append(const Data: RawByteString);
begin
  AppendSlice(Data, 1, Length(Data));
end;

procedure TReleaseMacros.AppendSlice(const Data: RawByteString; Index, Count: SizeInt);
begin
  if FOutput.Size + Count > MaxExpansionSize then
    raise EScuError.Create('Expanded deck exceeds the 64 MiB output limit.');
  if Count > 0 then
    FOutput.WriteBuffer(Data[Index], Count);
end;

procedure TReleaseMacros.ExpandMacros(const Line: RawByteString; LineStart, LineEnd: SizeInt; const Stored: TDeckSource);
var
  Index, FromIndex, TokenLength: SizeInt;
  Macro: TMacro;
begin
  Index := LineStart;
  FromIndex := Index;
  while Index <= LineEnd do
  begin
    while (Index <= LineEnd) and (Line[Index] <> 'S') do
      Inc(Index);
    if Index > LineEnd then
      Break;
    Macro := MacroAt(Line, Index, LineStart, LineEnd, TokenLength);
    if Macro = NoMacro then
    begin
      Inc(Index);
      Continue;
    end;
    AppendSlice(Line, FromIndex, Index - FromIndex);
    case Macro of
      ModifiedDate: AppendSlice(Stored.ModifiedUTC, 1, 10);
      ModifiedTime: AppendSlice(Stored.ModifiedUTC, 12, 8);
      ModifiedDateTime: Append(Stored.ModifiedUTC);
      LibraryVersion: Append(FVersion);
      DeckVersion: Append(Stored.DeckVersion);
    end;
    Inc(Index, TokenLength);
    FromIndex := Index;
  end;
  AppendSlice(Line, FromIndex, LineEnd - FromIndex + 1);
end;

function TReleaseMacros.Expand(const Source: TDeckSource): RawByteString;
var
  Index, LineStart, EndingStart, LineNo, Directive, First: SizeInt;
begin
  FOutput.Clear;
  FLegacyCopy := False;
  Index := 1;
  LineNo := 0;
  while Index <= Length(Source.Bytes) do
  begin
    if (LineNo and 255) = 0 then CheckSessionInterrupt;
    Inc(LineNo);
    LineStart := Index;
    ReadSourceLine(Source.Bytes, Index, EndingStart);
    Directive := DirectiveStart(Source.Bytes, Source.CommentPrefix, LineStart, EndingStart - 1, First);
    if (Directive <> 0) and (HasToken(Source.Bytes, Directive, EndingStart - 1, 'SCU_COPY') or
      HasToken(Source.Bytes, Directive, EndingStart - 1, 'SCU$COPY')) then FLegacyCopy := True;
    ExpandMacros(Source.Bytes, LineStart, EndingStart - 1, Source);
    AppendSlice(Source.Bytes, EndingStart, Index - EndingStart);
  end;
  SetLength(Result, FOutput.Size);
  if Result <> '' then Move(FOutput.Memory^, Result[1], Length(Result));
end;

end.
