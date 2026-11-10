unit ScuExpand;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuLibrary;

type
  TDeckExpander = class
  private
    FLibrary: TDeckLibrary;
    FRevision: Integer;
    FPrefixOverride, FDefaultPrefix: string;
    FVersion, FMissingDeckVersion, FExpansionUTC: string;
    FVisits: Integer;
    FSourceBytes: Int64;
    FStack: TStringList;
    FOutput: TMemoryStream;
    function EffectivePrefix(const Stored: TDeckSource): string;
    procedure Append(const Data: RawByteString);
    procedure AppendSlice(const Data: RawByteString; Index, Count: SizeInt);
    procedure ExpandInto(const Deck: string);
    procedure ExpandMacros(const Line: RawByteString; const Stored: TDeckSource);
  public
    constructor Create(ALibrary: TDeckLibrary; ARevision: Integer; const Version, Prefix: string;
      const MissingDeckVersion: string = '');
    destructor Destroy; override;
    function Expand(const Deck: string): RawByteString;
    procedure IncludeCopyDependents(Decks: TStringList);
  end;

implementation

uses
  SysUtils, ScuIO, ScuVersions, ScuSignals;

type
  TMacro = (NoMacro, ModifiedDate, ModifiedTime, LibraryVersion, DeckVersion,
    ModifiedDateTime, ExpansionDate, ExpansionTime, ExpansionDateTime);

const
  CopyDirective = 'SCU_COPY';
  MacroNames: array[ModifiedDate..ExpansionDateTime, 0..2] of string = (
    ('SCU$LAST_MODIFIED_DATE', 'SCU$DATE', '$SCU_DATE'),
    ('SCU$LAST_MODIFIED_TIME', 'SCU$TIME', '$SCU_TIME'),
    ('SCU$LIBRARY_VERSION', 'SCU$VERSION', '$SCU_VERSION'),
    ('SCU$DECK_VERSION', '', ''),
    ('SCU$LAST_MODIFIED_DATE_TIME', '', ''),
    ('SCU$EXPANSION_DATE', '', ''),
    ('SCU$EXPANSION_TIME', '', ''),
    ('SCU$EXPANSION_DATE_TIME', '', '')
  );
  MaxExpansionSize = 64 * 1024 * 1024;
  MaxDepth = 64;
  MaxVisits = 10000;
  MaxSourceBytes = 256 * 1024 * 1024;

function IsIdentifierChar(Value: Char): Boolean;
begin
  Result := Value in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

function HasToken(const Line: RawByteString; Index: SizeInt; const Token: string): Boolean;
begin
  Result := (Copy(Line, Index, Length(Token)) = Token) and
    ((Index + Length(Token) > Length(Line)) or
      not IsIdentifierChar(Line[Index + Length(Token)]));
end;

function MacroAt(const Line: RawByteString; Index: SizeInt;
  out TokenLength: SizeInt; AfterPrefix: Boolean = False): TMacro;
var
  Candidate: TMacro;
  Spelling: string;
begin
  if (Index > Length(Line)) or not (Line[Index] in ['S', '$']) or
    ((Index > 1) and not AfterPrefix and IsIdentifierChar(Line[Index - 1])) then
    Exit(NoMacro);
  if (Copy(Line, Index, 4) <> 'SCU$') and (Copy(Line, Index, 4) <> '$SCU') then
    Exit(NoMacro);
  for Candidate := Low(MacroNames) to High(MacroNames) do
    for Spelling in MacroNames[Candidate] do
      if (Spelling <> '') and HasToken(Line, Index, Spelling) then
      begin
        TokenLength := Length(Spelling);
        Exit(Candidate);
      end;
  Result := NoMacro;
end;

procedure ReadSourceLine(const Source: RawByteString; var Index: SizeInt;
  out Line, Ending: RawByteString);
var
  Start: SizeInt;
