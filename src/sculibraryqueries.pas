unit ScuLibraryQueries;

{$mode objfpc}{$H+}

interface

uses Classes, ScuLibraryTypes, ScuLibraryStore, ScuSQLite, ScuVersions;

type
  // The owner retains the store. Queries return values and never change payloads.
  TLibraryQueries = class
  strict private
    FStore: TLibraryStore;
    function GetRevision: Integer;
    function Versions: TVersionHistory;
  public
    constructor Create(Store: TLibraryStore);
    function FindDeckRevision(const Name: string; LastRevision: Integer): Integer;
    function RevisionDeletedAt(Sequence: Integer): Boolean;
    function DeckList(LibraryRevision: Integer): TDeckListEntries;
    function VersionDecks(Database: TSQLiteLibrary; const Version: string): TVersionDeckEntries;
    function DeckHistory(Database: TSQLiteLibrary; const Deck: string; Limit: Int64): TDeckHistoryEntries;
    procedure ChangedDecks(Base, Last: Integer; Dest: TStrings);
    function ListDeckRevisions(const Deck: string; Dest: TStrings; Formats: TDeckRevisionFormats): Integer;
    procedure VersionBounds(const Name: string; out Base, Last: Integer);
    procedure ListVersionNames(Dest: TStrings; const Deck: string);
    function SelectDeck(const Deck, Version, DeckRevision: string): TDeckSelection;
    procedure ListDeckRevisionNames(const Deck, Version: string; Dest: TStrings);
    function CurrentSnapshot: TLibrarySnapshot;
    function DeckVersionAt(Revision: Integer): string;
    function DeckRevisionAt(Revision: Integer): string;
    function ParseLibrarySnapshot(const Selector: string): TLibrarySnapshot;
    function TryDeckSnapshot(const Deck: string; LibraryRevision: Integer;
  out Snapshot: TLibrarySnapshot): Boolean;
    function ParseDeckSnapshot(const Name, Selector: string): TLibrarySnapshot;
    function TryPreviousSnapshot(out Snapshot: TLibrarySnapshot): Boolean;
    function PreviousDeckSnapshot(const Name: string; AtRevision: Integer): TLibrarySnapshot;
    function CurrentVersion: string;
    function VersionAt(Revision: Integer): string;
    function DefaultCommentPrefix(const Version: string): string;
    property Revision: Integer read GetRevision;
  end;

implementation

uses SysUtils, FGL, ScuLibraryModel, ScuErrors, ScuSignals, ScuVersionNumbers;

constructor TLibraryQueries.Create(Store: TLibraryStore);
begin
  inherited Create;
  FStore := Store;
end;

function TLibraryQueries.GetRevision: Integer;
begin
  Result := FStore.Count;
end;

function TLibraryQueries.Versions: TVersionHistory;
begin
  Result := FStore.Header.Versions;
end;

function TLibraryQueries.FindDeckRevision(const Name: string; LastRevision: Integer): Integer;
begin
  for Result := LastRevision downto 1 do
    if FStore[Result - 1].Name = Name then
      Exit;
  Result := 0;
end;


function TLibraryQueries.RevisionDeletedAt(Sequence: Integer): Boolean;
begin
  Result := FStore[Sequence - 1].Deleted;
end;


function TLibraryQueries.DeckList(LibraryRevision: Integer): TDeckListEntries;
var
  Seen: TStringList;
  Index, Count, StoredIndex: Integer;
  Name: string;
begin
  Result := nil;
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.CaseSensitive := True;
    for Index := LibraryRevision - 1 downto 0 do
    begin
      Name := FStore[Index].Name;
      if Seen.IndexOf(Name) >= 0 then
        Continue;
      // Objects holds revision indices only; Seen does not own objects.
      Seen.AddObject(Name, TObject(PtrInt(Index)));
    end;
    SetLength(Result, Seen.Count);
    Count := 0;
    for Index := 0 to Seen.Count - 1 do
    begin
      StoredIndex := PtrInt(Seen.Objects[Index]);
      if FStore[StoredIndex].Deleted then
        Continue;
      Result[Count].Name := Seen[Index];
      Result[Count].Sequence := StoredIndex + 1;
      Result[Count].DeckVersion := DeckVersionAt(StoredIndex + 1);
      Inc(Count);
    end;
    SetLength(Result, Count);
  finally
    Seen.Free;
  end;
