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
    procedure ExpandMacros(const Line: RawByteString; LineStart, LineEnd: SizeInt; const Stored: TDeckSource);
  public
    constructor Create(ALibrary: TDeckLibrary; Database: TSQLiteLibrary; ARevision: Integer; const Version, Prefix: string;
      const MissingDeckVersion: string = '');
    destructor Destroy; override;
    function Expand(const Deck: string): RawByteString;
    procedure IncludeCopyDependents(Decks: TStringList);
  end;

implementation

uses
  SysUtils, FPJSON, ScuClock, ScuErrors, ScuJSON, ScuVersions, ScuSignals, ScuDirectives, ScuCopyMetadata;

type
  TMacro = (NoMacro, ModifiedDate, ModifiedTime, LibraryVersion, DeckVersion,
    ModifiedDateTime, ExpansionDate, ExpansionTime, ExpansionDateTime);

const
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

function MacroAt(const Line: RawByteString; Index, LineStart, LineEnd: SizeInt;
  out TokenLength: SizeInt; AfterPrefix: Boolean = False): TMacro;
var
  Candidate: TMacro;
  SpellingIndex: Integer;
begin
  if (Index + 3 > LineEnd) or
    ((Index > LineStart) and not AfterPrefix and IsIdentifierChar(Line[Index - 1])) then
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
    for SpellingIndex := Low(MacroNames[Candidate]) to High(MacroNames[Candidate]) do
      if HasToken(Line, Index, LineEnd, MacroNames[Candidate, SpellingIndex]) then
      begin
        TokenLength := Length(MacroNames[Candidate, SpellingIndex]);
        Exit(Candidate);
      end;
  Result := NoMacro;
end;

constructor TDeckExpander.Create(ALibrary: TDeckLibrary; Database: TSQLiteLibrary; ARevision: Integer; const Version, Prefix: string;
  const MissingDeckVersion: string);
begin
  inherited Create;
  if Prefix <> '' then
    ValidateCommentPrefix(Prefix);
  FLibrary := ALibrary;
  FDatabase := Database;
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
      ExpansionDate: AppendSlice(FExpansionUTC, 1, 10);
      ExpansionTime: AppendSlice(FExpansionUTC, 12, 8);
      ExpansionDateTime: Append(FExpansionUTC);
    end;
    Inc(Index, TokenLength);
    FromIndex := Index;
  end;
  AppendSlice(Line, FromIndex, LineEnd - FromIndex + 1);
end;

procedure TDeckExpander.ExpandInto(const Deck: string);
var
  Name, Target, Prefix: string;
  Source: RawByteString;
  Stored: TDeckSource;
  Index, LineStart, EndingStart, First, Directive, LineNo, TokenLength: SizeInt;
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
    Stored := FLibrary.Extract(FDatabase, Name, FRevision, FMissingDeckVersion);
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
      LineStart := Index;
      ReadSourceLine(Source, Index, EndingStart);
      Directive := DirectiveStart(Source, Prefix, LineStart, EndingStart - 1, First);
      if Directive <> 0 then
      begin
        if HasToken(Source, Directive, EndingStart - 1, CopyDirective) then
        begin
          try
            if not TryCopyTarget(Source, Directive, EndingStart - 1, Target) then
              raise EScuError.Create('Expected SCU_COPY followed by a deck name.');
            PreviousSize := FOutput.Size;
            ExpandInto(Target);
            if (FOutput.Size > PreviousSize) and
              not (PChar(FOutput.Memory)[FOutput.Size - 1] in [#10, #13]) then
              AppendSlice(Source, EndingStart, Index - EndingStart);
          except
            on E: ECommandCancelled do
              raise;
            on E: EScuError do
              raise EScuError.CreateFmt('%s:%d: %s', [Name, LineNo, E.Message]);
          end;
          Continue;
        end;
        if MacroAt(Source, Directive, LineStart, EndingStart - 1, TokenLength, True) <> NoMacro then
        begin
          AppendSlice(Source, LineStart, First - LineStart);
          LineStart := Directive;
        end;
      end;
      ExpandMacros(Source, LineStart, EndingStart - 1, Stored);
      AppendSlice(Source, EndingStart, Index - EndingStart);
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
  Visible: TJSONObject;
  Metadata: TJSONObject;
  RecordedTargets: TJSONArray;
  Parents, Pending, Targets, Dependents: TStringList;
  Name, Target, Prefix: string;
  Stored: TDeckSource;
  Index, TargetIndex, Entry, Head: Integer;
begin
  if Decks.Count = 0 then
    Exit;
  Visible := FDatabase.Revisions.ReadCopyMetadata(FRevision);
  Parents := TStringList.Create;
  Pending := TStringList.Create;
  Targets := TStringList.Create;
  try
    Parents.CaseSensitive := True;
    Parents.Sorted := True;
    Parents.OwnsObjects := True;
    Targets.CaseSensitive := True;
    Targets.Sorted := True;
    Targets.Duplicates := dupIgnore;
    for Index := 0 to Visible.Count - 1 do
    begin
      CheckSessionInterrupt;
      Name := Visible.Names[Index];
      if Decks.IndexOf(Name) >= 0 then
        Continue;
      Targets.Clear;
      Metadata := nil;
      if Visible.Items[Index] is TJSONObject then
        Metadata := TJSONObject(Visible.Items[Index]);
      if Assigned(Metadata) and ((FPrefixOverride = '') or
        (Field(Metadata, 'prefix', jtString).AsString = FPrefixOverride)) then
      begin
        RecordedTargets := TJSONArray(Field(Metadata, 'targets', jtArray));
        for TargetIndex := 0 to RecordedTargets.Count - 1 do
          Targets.Add(RecordedTargets.Strings[TargetIndex]);
      end
      else
      begin
        Stored := FLibrary.Extract(FDatabase, Name, FRevision);
        Prefix := EffectivePrefix(Stored);
        CollectCopyTargets(Stored.Bytes, Prefix, Targets);
        if not Assigned(Metadata) and (Prefix = Stored.CommentPrefix) then
          CacheCopyMetadata(FDatabase, Stored.LibraryRevision, Stored.CommentPrefix, Targets);
      end;
      for Target in Targets do
      begin
        if not Parents.Find(Target, Entry) then
          Entry := Parents.AddObject(Target, TStringList.Create);
        TStringList(Parents.Objects[Entry]).Add(Name);
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
    Targets.Free;
    Pending.Free;
    Parents.Free;
    Visible.Free;
  end;
end;

end.
