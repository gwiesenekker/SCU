unit ScuExpand;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuLibrary, ScuSQLite;

type
  TDeckExpander = class
  private
    FLibrary: TDeckLibrary;
    FDatabase: TSQLiteLibrary;
    FRevision, FRootRevision: Integer;
    FVersion, FExpansionUTC, FRootDeckVersion: string;
    FOutput: TMemoryStream;
    procedure Append(const Data: RawByteString);
    procedure AppendSlice(const Data: RawByteString; Index, Count: SizeInt);
    procedure ExpandInto(const Deck: string);
    procedure ExpandMacros(const Line: RawByteString; LineStart, LineEnd: SizeInt; const Stored: TDeckSource);
  public
    constructor Create(ALibrary: TDeckLibrary; Database: TSQLiteLibrary; ARevision: Integer; const Version: string;
      const ExpansionUTC: string = '');
    destructor Destroy; override;
    function Expand(const Deck: string; RootRevision: Integer = 0): RawByteString;
    property RootDeckVersion: string read FRootDeckVersion;
    property ExpansionUTC: string read FExpansionUTC;
  end;

implementation

uses
  SysUtils, ScuClock, ScuErrors, ScuSignals, ScuDirectives;

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
    '$':
      if (Line[Index + 1] <> 'S') or (Line[Index + 2] <> 'C') or (Line[Index + 3] <> 'U') then
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

constructor TDeckExpander.Create(ALibrary: TDeckLibrary; Database: TSQLiteLibrary; ARevision: Integer; const Version: string;
  const ExpansionUTC: string);
begin
  inherited Create;
  FLibrary := ALibrary;
  FDatabase := Database;
  FRevision := ARevision;
  FVersion := Version;
  FExpansionUTC := ExpansionUTC;
  if FExpansionUTC = '' then
    FExpansionUTC := UtcTimestamp(UtcNow);
  FOutput := TMemoryStream.Create;
end;

destructor TDeckExpander.Destroy;
begin
  FOutput.Free;
  inherited Destroy;
end;

procedure TDeckExpander.Append(const Data: RawByteString);
begin
  AppendSlice(Data, 1, Length(Data));
end;

procedure TDeckExpander.AppendSlice(const Data: RawByteString; Index, Count: SizeInt);
begin
  if FOutput.Size + Count > MaxExpansionSize then
    raise EScuError.Create('Expanded deck exceeds the 64 MiB output limit.');
  if Count > 0 then
    FOutput.WriteBuffer(Data[Index], Count);
end;

procedure TDeckExpander.ExpandMacros(const Line: RawByteString; LineStart, LineEnd: SizeInt; const Stored: TDeckSource);
var
  Index, FromIndex, TokenLength: SizeInt;
  Macro: TMacro;
begin
  Index := LineStart;
  FromIndex := Index;
  while Index <= LineEnd do
  begin
    while (Index <= LineEnd) and not (Line[Index] in ['S', '$']) do
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

procedure TDeckExpander.ExpandInto(const Deck: string);
var
  Name: string;
  Source: RawByteString;
  Stored: TDeckSource;
  Index, LineStart, EndingStart, LineNo: SizeInt;
begin
  CheckSessionInterrupt;
  Name := DeckName(Deck);
  if FRootRevision > 0 then
    Stored := FLibrary.Extract(FDatabase, Name, FRootRevision, FVersion)
  else
    Stored := FLibrary.Extract(FDatabase, Name, FRevision, FVersion);
  FRootDeckVersion := Stored.DeckVersion;
  Source := Stored.Bytes;
  Index := 1;
  LineNo := 0;
  while Index <= Length(Source) do
  begin
    if (LineNo and 255) = 0 then CheckSessionInterrupt;
    Inc(LineNo);
    LineStart := Index;
    ReadSourceLine(Source, Index, EndingStart);
    ExpandMacros(Source, LineStart, EndingStart - 1, Stored);
    AppendSlice(Source, EndingStart, Index - EndingStart);
  end;
end;

function TDeckExpander.Expand(const Deck: string; RootRevision: Integer): RawByteString;
begin
  FOutput.Clear;
  FRootDeckVersion := '';
  FRootRevision := RootRevision;
  ExpandInto(Deck);
  SetLength(Result, FOutput.Size);
  if Result <> '' then
    Move(FOutput.Memory^, Result[1], Length(Result));
end;

end.