end;


function TLibraryQueries.VersionDecks(Database: TSQLiteLibrary; const Version: string): TVersionDeckEntries;
type
  TDeckIndex = specialize TFPGMap<string, Integer>;
var
  Decks: TDeckIndex;
  Base, Last, Index, StoredIndex, Slot, Remaining: Integer;
  PriorSequences: array of Integer;
  PreviousVersion: string;
  Entry, Prior: TLibraryRevision;
begin
  Result := nil;
  VersionBounds(Version, Base, Last);
  Decks := TDeckIndex.Create;
  try
    Decks.Sorted := True;
    for Index := Last - 1 downto Base do
    begin
      CheckSessionInterrupt;
      Entry := FStore[Index];
      if Decks.IndexOf(Entry.Name) < 0 then
        Decks.Add(Entry.Name, Index);
    end;
    if Decks.Count = 0 then Exit;
    PreviousVersion := Versions.PredecessorName(Version);
    SetLength(PriorSequences, Decks.Count);
    Remaining := Decks.Count;
    // Resolve the visible predecessor of every listed deck in one backward pass.
    for Index := Base - 1 downto 0 do
    begin
      CheckSessionInterrupt;
      Slot := Decks.IndexOf(FStore[Index].Name);
      if (Slot < 0) or (PriorSequences[Slot] <> 0) then Continue;
      PriorSequences[Slot] := Index + 1;
      Dec(Remaining);
      if Remaining = 0 then Break;
    end;
    SetLength(Result, Decks.Count);
    for Index := 0 to Decks.Count - 1 do
    begin
      CheckSessionInterrupt;
      StoredIndex := Decks.Data[Index];
      Entry := FStore.PayloadAt(StoredIndex, Database);
      Result[Index].Name := Entry.Name;
      Result[Index].DeckVersion := DeckVersionAt(StoredIndex + 1);
      Result[Index].ModifiedUTC := Entry.ModifiedUTC;
      Result[Index].Deleted := Entry.Deleted;
      if Entry.Deleted or (PriorSequences[Index] = 0) then Continue;
      StoredIndex := PriorSequences[Index] - 1;
      if FStore[StoredIndex].Deleted then Continue;
      Prior := FStore.PayloadAt(StoredIndex, Database);
      if (Entry.SHA1 = Prior.SHA1) and (Entry.Decode = Prior.Decode) then
        Result[Index].MatchingVersion := PreviousVersion;
    end;
  finally
    Decks.Free;
  end;
end;


function TLibraryQueries.DeckHistory(Database: TSQLiteLibrary; const Deck: string; Limit: Int64): TDeckHistoryEntries;
var
  Name: string;
  Index, Count: Integer;
  Entry: TLibraryRevision;
begin
  Name := DeckName(Deck);
  Count := 0;
  for Index := 0 to Revision - 1 do
    if FStore[Index].Name = Name then
      Inc(Count);
  if Count = 0 then
    raise EScuError.CreateFmt('Deck "%s" does not exist.', [Name]);
  if (Limit > 0) and (Limit < Count) then
    Count := Integer(Limit);
  Result := nil;
  SetLength(Result, Count);
  Count := 0;
  for Index := Revision - 1 downto 0 do
  begin
    Entry := FStore[Index];
    if Entry.Name = Name then
    begin
      Result[Count].DeckVersion := DeckVersionAt(Index + 1);
      Result[Count].ModifiedUTC := FStore.PayloadAt(Index, Database).ModifiedUTC;
      Result[Count].Deleted := Entry.Deleted;
      Inc(Count);
      if Count = Length(Result) then
        Break;
    end;
  end;
end;


procedure TLibraryQueries.ChangedDecks(Base, Last: Integer; Dest: TStrings);
var
  Index: Integer;
begin
  for Index := Base to Last - 1 do
    Dest.Add(FStore[Index].Name);
end;


function TLibraryQueries.ListDeckRevisions(const Deck: string; Dest: TStrings; Formats: TDeckRevisionFormats): Integer;
var
  Name: string;
  Index: Integer;
