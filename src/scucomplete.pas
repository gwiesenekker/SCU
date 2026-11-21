unit ScuComplete;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuBinder, ScuCommands, ScuLibrary;

type
  TCompletionContext = record
    CommandName, Deck, Version, Revision, FromSnapshot, ToSnapshot: string;
  end;

  TCompletionLibrary = class
  private
    FPath, FState: string;
    FSnapshot: TDeckLibrary;
  public
    destructor Destroy; override;
    // The cache owns the snapshot. A later read can replace it.
    function ReadSnapshot(const LibraryPath: string): TDeckLibrary;
  end;

function CompletionContext(Binder: TCommandBinder): TCompletionContext;
procedure CompleteLine(Commands: TCommandDefinitions; const LibraryPath, Before, Prefix, After: string;
  Candidates: TStrings; out AppendCharacter: Char; LibraryCache: TCompletionLibrary;
  PendingLibrary: TDeckLibrary);
procedure CompleteValue(Commands: TCommandDefinitions; Parameter: TParameterDefinition;
  const Context: TCompletionContext; const LibraryPath, Value, Prefix: string; Quote: Char; RawValue: Boolean;
  Candidates: TStrings; out AppendCharacter: Char; LibraryCache: TCompletionLibrary;
  PendingLibrary: TDeckLibrary);

implementation

uses
  SysUtils, ScuErrors, ScuFiles, ScuSQLite, ScuTokenizer;

destructor TCompletionLibrary.Destroy;
begin
  FSnapshot.Free;
  inherited Destroy;
end;

function TCompletionLibrary.ReadSnapshot(const LibraryPath: string): TDeckLibrary;
var
  Reader: TSQLiteLibrary;
  State: string;
  Snapshot: TDeckLibrary;
begin
  if not RegularFileExists(LibraryPath) then
    Exit(nil);
  Reader := TSQLiteLibrary.OpenRead(LibraryPath);
  try
    State := Reader.Revisions.StateKey;
    if not Assigned(FSnapshot) or (FPath <> LibraryPath) or (FState <> State) then
    begin
      Snapshot := TDeckLibrary.Load(LibraryPath, Reader);
      FSnapshot.Free;
      FSnapshot := Snapshot;
      FPath := LibraryPath;
      FState := State;
    end;
    Result := FSnapshot;
  finally
    Reader.Free;
  end;
end;

procedure RecordCompletionValue(var Context: TCompletionContext; const Name, Value: string);
begin
  case Name of
    'deck_name': Context.Deck := Value;
    'version': Context.Version := Value;
    'revision': Context.Revision := Value;
    'from_snapshot': Context.FromSnapshot := Value;
    'to_snapshot': Context.ToSnapshot := Value;
  end;
end;

function CompletionContext(Binder: TCommandBinder): TCompletionContext;
var
  Slot: Integer;
begin
  Result := Default(TCompletionContext);
  Result.CommandName := Binder.Name;
  for Slot := 0 to Binder.Arguments.Count - 1 do
    if Binder.Supplied[Slot] then
      RecordCompletionValue(Result, Binder.ParameterAt(Slot).Name, Binder.Values[Slot]);
end;

type
  TParameterSlots = array of Boolean;

procedure SuggestNames(Entries: TDefinitionList; const Prefix, Leader: string; Candidates: TStrings;
  const Supplied: TParameterSlots = nil; Offset: Integer = 0; PreferExact: Boolean = True);
var
  Index, AliasIndex: Integer;
  Entry: TNamedDefinition;
  Exact: string;

  procedure Suggest(const Name: string);
  var
    Spelling: string;
  begin
    Spelling := Leader + Name;
    if PreferExact and SameText(Spelling, Prefix) then
      Exact := Spelling
    else if SameText(Copy(Spelling, 1, Length(Prefix)), Prefix) then
      Candidates.Add(Spelling);
  end;

begin
  Exact := '';
  for Index := 0 to Entries.Count - 1 do
  begin
    if Assigned(Supplied) and Supplied[Offset + Index] then
      Continue;
    Entry := Entries.Entries[Index];
    Suggest(Entry.Name);
    for AliasIndex := 0 to Entry.AliasCount - 1 do
      Suggest(Entry.Aliases[AliasIndex]);
  end;
  if Exact <> '' then
  begin
    Candidates.Clear;
    Candidates.Add(Exact);
  end;
end;

