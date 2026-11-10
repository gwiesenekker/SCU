unit ScuComplete;

{$mode objfpc}{$H+}

interface

uses
  Classes, ScuBinder, ScuCommands, ScuLibrary;

type
  TCompletionContext = record
    Deck, Version, Revision, FromSnapshot, ToSnapshot: string;
  end;

function CompletionContext(Binder: TCommandBinder): TCompletionContext;
procedure CompleteLine(Commands: TCommandDefinitions; const LibraryPath, Before, Prefix, After: string;
  Candidates: TStrings; out AppendCharacter: Char; PendingLibrary: TDeckLibrary = nil);
procedure CompleteValue(Commands: TCommandDefinitions; Parameter: TParameterDefinition;
  const Context: TCompletionContext; const LibraryPath, Value, Prefix: string; Quote: Char; RawValue: Boolean;
  Candidates: TStrings; out AppendCharacter: Char; PendingLibrary: TDeckLibrary = nil);

implementation

uses
  SysUtils, ScuErrors, ScuFiles, ScuTokenizer;

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
  for Slot := Binder.Arguments.Count to Binder.Count - 1 do
    if Binder.Supplied[Slot] then
      RecordCompletionValue(Result, Binder.ParameterAt(Slot).Name, Binder.Values[Slot]);
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

procedure CompleteValue(Commands: TCommandDefinitions; Parameter: TParameterDefinition;
  const Context: TCompletionContext; const LibraryPath, Value, Prefix: string; Quote: Char; RawValue: Boolean;
  Candidates: TStrings; out AppendCharacter: Char; PendingLibrary: TDeckLibrary);
var
  Kind: TCompletionKind;
  Directory, SearchDirectory, Leaf, Name, Suffix, Deck, DeckVersion: string;
  Values: TStringList;
  LibraryFile: TDeckLibrary;
  Search: TSearchRec;
  Index, Base, Last, DeckRevisionCount: Integer;
  IsDirectory: Boolean;

  procedure AddLibraryValue(const Candidate: string);
  begin
    if SameText(Copy(Candidate, 1, Length(Value)), Value) then
      Values.Add(Candidate);
  end;

  function MatchesDeckVersion(const Candidate, Selector: string): Boolean;
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

  function VisibleEntry(const Entry: string): Boolean;
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
    case Kind of
      ckBoolean:
        begin
          Values.Add('no');
          Values.Add('yes');
        end;
      ckCommand: SuggestNames(Commands, Value, '', Values, nil, 0, False);
      ckFile, ckDirectory:
        begin
          Directory := ExtractFilePath(Value);
          Leaf := ExtractFileName(Value);
          SearchDirectory := Directory;
          if SearchDirectory = '' then
            SearchDirectory := './';
          if FindFirst(SearchDirectory + '*', faAnyFile, Search) = 0 then
          try
            repeat
              if not VisibleEntry(Search.Name) then
                Continue;
              Name := SearchDirectory + Search.Name;
              IsDirectory := DirectoryExists(Name);
              if IsDirectory then
                Values.Add(Directory + Search.Name + DirectorySeparator)
              else if (Kind = ckFile) and FileExists(Name) then
                Values.Add(Directory + Search.Name);
            until FindNext(Search) <> 0;
          finally
            FindClose(Search);
          end;
        end;
      ckDeck, ckVersion, ckRevision, ckDeckVersion:
        begin
          LibraryFile := PendingLibrary;
          if not Assigned(LibraryFile) then
          begin
            if not RegularFileExists(LibraryPath) then
              Exit;
            LibraryFile := TDeckLibrary.Create(LibraryPath);
          end;
          try
            if Kind = ckDeck then
            begin
              Last := LibraryFile.Revision;
              DeckVersion := Context.Version;
              if (DeckVersion <> '') and (Pos('-', DeckVersion) <= 1) then
              begin
                LibraryFile.VersionBounds(DeckVersion, Base, Last);
                DeckVersion := '';
              end
              else if Context.Revision <> '' then
                Last := LibraryFile.ParseRevision(Context.Revision);
              LibraryFile.ChangedDecks(0, Last, Values);
              if (DeckVersion <> '') or (Context.FromSnapshot <> '') or (Context.ToSnapshot <> '') then
                for Index := Values.Count - 1 downto 0 do
                  if not (MatchesDeckVersion(Values[Index], DeckVersion) and
                    MatchesDeckVersion(Values[Index], Context.FromSnapshot) and
                    MatchesDeckVersion(Values[Index], Context.ToSnapshot)) then
                    Values.Delete(Index);
              if SameText(Copy(Value, 1, 4), 'scu$') and
                (Values.IndexOf(LibraryFile.LastModifiedDeck) >= 0) then
                AddLibraryValue(LastModifiedDeckSelector);
            end
            else
            begin
              Deck := Context.Deck;
              if (Kind = ckDeckVersion) and (Deck = '') then
                Deck := LibraryFile.LastModifiedDeck;
              if SameText(Deck, LastModifiedDeckSelector) then
              begin
                Deck := LibraryFile.LastModifiedDeck;
                if Deck = '' then
                  Exit;
              end;
              if Kind = ckVersion then
                LibraryFile.ListVersionNames(Values, Deck);
              if Deck <> '' then
              begin
                DeckRevisionCount := LibraryFile.ListDeckRevisions(Deck, Values, Kind = ckRevision,
                  (Kind = ckDeckVersion) or ((Kind = ckVersion) and ((Value = '') or (Pos('-', Value) > 1))));
                if Kind = ckDeckVersion then
                begin
                  if DeckRevisionCount > 0 then
                    AddLibraryValue(CurrentDeckVersionSelector);
                  if DeckRevisionCount > 1 then
                    AddLibraryValue(PreviousDeckVersionSelector);
                end;
              end
              else if Kind = ckRevision then
                for Index := 0 to LibraryFile.Revision do
                  AddLibraryValue(IntToStr(Index));
            end;
          finally
            if not Assigned(PendingLibrary) then
              LibraryFile.Free;
          end;
        end;
    end;

    for Name in Values do
    begin
      if not SameText(Copy(Name, 1, Length(Value)), Value) then
        Continue;
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