begin
  Name := DeckName(Deck);
  Result := 0;
  for Index := 0 to Revision - 1 do
    if FStore[Index].Name = Name then
    begin
      Inc(Result);
      if drLibraryRevision in Formats then
        Dest.Add(IntToStr(Index + 1));
      if drDeckVersion in Formats then
        Dest.Add(DeckVersionAt(Index + 1));
    end;
end;


procedure TLibraryQueries.VersionBounds(const Name: string; out Base, Last: Integer);
begin
  Versions.Bounds(Name, Revision, Base, Last);
end;



procedure TLibraryQueries.ListVersionNames(Dest: TStrings; const Deck: string);
var
  Name: string;
  Index, Base, Last, Found: Integer;
begin
  if Deck = '' then
  begin
    Versions.ListNames(Revision, 0, Dest);
    Exit;
  end;
  Name := DeckName(Deck);
  for Index := 0 to Versions.Count - 1 do
  begin
    Versions.Bounds(Versions.Entries[Index].Name, Revision, Base, Last);
    Found := FindDeckRevision(Name, Last);
    if (Found > 0) and not RevisionDeletedAt(Found) then
      Dest.Add(Versions.Entries[Index].Name);
  end;
end;


function TLibraryQueries.SelectDeck(const Deck, Version, DeckRevision: string): TDeckSelection;
var
  Name, SelectedVersion: string;
  Stored: TLibrarySnapshot;
  Number: Int64;
begin
  Name := DeckName(Deck);
  SelectedVersion := Version;
  if SelectedVersion = '' then
    SelectedVersion := CurrentVersionSelector;
  if Pos('-', SelectedVersion) > 0 then
  begin
    if DeckRevision <> '' then
      raise EScuError.Create('Use a library version with revision, or a complete deck version without revision.');
    Stored := ParseDeckSnapshot(Name, SelectedVersion);
    Result.Snapshot := ParseLibrarySnapshot(Stored.Version);
    Result.RootRevision := Stored.LibraryRevision;
  end
  else
  begin
    Result.Snapshot := ParseLibrarySnapshot(SelectedVersion);
    if DeckRevision = '' then
      Result.RootRevision := FindDeckRevision(Name, Result.Snapshot.LibraryRevision)
    else
    begin
      if not TryParseFixed(DeckRevision, 3, Number) or (Number > MaxDeckRevision) then
        raise EScuError.Create('Expected a deck revision from 0.000 to 0.999.');
      Stored := ParseDeckSnapshot(Name, Result.Snapshot.Version + '-' + FormatFixed(Number, 3));
      Result.RootRevision := Stored.LibraryRevision;
    end;
  end;
  if ((DeckRevision <> '') or (Pos('-', SelectedVersion) > 0)) and
    RevisionDeletedAt(Result.RootRevision) then
    raise EScuError.CreateFmt('Deck "%s" is deleted at deck version %s.',
      [Name, DeckVersionAt(Result.RootRevision)]);
end;


procedure TLibraryQueries.ListDeckRevisionNames(const Deck, Version: string; Dest: TStrings);
var
  Name, SelectedVersion: string;
  Snapshot: TLibrarySnapshot;
  Base, Last, Index, Separator: Integer;
begin
  Name := DeckName(Deck);
  SelectedVersion := Version;
  if SelectedVersion = '' then
    SelectedVersion := CurrentVersionSelector;
  Separator := Pos('-', SelectedVersion);
  if Separator > 0 then
    SelectedVersion := Copy(SelectedVersion, 1, Separator - 1);
  Snapshot := ParseLibrarySnapshot(SelectedVersion);
  VersionBounds(Snapshot.Version, Base, Last);
  for Index := Base to Last - 1 do
    if (FStore[Index].Name = Name) and not FStore[Index].Deleted then
      Dest.Add(DeckRevisionAt(Index + 1));
end;


function TLibraryQueries.CurrentSnapshot: TLibrarySnapshot;
begin
  Result.Version := CurrentVersion;
  Result.LibraryRevision := Revision;
end;


function TLibraryQueries.DeckVersionAt(Revision: Integer): string;
begin
  Result := VersionAt(Revision) + '-' + DeckRevisionAt(Revision);
end;