function MatchesDeckVersion(LibraryFile: TDeckLibrary; const Candidate, Selector: string): Boolean;
begin
  if (Selector = '') or SameText(Selector, CurrentDeckVersionSelector) then
    Exit(True);
  try
    LibraryFile.ParseDeckSnapshot(Candidate, Selector);
    Result := True;
  except
    on E: EScuError do Result := False;
  end;
end;

function VisibleEntry(const Entry, Leaf: string): Boolean;
var
  Ch: Char;
begin
  if (Entry = '.') or (Entry = '..') or
    ((Entry[1] = '.') and (Copy(Leaf, 1, 1) <> '.')) then
    Exit(False);
  for Ch in Entry do
    if Ch in [#0..#31, #127] then
      Exit(False);
  Result := Copy(Entry, 1, Length(Leaf)) = Leaf;
end;

procedure CompleteFileValues(Kind: TCompletionKind; const Value: string; Values: TStrings;
  const LibraryPath: string = '');
var
  Directory, SearchDirectory, Leaf, Name: string;
  Search: TSearchRec;
  IsDirectory: Boolean;
begin
  Directory := ExtractFilePath(Value);
  Leaf := ExtractFileName(Value);
  SearchDirectory := Directory;
  if Kind = ckLibraryFile then
  begin
    if (Directory <> '') or (Pos('\', Value) > 0) then
      Exit;
    SearchDirectory := IncludeTrailingPathDelimiter(ExtractFileDir(ExpandFileName(LibraryPath)));
  end;
  if SearchDirectory = '' then
    SearchDirectory := './';
  if FindFirst(SearchDirectory + '*', faAnyFile, Search) = 0 then
  try
    repeat
      if not VisibleEntry(Search.Name, Leaf) then
        Continue;
      Name := SearchDirectory + Search.Name;
      IsDirectory := DirectoryExists(Name);
      if IsDirectory and (Kind <> ckLibraryFile) then
        Values.Add(Directory + Search.Name + DirectorySeparator)
      else if not IsDirectory and (Kind in [ckFile, ckLibraryFile]) and FileExists(Name) then
        Values.Add(Directory + Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure CompleteDeckValues(LibraryFile: TDeckLibrary; const Context: TCompletionContext;
  const Value: string; Values: TStringList);
var
  Last, Index: Integer;
  DeckVersion: string;
  Snapshot: TLibrarySnapshot;
  Selection: TDeckSelection;
begin
  Last := LibraryFile.Revision;
  DeckVersion := Context.Version;
  if (DeckVersion <> '') and (Pos('-', DeckVersion) <= 1) then
  begin
    Snapshot := LibraryFile.ParseLibrarySnapshot(DeckVersion);
    Last := Snapshot.LibraryRevision;
    DeckVersion := '';
  end;
  LibraryFile.ChangedDecks(0, Last, Values);
  if (DeckVersion = '') and (Context.FromSnapshot = '') and (Context.ToSnapshot = '') and
    (Context.Revision = '') and
    (Context.CommandName <> 'display_deck') and (Context.CommandName <> 'display_deck_diff') then
    for Index := Values.Count - 1 downto 0 do
      if not LibraryFile.TryDeckSnapshot(Values[Index], Last, Snapshot) then
        Values.Delete(Index);
  if (DeckVersion <> '') or (Context.FromSnapshot <> '') or (Context.ToSnapshot <> '') then
    for Index := Values.Count - 1 downto 0 do
      if not (MatchesDeckVersion(LibraryFile, Values[Index], DeckVersion) and
        MatchesDeckVersion(LibraryFile, Values[Index], Context.FromSnapshot) and
        MatchesDeckVersion(LibraryFile, Values[Index], Context.ToSnapshot)) then
        Values.Delete(Index);
  if (Context.Revision <> '') and
    ((Context.CommandName = 'extract_deck') or (Context.CommandName = 'expand_deck')) then
    for Index := Values.Count - 1 downto 0 do
      try
        Selection := LibraryFile.SelectDeck(Values[Index], Context.Version, Context.Revision);
        if Selection.RootRevision = 0 then
          Values.Delete(Index);
      except
        on E: EScuError do Values.Delete(Index);
      end;
  if SameText(Copy(Value, 1, 4), 'scu$') and
    (Values.IndexOf(LibraryFile.LastModifiedDeck) >= 0) then
    Values.Add(LastModifiedDeckSelector);
end;

procedure CompleteSnapshotValues(LibraryFile: TDeckLibrary; Kind: TCompletionKind;
  const Context: TCompletionContext; const Value: string; Values: TStrings);
var
  Deck: string;
  Index, DeckRevisionCount: Integer;
  Selection: TDeckSelection;
  RevisionFormats: TDeckRevisionFormats;
  Previous: TLibrarySnapshot;

  procedure AddLibraryValue(const Candidate: string);
  begin
    if SameText(Copy(Candidate, 1, Length(Value)), Value) then
      Values.Add(Candidate);
  end;

begin
  if (Kind = ckVersion) and (Context.CommandName = 'rename_version') then
  begin
    AddLibraryValue(LibraryFile.CurrentVersion);
    Exit;
  end;
  Deck := Context.Deck;
  if (Kind = ckDeckVersion) and (Deck = '') then
    Deck := LibraryFile.LastModifiedDeck;
  if SameText(Deck, LastModifiedDeckSelector) then
  begin
    Deck := LibraryFile.LastModifiedDeck;
    if Deck = '' then
      Exit;
  end;
  if Kind in [ckVersion, ckLibraryVersion] then
    if (Kind = ckVersion) and (Context.Revision <> '') then
      LibraryFile.ListVersionNames(Values)
    else
      LibraryFile.ListVersionNames(Values, Deck);
  if (Kind = ckVersion) and (Context.Revision <> '') and (Deck <> '') then
    for Index := Values.Count - 1 downto 0 do
      try
        Selection := LibraryFile.SelectDeck(Deck, Values[Index], Context.Revision);
        if Selection.RootRevision = 0 then
          Values.Delete(Index);
      except
        on E: EScuError do Values.Delete(Index);
      end;
  if Kind = ckRevision then
  begin
    if Deck = '' then
      Deck := LibraryFile.LastModifiedDeck;
    if Deck <> '' then
      LibraryFile.ListDeckRevisionNames(Deck, Context.Version, Values);
    Exit;
  end;
  if (Kind = ckVersion) and
    ((Context.CommandName = 'release_version') or (Context.CommandName = 'extract_deck') or
     (Context.CommandName = 'expand_deck')) then
    if (Context.Revision = '') or (Values.IndexOf(LibraryFile.CurrentVersion) >= 0) then
      AddLibraryValue(CurrentVersionSelector);
  if Kind = ckLibraryVersion then
  begin
    if Context.CommandName = 'release_version' then
      AddLibraryValue(LatestVersionSelector);
    AddLibraryValue(CurrentVersionSelector);
    if LibraryFile.TryPreviousSnapshot(Previous) then
      AddLibraryValue(PreviousVersionSelector);
  end;
  if Deck <> '' then
  begin
    RevisionFormats := [];
    if (Kind = ckDeckVersion) or ((Kind = ckVersion) and ((Value = '') or (Pos('-', Value) > 1))) then
      Include(RevisionFormats, drDeckVersion);
    DeckRevisionCount := LibraryFile.ListDeckRevisions(Deck, Values, RevisionFormats);
    if Kind = ckDeckVersion then
    begin
      if DeckRevisionCount > 0 then
        AddLibraryValue(CurrentDeckVersionSelector);
      if DeckRevisionCount > 1 then
        AddLibraryValue(PreviousDeckVersionSelector);
    end;
  end;
end;

procedure CollectCompletionValues(Commands: TCommandDefinitions; Kind: TCompletionKind;
  const Context: TCompletionContext; const LibraryPath, Value: string; Values: TStringList;
  LibraryCache: TCompletionLibrary; PendingLibrary: TDeckLibrary);
var
  LibraryFile: TDeckLibrary;
begin
  case Kind of
    ckCommand: SuggestNames(Commands, Value, '', Values, nil, 0, False);
    ckFile, ckDirectory, ckLibraryFile: CompleteFileValues(Kind, Value, Values, LibraryPath);
    ckDeck, ckVersion, ckRevision, ckDeckVersion, ckLibraryVersion:
      begin
        LibraryFile := PendingLibrary;
        if not Assigned(LibraryFile) then
          LibraryFile := LibraryCache.ReadSnapshot(LibraryPath);
        if not Assigned(LibraryFile) then
          Exit;
        if Kind = ckDeck then
          CompleteDeckValues(LibraryFile, Context, Value, Values)
        else
          CompleteSnapshotValues(LibraryFile, Kind, Context, Value, Values);
      end;
  end;
end;

procedure CompleteValue(Commands: TCommandDefinitions; Parameter: TParameterDefinition;
  const Context: TCompletionContext; const LibraryPath, Value, Prefix: string; Quote: Char; RawValue: Boolean;
  Candidates: TStrings; out AppendCharacter: Char; LibraryCache: TCompletionLibrary;
  PendingLibrary: TDeckLibrary);
var
  Kind: TCompletionKind;
  Values: TStringList;
  Name, Suffix: string;
  Index, AliasIndex: Integer;
begin
  AppendCharacter := ' ';
  if RawValue then
    AppendCharacter := #0
  else if Quote <> #0 then
    AppendCharacter := Quote;
  if not Assigned(Parameter) then
    Exit;
  Kind := Parameter.Completion;
  if Kind = ckNone then
    Exit;
  Values := TStringList.Create;
  try
    Values.CaseSensitive := True;
    Values.Sorted := True;
    Values.Duplicates := dupIgnore;
    if Kind = ckEnum then
      for Index := 0 to Parameter.ValueCount - 1 do
      begin
        Values.Add(Parameter.Values[Index]);
        for AliasIndex := 0 to Parameter.EnumValues[Index].AliasCount - 1 do
          Values.Add(Parameter.EnumValues[Index].Aliases[AliasIndex]);
      end
    else
      CollectCompletionValues(Commands, Kind, Context, LibraryPath, Value, Values, LibraryCache, PendingLibrary);
    for Name in Values do
    begin
      if (Kind = ckDeck) and (Pos('$', Name) = 0) then
      begin
        if Copy(Name, 1, Length(Value)) <> Value then Continue;
      end
      else if not SameText(Copy(Name, 1, Length(Value)), Value) then Continue;
      Suffix := Copy(Name, Length(Value) + 1, MaxInt);
      if not RawValue then
        Suffix := EscapeSuffix(Suffix, Quote);
      Candidates.Add(Prefix + Suffix);
    end;
    if (Candidates.Count = 1) and ((Kind = ckFile) or (Kind = ckDirectory)) then
    begin
      Name := Values[0];
      if Name[Length(Name)] = DirectorySeparator then
        AppendCharacter := #0;
    end;
  finally
    Values.Free;
  end;
end;

type
  TLineCompletion = record
    Commands: TCommandDefinitions;
    LibraryPath, Prefix, After: string;
    Current: TCommandToken;
    Spec: TCommandDefinition;
    Earlier: TCommandBinder; // Borrowed for one completion request.
    LibraryCache: TCompletionLibrary;
    PendingLibrary: TDeckLibrary;
  end;

function WithLaterBindings(const Request: TLineCompletion; Position: Integer): TCommandBinder;
var
  LaterTokens: TStringList;
  Token: string;
  Tail: TCommandToken;
begin
  Result := Request.Earlier.WithReservedSlot(Position);
  if (Request.After = '') or (Request.Current.Quote <> #0) then
    Exit;
  try
    LaterTokens := TStringList.Create;
    try
      if TokenizeCommandPrefix(Request.After, LaterTokens, Tail) and
        (Tail.Quote = #0) and Tail.Started then
        LaterTokens.Add(Tail.Text);
      for Token in LaterTokens do
        Result.Feed(Token);
    finally
      LaterTokens.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function HiddenNameSlots(const Request: TLineCompletion): TParameterSlots;
var
  Bindings: TCommandBinder;
  GroupIndex, MemberIndex, ArgumentSlot, Position: Integer;
  Selected: Boolean;
begin
  Bindings := WithLaterBindings(Request, -1);
  try
    Result := nil;
    SetLength(Result, Bindings.Count);
    for Position := 0 to High(Result) do
      Result[Position] := Bindings.Supplied[Position];
    for GroupIndex := 0 to Request.Spec.ExclusiveGroupCount - 1 do
    begin
      Selected := False;
      for MemberIndex := 0 to Request.Spec.ExclusiveGroupSize[GroupIndex] - 1 do
      begin
        ArgumentSlot := Request.Spec.ExclusiveArguments[GroupIndex, MemberIndex].ArgumentIndex;
        if Bindings.Supplied[ArgumentSlot] then
        begin
          Selected := True;
          Break;
        end;
      end;
      if Selected then
        for MemberIndex := 0 to Request.Spec.ExclusiveGroupSize[GroupIndex] - 1 do
        begin
          ArgumentSlot := Request.Spec.ExclusiveArguments[GroupIndex, MemberIndex].ArgumentIndex;
          Result[ArgumentSlot] := True;
        end;
    end;
  finally
    Bindings.Free;
  end;
end;

procedure SuggestBoundValue(const Request: TLineCompletion; Position: Integer; const Value: string;
  Candidates: TStrings; out AppendCharacter: Char);
var
  Bindings: TCommandBinder;
begin
  Bindings := WithLaterBindings(Request, Position);
  try
    CompleteValue(Request.Commands, Bindings.ParameterAt(Position), CompletionContext(Bindings),
      Request.LibraryPath, Value, Request.Prefix, Request.Current.Quote, False, Candidates, AppendCharacter, Request.LibraryCache, Request.PendingLibrary);
  finally
    Bindings.Free;
  end;
end;

procedure SuggestParameterValues(const Request: TLineCompletion; Candidates: TStrings;
  out AppendCharacter: Char);
var
  Names: TStringList;
  Hidden: TParameterSlots;
  Index, Slot: Integer;
  Name: string;
begin
  Names := TStringList.Create;
  try
    if not Request.Earlier.PositionalOnly and (Request.Current.Text = Request.Prefix) then
    begin
      Hidden := HiddenNameSlots(Request);
      SuggestNames(Request.Earlier.Arguments, Request.Prefix, '', Names, Hidden);
      Index := Names.IndexOf(Request.Prefix);
      if Index >= 0 then
      begin
        Candidates.Add(Names[Index]);
        AppendCharacter := '=';
        Exit;
      end;
    end;
    Slot := Request.Earlier.NextPositional;
    if Slot >= 0 then
      SuggestBoundValue(Request, Slot, Request.Current.Text, Candidates, AppendCharacter);
    if Candidates.Count = 0 then
    begin
      Candidates.AddStrings(Names);
      AppendCharacter := '=';
    end
    else
      for Name in Names do
        Candidates.Add(Name + '=');
  finally
    Names.Free;
  end;
end;

procedure CompleteLine(Commands: TCommandDefinitions; const LibraryPath, Before, Prefix, After: string;
  Candidates: TStrings; out AppendCharacter: Char; LibraryCache: TCompletionLibrary;
  PendingLibrary: TDeckLibrary);
var
  Tokens: TStringList;
  Request: TLineCompletion;
  Hidden: TParameterSlots;
  Index, Slot, Separator: Integer;
begin
  AppendCharacter := ' ';
  Request.Commands := Commands;
  Request.LibraryPath := LibraryPath;
  Request.Prefix := Prefix;
  Request.After := After;
  Request.LibraryCache := LibraryCache;
  Request.PendingLibrary := PendingLibrary;
  Tokens := TStringList.Create;
  try
    if not TokenizeCommandPrefix(Before + Prefix, Tokens, Request.Current) then
      Exit;
    if Tokens.Count = 0 then
    begin
      if Prefix = Request.Current.Text then
        SuggestNames(Commands, Prefix, '', Candidates, nil, 0, False);
      Exit;
    end;
    Index := Commands.FindIndex(Tokens[0]);
    if Index < 0 then
      Exit;
    Request.Spec := Commands[Index];
    Request.Earlier := TCommandBinder.Create(Request.Spec, bmCompletion);
    try
      for Index := 1 to Tokens.Count - 1 do
        Request.Earlier.Feed(Tokens[Index]);
      if Request.Earlier.PendingAccepts(Request.Current.Text) then
        SuggestBoundValue(Request, Request.Earlier.PendingSlot, Request.Current.Text, Candidates, AppendCharacter)
      else
      begin
        Slot := Request.Earlier.NamedSlot(Request.Current.Text, Separator);
        if (Slot >= 0) and (Separator > 0) then
          SuggestBoundValue(Request, Slot, Copy(Request.Current.Text, Separator + 1, MaxInt), Candidates, AppendCharacter)
        else if not Request.Earlier.PositionalOnly and (Copy(Request.Current.Text, 1, 1) = '-') and
          (Request.Current.Text = Prefix) then
        begin
          Hidden := HiddenNameSlots(Request);
          SuggestNames(Request.Earlier.Arguments, Prefix, '--', Candidates, Hidden);
        end
        else
          SuggestParameterValues(Request, Candidates, AppendCharacter);
      end;
    finally
      Request.Earlier.Free;
    end;
  finally
    Tokens.Free;
  end;
end;

end.
