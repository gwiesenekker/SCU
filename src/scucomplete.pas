unit ScuComplete;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, ScuLibrary;

type
  TCompletionContext = record
    Deck, Version, Revision, FromSnapshot, ToSnapshot: string;
  end;

procedure RecordCompletionValue(var Context: TCompletionContext; const Name, Value: string);
procedure CompleteLine(Commands: TJSONArray; const LibraryPath, Before, Prefix, After: string;
  Candidates: TStrings; out AppendCharacter: Char; PendingLibrary: TDeckLibrary = nil);
procedure CompleteValue(Commands: TJSONArray; Parameter: TJSONObject;
  const Context: TCompletionContext; const LibraryPath, Value, Prefix: string; Quote: Char; RawValue: Boolean;
  Candidates: TStrings; out AppendCharacter: Char; PendingLibrary: TDeckLibrary = nil);

implementation

uses
  SysUtils, ScuCommands, ScuInput, ScuIO, ScuJSON;

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

type
  TParameterSlots = array of Boolean;

procedure SuggestNames(Entries: TJSONArray; const Prefix, Leader: string; Candidates: TStrings;
  const Supplied: TParameterSlots = nil; Offset: Integer = 0; PreferExact: Boolean = True);
var
  Index, AliasIndex: Integer;
  Entry: TJSONObject;
  Aliases: TJSONArray;
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
    Entry := DefinitionAt(Entries, Index);
    Suggest(DefinitionName(Entry));
    Aliases := DefinitionAliases(Entry);
    if Assigned(Aliases) then
      for AliasIndex := 0 to Aliases.Count - 1 do
        Suggest(Aliases.Strings[AliasIndex]);
  end;
  if Exact <> '' then
  begin
    Candidates.Clear;
    Candidates.Add(Exact);
  end;
end;

function EscapeSuffix(const Suffix: string; Quote: Char): string;
var
  Character: Char;