function TLibraryQueries.DeckRevisionAt(Revision: Integer): string;
begin
  Result := FormatFixed(FStore[Revision - 1].Number, 3);
end;


function TLibraryQueries.ParseLibrarySnapshot(const Selector: string): TLibrarySnapshot;
var
  Base: Integer;
begin
  if SameText(Selector, CurrentVersionSelector) then
    Exit(CurrentSnapshot);
  if SameText(Selector, PreviousVersionSelector) then
  begin
    if not TryPreviousSnapshot(Result) then
      raise EScuError.CreateFmt('No locked version precedes current version %s.', [CurrentVersion]);
    Exit;
  end;
  VersionBounds(Selector, Base, Result.LibraryRevision);
  Result.Version := Selector;
end;


function TLibraryQueries.TryDeckSnapshot(const Deck: string; LibraryRevision: Integer;
  out Snapshot: TLibrarySnapshot): Boolean;
begin
  Snapshot := Default(TLibrarySnapshot);
  Snapshot.LibraryRevision := FindDeckRevision(DeckName(Deck), LibraryRevision);
  Result := (Snapshot.LibraryRevision <> 0) and not RevisionDeletedAt(Snapshot.LibraryRevision);
  if Result then
    Snapshot.Version := VersionAt(Snapshot.LibraryRevision)
  else
    Snapshot := Default(TLibrarySnapshot);
end;


function TLibraryQueries.ParseDeckSnapshot(const Name, Selector: string): TLibrarySnapshot;
var
  Separator, Base, Last, Index: Integer;
  Number: Int64;
begin
  if SameText(Selector, PreviousDeckVersionSelector) then
    Exit(PreviousDeckSnapshot(Name, Revision));
  if SameText(Selector, CurrentDeckVersionSelector) then
  begin
    Result.LibraryRevision := FindDeckRevision(Name, Revision);
    if Result.LibraryRevision = 0 then
      raise EScuError.CreateFmt('Deck "%s" does not exist in version %s.', [Name, CurrentVersion]);
    Result.Version := VersionAt(Result.LibraryRevision);
    Exit;
  end;
  Separator := Pos('-', Selector);
  if (Separator <= 1) or not TryParseFixed(Copy(Selector, Separator + 1, MaxInt), 3, Number) then
    raise EScuError.CreateFmt('Invalid deck version "%s". Expected VERSION-REVISION, %s, or %s.',
      [Selector, CurrentDeckVersionSelector, PreviousDeckVersionSelector]);
  Result.Version := Copy(Selector, 1, Separator - 1);
  VersionBounds(Result.Version, Base, Last);
  for Index := Last downto Base + 1 do
    if (FStore[Index - 1].Number = Number) and
      (FStore[Index - 1].Name = Name) then
    begin
      Result.LibraryRevision := Index;
      Exit;
    end;
  raise EScuError.CreateFmt('Deck "%s" has no deck version "%s".', [Name, Selector]);
end;


function TLibraryQueries.TryPreviousSnapshot(out Snapshot: TLibrarySnapshot): Boolean;
begin
  Result := Versions.TryPrevious(Snapshot.Version, Snapshot.LibraryRevision);
end;


function TLibraryQueries.PreviousDeckSnapshot(const Name: string; AtRevision: Integer): TLibrarySnapshot;
var
  StoredRevision: Integer;
begin
  StoredRevision := FindDeckRevision(Name, AtRevision);
  if StoredRevision = 0 then
    raise EScuError.CreateFmt('Deck "%s" does not exist in version %s.', [Name, VersionAt(AtRevision)]);
  Result.LibraryRevision := FindDeckRevision(Name, StoredRevision - 1);
  if Result.LibraryRevision = 0 then
    raise EScuError.CreateFmt('Deck "%s" has no earlier revision to compare with. Store an edit before comparing.', [Name]);
  Result.Version := VersionAt(Result.LibraryRevision);
end;


function TLibraryQueries.CurrentVersion: string;
begin
  Result := Versions.Current;
end;


function TLibraryQueries.VersionAt(Revision: Integer): string;
begin
  Result := Versions.AtRevision(Revision);
end;


function TLibraryQueries.DefaultCommentPrefix(const Version: string): string;
begin
  Result := Versions.CommentPrefix(Version);
end;


end.