procedure CompleteLine(Commands: TCommandDefinitions; const LibraryPath, Before, Prefix, After: string;
  Candidates: TStrings; out AppendCharacter: Char; PendingLibrary: TDeckLibrary);
var
  Tokens, Names, OptionNames: TStringList;
  Spec: TCommandDefinition;
  Earlier: TCommandBinder;
  Hidden: TParameterSlots;
  Index, Slot, Separator: Integer;
  Name: string;
  Current: TCommandToken;

  function WithLaterBindings(Position: Integer): TCommandBinder;
  var
    LaterTokens: TStringList;
    Token: string;
    Tail: TCommandToken;
  begin
    Result := Earlier.WithReservedSlot(Position);
    if (After = '') or (Current.Quote <> #0) then
      Exit;
    try
      LaterTokens := TStringList.Create;
      try
        if TokenizeCommandPrefix(After, LaterTokens, Tail) and
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

  function HiddenNameSlots: TParameterSlots;
  var
    Bindings: TCommandBinder;
    GroupIndex, MemberIndex, OptionSlot, Position, Offset: Integer;
    Selected: Boolean;
  begin
    Bindings := WithLaterBindings(-1);
    try
      Result := nil;
      SetLength(Result, Bindings.Count);
      for Position := 0 to High(Result) do
        Result[Position] := Bindings.Supplied[Position];
      Offset := Bindings.Arguments.Count;
      for GroupIndex := 0 to Spec.ExclusiveGroupCount - 1 do
      begin
        Selected := False;
        for MemberIndex := 0 to Spec.ExclusiveGroupSize[GroupIndex] - 1 do
        begin
          OptionSlot := Spec.ExclusiveOptions[GroupIndex, MemberIndex].OptionIndex;
          if Bindings.Supplied[Offset + OptionSlot] then
          begin
            Selected := True;
            Break;
          end;
        end;
        if Selected then
          for MemberIndex := 0 to Spec.ExclusiveGroupSize[GroupIndex] - 1 do
          begin
            OptionSlot := Spec.ExclusiveOptions[GroupIndex, MemberIndex].OptionIndex;
            Result[Offset + OptionSlot] := True;
          end;
      end;
    finally
      Bindings.Free;
    end;
  end;

  procedure SuggestValue(Position: Integer; const Value: string);
  var
    Bindings: TCommandBinder;
  begin
    Bindings := WithLaterBindings(Position);
    try
      CompleteValue(Commands, Bindings.ParameterAt(Position), CompletionContext(Bindings),
        LibraryPath, Value, Prefix, Current.Quote, False, Candidates, AppendCharacter, PendingLibrary);
    finally
      Bindings.Free;
    end;
  end;

begin
  AppendCharacter := ' ';
  Tokens := TStringList.Create;
  try
    if not TokenizeCommandPrefix(Before + Prefix, Tokens, Current) then
      Exit;
    if Tokens.Count = 0 then
    begin
      if Prefix = Current.Text then
        SuggestNames(Commands, Prefix, '', Candidates, nil, 0, False);
      Exit;
    end;
    Index := Commands.FindIndex(Tokens[0]);
    if Index < 0 then
      Exit;
    Spec := Commands[Index];
    Earlier := TCommandBinder.Create(Spec, bmCompletion);
    try
      for Index := 1 to Tokens.Count - 1 do
        Earlier.Feed(Tokens[Index]);

      if Earlier.PendingAccepts(Current.Text) then
      begin
        SuggestValue(Earlier.PendingSlot, Current.Text);
        Exit;
      end;
      Slot := Earlier.NamedSlot(Current.Text, Separator);
      if (Slot >= 0) and (Separator > 0) then
        SuggestValue(Slot, Copy(Current.Text, Separator + 1, MaxInt))
      else if not Earlier.PositionalOnly and (Copy(Current.Text, 1, 1) = '-') and
        (Current.Text = Prefix) then
      begin
        Hidden := HiddenNameSlots;
        SuggestNames(Earlier.Options, Prefix, '--', Candidates, Hidden, Earlier.Arguments.Count);
      end
      else
      begin
        Names := TStringList.Create;
        OptionNames := nil;
        try
          if not Earlier.PositionalOnly and (Current.Text = Prefix) then
          begin
            Hidden := HiddenNameSlots;
            OptionNames := TStringList.Create;
            SuggestNames(Earlier.Arguments, Prefix, '', Names, Hidden);
            SuggestNames(Earlier.Options, Prefix, '', OptionNames, Hidden, Earlier.Arguments.Count);
            Names.AddStrings(OptionNames);
            Index := Names.IndexOf(Prefix);
            if Index >= 0 then
            begin
              Candidates.Add(Names[Index]);
              AppendCharacter := '=';
              Exit;
            end;
          end;
          Slot := Earlier.NextPositional;
          if Slot >= 0 then
            SuggestValue(Slot, Current.Text);
          if Candidates.Count = 0 then
          begin
            Candidates.AddStrings(Names);
            AppendCharacter := '=';
          end
          else
            for Name in Names do
              Candidates.Add(Name + '=');
        finally
          OptionNames.Free;
          Names.Free;
        end;
      end;
    finally
      Earlier.Free;
    end;
  finally
    Tokens.Free;
  end;
end;

end.