begin
  Start := Index;
  while (Index <= Length(Source)) and not (Source[Index] in [#10, #13]) do
    Inc(Index);
  Line := Copy(Source, Start, Index - Start);
  Start := Index;
  if (Index <= Length(Source)) and (Source[Index] = #13) then
    Inc(Index);
  if (Index <= Length(Source)) and (Source[Index] = #10) then
    Inc(Index);
  Ending := Copy(Source, Start, Index - Start);
end;

function DirectiveStart(const Line: RawByteString; const Prefix: string; out First: SizeInt): SizeInt;
begin
  First := 1;
  while (First <= Length(Line)) and (Line[First] in [' ', #9]) do
    Inc(First);
  if Copy(Line, First, Length(Prefix)) = Prefix then
    Exit(First + Length(Prefix));
  Result := 0;
end;

function TryCopyTarget(const Line: RawByteString; Directive: SizeInt; out Target: string): Boolean;
var
  Separator: SizeInt;
begin
  Separator := Directive + Length(CopyDirective);
  Result := (Separator <= Length(Line)) and (Line[Separator] in [' ', #9]);
  if Result then
    Target := Trim(Copy(Line, Separator, MaxInt));
end;

constructor TDeckExpander.Create(ALibrary: TDeckLibrary; ARevision: Integer; const Version, Prefix: string;
  const MissingDeckVersion: string);
begin
  inherited Create;
  if Prefix <> '' then
    ValidateCommentPrefix(Prefix);
  FLibrary := ALibrary;
  FRevision := ARevision;
  FVersion := Version;
  FExpansionUTC := UtcTimestamp(UtcNow);
  FMissingDeckVersion := MissingDeckVersion;
  FPrefixOverride := Prefix;
  FDefaultPrefix := ALibrary.DefaultCommentPrefix(Version);
  FStack := TStringList.Create;
  FStack.CaseSensitive := True;
  FOutput := TMemoryStream.Create;
end;

function TDeckExpander.EffectivePrefix(const Stored: TDeckSource): string;
begin
  Result := FPrefixOverride;
  if Result = '' then
    Result := Stored.CommentPrefix;
  if Result = '' then
    Result := FDefaultPrefix;
end;

destructor TDeckExpander.Destroy;
begin
  FOutput.Free;
  FStack.Free;
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

procedure TDeckExpander.ExpandMacros(const Line: RawByteString; const Stored: TDeckSource);
var
  Index, FromIndex, TokenLength: SizeInt;
  Macro: TMacro;
begin
  Index := 1;
  FromIndex := Index;
  while Index <= Length(Line) do
  begin
    Macro := MacroAt(Line, Index, TokenLength);
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
      ExpansionDate: AppendSlice(FExpansionUTC, 1, 10);
      ExpansionTime: AppendSlice(FExpansionUTC, 12, 8);
      ExpansionDateTime: Append(FExpansionUTC);
    end;
    Inc(Index, TokenLength);
    FromIndex := Index;
  end;
  AppendSlice(Line, FromIndex, Length(Line) - FromIndex + 1);
end;

procedure TDeckExpander.ExpandInto(const Deck: string);
var
  Name, Target, Prefix: string;
  Source, Line, Ending: RawByteString;
  Stored: TDeckSource;
  Index, First, Directive, LineNo, TokenLength: SizeInt;
  PreviousSize: Int64;
begin
  CheckSessionInterrupt;
  Name := DeckName(Deck);
  if FStack.IndexOf(Name) >= 0 then
    raise EScuError.CreateFmt('COPY cycle: %s -> %s.', [Trim(FStack.CommaText), Name]);
  if FStack.Count >= MaxDepth then
    raise EScuError.Create('COPY nesting exceeds 64 decks.');
  FStack.Add(Name);
  try
    Inc(FVisits);
    if FVisits > MaxVisits then
      raise EScuError.Create('Expansion exceeds 10000 deck visits.');
    Stored := FLibrary.Extract(Name, FRevision, FMissingDeckVersion);
    Prefix := EffectivePrefix(Stored);
    Source := Stored.Bytes;
    Inc(FSourceBytes, Length(Source));
    if FSourceBytes > MaxSourceBytes then
      raise EScuError.Create('Expansion exceeds 256 MiB of source input.');
    Index := 1;
    LineNo := 0;
    while Index <= Length(Source) do
    begin
      if (LineNo and 255) = 0 then
        CheckSessionInterrupt;
      Inc(LineNo);
      ReadSourceLine(Source, Index, Line, Ending);
      Directive := DirectiveStart(Line, Prefix, First);
      if Directive <> 0 then
      begin
        if HasToken(Line, Directive, CopyDirective) then
        begin
          try
            if not TryCopyTarget(Line, Directive, Target) then
              raise EScuError.Create('Expected SCU_COPY followed by a deck name.');
            PreviousSize := FOutput.Size;
            ExpandInto(Target);
            if (FOutput.Size > PreviousSize) and
              not (PChar(FOutput.Memory)[FOutput.Size - 1] in [#10, #13]) then
              Append(Ending);
          except
            on E: EScuError do
              raise EScuError.CreateFmt('%s:%d: %s', [Name, LineNo, E.Message]);
          end;
          Continue;
        end;
        if MacroAt(Line, Directive, TokenLength, True) <> NoMacro then
          Delete(Line, First, Length(Prefix));
      end;
      ExpandMacros(Line, Stored);
      Append(Ending);
    end;
  finally
    FStack.Delete(FStack.Count - 1);
  end;
end;

function TDeckExpander.Expand(const Deck: string): RawByteString;
begin
  FOutput.Clear;
  FVisits := 0;
  FSourceBytes := 0;
  ExpandInto(Deck);
  SetLength(Result, FOutput.Size);
  if Result <> '' then
    Move(FOutput.Memory^, Result[1], Length(Result));
end;

procedure TDeckExpander.IncludeCopyDependents(Decks: TStringList);
var
  Visible, Parents, Pending, Dependents: TStringList;
  Name, Target, Prefix: string;
  Line, Ending: RawByteString;
  Stored: TDeckSource;
  Index, First, Directive: SizeInt;
  Entry, Head: Integer;
begin
  if Decks.Count = 0 then
    Exit;
  Visible := TStringList.Create;
  Parents := TStringList.Create;
  Pending := TStringList.Create;
  try
    Visible.CaseSensitive := True;
    Visible.Sorted := True;
    Visible.Duplicates := dupIgnore;
    FLibrary.ChangedDecks(0, FRevision, Visible);
    if Visible.Count = Decks.Count then
      Exit;
    Parents.CaseSensitive := True;
    Parents.Sorted := True;
    Parents.OwnsObjects := True;
    for Name in Visible do
    begin
      CheckSessionInterrupt;
      // Decks already scheduled for output do not need incoming edges.
      if Decks.IndexOf(Name) >= 0 then
        Continue;
      Stored := FLibrary.Extract(Name, FRevision);
      Prefix := EffectivePrefix(Stored);
      Index := 1;
      while Index <= Length(Stored.Bytes) do
      begin
        ReadSourceLine(Stored.Bytes, Index, Line, Ending);
        Directive := DirectiveStart(Line, Prefix, First);
        if (Directive = 0) or not HasToken(Line, Directive, CopyDirective) or
          not TryCopyTarget(Line, Directive, Target) then
          Continue;
        Target := LowerCase(Target);
        if not Parents.Find(Target, Entry) then
          Entry := Parents.AddObject(Target, TStringList.Create);
        Dependents := TStringList(Parents.Objects[Entry]);
        if (Dependents.Count = 0) or (Dependents[Dependents.Count - 1] <> Name) then
          Dependents.Add(Name);
      end;
    end;
    Pending.Assign(Decks);
    Head := 0;
    while Head < Pending.Count do
    begin
      if Parents.Find(Pending[Head], Entry) then
      begin
        Dependents := TStringList(Parents.Objects[Entry]);
        for Name in Dependents do
          if Decks.IndexOf(Name) < 0 then
          begin
            Decks.Add(Name);
            Pending.Add(Name);
          end;
      end;
      Inc(Head);
    end;
  finally
    Pending.Free;
    Parents.Free;
    Visible.Free;
  end;
end;

end.