begin
  Result := '';
  for Character in Suffix do
  begin
    if (Quote = #39) and (Character = #39) then
      Result := Result + #39 + '\' + #39 + #39
    else
    begin
      if ((Quote = #0) and (Character in [' ', #9, '\', '"', #39])) or
        ((Quote = '"') and (Character in ['\', '"'])) then
        Result := Result + '\';
      Result := Result + Character;
    end;
  end;
end;

procedure CompleteValue(Commands: TJSONArray; Parameter: TJSONObject;
  const Context: TCompletionContext; const LibraryPath, Value, Prefix: string; Quote: Char; RawValue: Boolean;
  Candidates: TStrings; out AppendCharacter: Char; PendingLibrary: TDeckLibrary);
var
  KindField: TJSONData;
  Kind, Directory, SearchDirectory, Leaf, Name, Suffix, Deck, DeckVersion: string;
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
  KindField := Parameter.Find('completion');
  if Assigned(KindField) then
    Kind := KindField.AsString
  else if Field(Parameter, 'type', jtString).AsString = 'boolean' then
    Kind := 'boolean'
  else
    Exit;

  Values := TStringList.Create;
  try
    Values.CaseSensitive := True;
    Values.Sorted := True;
    Values.Duplicates := dupIgnore;
    case Kind of
      'boolean':
        begin
          Values.Add('no');
          Values.Add('yes');
        end;
      'command': SuggestNames(Commands, Value, '', Values, nil, 0, False);
      'file', 'directory':
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
              else if (Kind = 'file') and FileExists(Name) then
                Values.Add(Directory + Search.Name);
            until FindNext(Search) <> 0;
          finally
            FindClose(Search);
          end;
        end;
      'deck', 'version', 'revision', 'deck_version':
        begin
          LibraryFile := PendingLibrary;
          if not Assigned(LibraryFile) then
          begin
            if not RegularFileExists(LibraryPath) then
              Exit;
            LibraryFile := TDeckLibrary.Create(LibraryPath);
          end;
          try
            if Kind = 'deck' then
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
              if (Kind = 'deck_version') and (Deck = '') then
                Deck := LibraryFile.LastModifiedDeck;
              if SameText(Deck, LastModifiedDeckSelector) then
              begin
                Deck := LibraryFile.LastModifiedDeck;
                if Deck = '' then
                  Exit;
              end;
              if Kind = 'version' then
                LibraryFile.ListVersionNames(Values, Deck);
              if Deck <> '' then
              begin
                DeckRevisionCount := LibraryFile.ListDeckRevisions(Deck, Values, Kind = 'revision',
                  (Kind = 'deck_version') or ((Kind = 'version') and ((Value = '') or (Pos('-', Value) > 1))));
                if Kind = 'deck_version' then
                begin
                  if DeckRevisionCount > 0 then
                    AddLibraryValue(CurrentDeckVersionSelector);
                  if DeckRevisionCount > 1 then
                    AddLibraryValue(PreviousDeckVersionSelector);
                end;
              end
              else if Kind = 'revision' then
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
    if (Candidates.Count = 1) and ((Kind = 'file') or (Kind = 'directory')) then
    begin
      Name := Values[0];
      if Name[Length(Name)] = DirectorySeparator then
        AppendCharacter := #0;
    end;
  finally
    Values.Free;
  end;
end;

procedure CompleteLine(Commands: TJSONArray; const LibraryPath, Before, Prefix, After: string;
  Candidates: TStrings; out AppendCharacter: Char; PendingLibrary: TDeckLibrary);
type
  TBindings = record
    Supplied: TParameterSlots;
    Context: TCompletionContext;
    Pending: Integer;
    PositionalOnly, ConsumeNamed: Boolean;
  end;
var
  Tokens, Names, OptionNames: TStringList;
  Arguments, Options: TJSONArray;
  Spec: TJSONObject;
  Earlier: TBindings;
  Hidden: TParameterSlots;
  Index, Slot, Separator: Integer;
  Current, Name: string;
  Quote: Char;

  function ParameterAt(Position: Integer): TJSONObject;
  begin
    if Position < Arguments.Count then
      Result := DefinitionAt(Arguments, Position)
    else
      Result := DefinitionAt(Options, Position - Arguments.Count);
  end;

  function BoundPosition(const Spelling: string; PositionalOnly: Boolean;
    out EqualsAt: Integer): Integer;
  var
    OptionSlot: Integer;
    Key: string;
  begin
    Result := -1;
    EqualsAt := 0;
    if PositionalOnly then
      Exit;
    if Copy(Spelling, 1, 2) = '--' then
    begin
      EqualsAt := Pos('=', Spelling);
      Key := Copy(Spelling, 3, MaxInt);
      if EqualsAt > 0 then
        Key := Copy(Spelling, 3, EqualsAt - 3);
      OptionSlot := FindDefinition(Options, Key);
    end
    else
    begin
      EqualsAt := Pos('=', Spelling);
      if EqualsAt <= 1 then
        Exit;
      Key := Copy(Spelling, 1, EqualsAt - 1);
      Result := FindDefinition(Arguments, Key);
      if Result >= 0 then
        Exit;
      OptionSlot := FindDefinition(Options, Key);
    end;
    if OptionSlot >= 0 then
      Result := Arguments.Count + OptionSlot;
  end;

  function NextPosition(const Bindings: TBindings): Integer;
  begin
    Result := 0;
    while (Result < Arguments.Count) and Bindings.Supplied[Result] do
      Inc(Result);
  end;

  procedure RecordValue(var Bindings: TBindings; Position: Integer; const Value: string);
  begin
    Bindings.Supplied[Position] := True;
    RecordCompletionValue(Bindings.Context, DefinitionName(ParameterAt(Position)), Value);
  end;

  procedure ReadBinding(var Bindings: TBindings; const Spelling: string);
  var
    Position, Waiting, EqualsAt: Integer;
  begin
    Position := BoundPosition(Spelling, Bindings.PositionalOnly, EqualsAt);
    if Bindings.Pending >= 0 then
    begin
      Waiting := Bindings.Pending;
      Bindings.Pending := -1;
      if Bindings.ConsumeNamed or ((Position < 0) and (Spelling <> '--')) then
      begin
        RecordValue(Bindings, Waiting, Spelling);
        Exit;
      end;
    end;
    if (Spelling = '--') and not Bindings.PositionalOnly then
      Bindings.PositionalOnly := True
    else if Position >= 0 then
    begin
      if (EqualsAt = 0) or (EqualsAt = Length(Spelling)) then
      begin
        Bindings.Pending := Position;
        Bindings.ConsumeNamed := (EqualsAt = 0) and not ParameterRequired(ParameterAt(Position), False);
      end
      else
        RecordValue(Bindings, Position, Copy(Spelling, EqualsAt + 1, MaxInt));
    end
    else
    begin
      Position := NextPosition(Bindings);
      if Position < Arguments.Count then
        RecordValue(Bindings, Position, Spelling);
    end;
  end;

  function WithLaterBindings(Position: Integer): TBindings;
  var
    LaterTokens: TStringList;
    Tail, LaterToken: string;
    TailQuote: Char;
  begin
    Result := Earlier;
    if (After = '') or (Quote <> #0) then
      Exit;
    Result.Supplied := Copy(Earlier.Supplied);
    Result.Pending := -1;
    if Position >= 0 then
      Result.Supplied[Position] := True;
    LaterTokens := TStringList.Create;
    try
      if TokenizeCommandPrefix(After, LaterTokens, Tail, TailQuote) and
        (TailQuote = #0) and (Tail <> '') then
        LaterTokens.Add(Tail);
      for LaterToken in LaterTokens do
        ReadBinding(Result, LaterToken);
    finally
      LaterTokens.Free;
    end;
  end;

  function HiddenNameSlots: TParameterSlots;
  var
    Bindings: TBindings;
    Groups, Group: TJSONArray;
    GroupIndex, MemberIndex, OptionSlot: Integer;
    Selected: Boolean;
  begin
    Bindings := WithLaterBindings(-1);
    Result := Bindings.Supplied;
    Groups := ExclusiveOptionGroups(Spec);
    if not Assigned(Groups) then
      Exit;
    Result := Copy(Bindings.Supplied);
    for GroupIndex := 0 to Groups.Count - 1 do
    begin
      Group := TJSONArray(Groups.Items[GroupIndex]);
      Selected := False;
      for MemberIndex := 0 to Group.Count - 1 do
      begin
        OptionSlot := FindDefinition(Options, Group.Items[MemberIndex].AsString);
        if (OptionSlot >= 0) and Bindings.Supplied[Arguments.Count + OptionSlot] then
        begin
          Selected := True;
          Break;
        end;
      end;
      if Selected then
        for MemberIndex := 0 to Group.Count - 1 do
        begin
          OptionSlot := FindDefinition(Options, Group.Items[MemberIndex].AsString);
          if OptionSlot >= 0 then
            Result[Arguments.Count + OptionSlot] := True;
        end;
    end;
  end;

  procedure SuggestValue(Position: Integer; const Value: string);
  var
    Bindings: TBindings;
  begin
    Bindings := WithLaterBindings(Position);
    CompleteValue(Commands, ParameterAt(Position), Bindings.Context, LibraryPath, Value,
      Prefix, Quote, False, Candidates, AppendCharacter, PendingLibrary);
  end;

begin
  AppendCharacter := ' ';
  Tokens := TStringList.Create;
  try
    if not TokenizeCommandPrefix(Before + Prefix, Tokens, Current, Quote) then
      Exit;
    if Tokens.Count = 0 then
    begin
      if Prefix = Current then
        SuggestNames(Commands, Prefix, '', Candidates, nil, 0, False);
      Exit;
    end;
    Index := FindDefinition(Commands, Tokens[0]);
    if Index < 0 then
      Exit;
    Spec := DefinitionAt(Commands, Index);
    Arguments := TJSONArray(Field(Spec, 'arguments', jtArray));
    Options := TJSONArray(Field(Spec, 'options', jtArray));
    SetLength(Earlier.Supplied, Arguments.Count + Options.Count);
    Earlier.PositionalOnly := False;
    Earlier.Pending := -1;
    Earlier.ConsumeNamed := False;
    for Index := 1 to Tokens.Count - 1 do
      ReadBinding(Earlier, Tokens[Index]);

    Slot := BoundPosition(Current, Earlier.PositionalOnly, Separator);
    if (Earlier.Pending >= 0) and (Earlier.ConsumeNamed or ((Slot < 0) and (Current <> '--'))) then
      SuggestValue(Earlier.Pending, Current)
    else if (Slot >= 0) and (Separator > 0) then
      SuggestValue(Slot, Copy(Current, Separator + 1, MaxInt))
    else if not Earlier.PositionalOnly and (Copy(Current, 1, 1) = '-') and (Current = Prefix) then
    begin
      Hidden := HiddenNameSlots;
      SuggestNames(Options, Prefix, '--', Candidates, Hidden, Arguments.Count);
    end
    else
    begin
      Names := TStringList.Create;
      OptionNames := nil;
      try
        if not Earlier.PositionalOnly and (Current = Prefix) then
        begin
          Hidden := HiddenNameSlots;
          OptionNames := TStringList.Create;
          SuggestNames(Arguments, Prefix, '', Names, Hidden);
          SuggestNames(Options, Prefix, '', OptionNames, Hidden, Arguments.Count);
          Names.AddStrings(OptionNames);
          Index := Names.IndexOf(Prefix);
          if Index >= 0 then
          begin
            Candidates.Add(Names[Index]);
            AppendCharacter := '=';
            Exit;
          end;
        end;
        Slot := NextPosition(Earlier);
        if Slot < Arguments.Count then
          SuggestValue(Slot, Current);
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
    Tokens.Free;
  end;
end;

end.
