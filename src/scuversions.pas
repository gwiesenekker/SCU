unit ScuVersions;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON;

type
  TVersionEntry = record
    Name, CommentPrefix, LockedUTC, Description: string;
    BaseRevision: Integer;
    Locked: Boolean;
  end;

  TVersionHistory = class
  private
    FEntries: array of TVersionEntry;
    FSerialized: TJSONArray; // Borrowed from the header that owns the original JSON.
    function Entry(Index: Integer): TJSONObject;
    function GetCurrent: string;
    function GetLocked: Boolean;
    function GetCount: Integer;
    function GetEntry(Index: Integer): TVersionEntry;
    function BaseRevision(Index: Integer): Integer;
    function EndRevision(Index, Latest: Integer): Integer;
    function IndexOf(const Name: string): Integer;
  public
    constructor Create(Entries: TJSONArray; Latest: Integer);
    procedure Lock(const Description: string);
    procedure DeleteEmpty(const Name: string; Latest: Integer);
    procedure Start(const Name, Prefix: string; Latest: Integer);
    function NextVersion(Increment: Int64): string;
    function CommentPrefix(const Name: string): string;
    procedure SetCommentPrefix(const Prefix: string; Latest: Integer);
    procedure Bounds(const Name: string; Latest: Integer; out Base, Last: Integer);
    procedure ListNames(Latest, MinimumRevision: Integer; Dest: TStrings);
    function AtRevision(Revision: Integer): string;
    function TryPrevious(out Name: string; out Last: Integer): Boolean;
    property Count: Integer read GetCount;
    property Entries[Index: Integer]: TVersionEntry read GetEntry;
    property Current: string read GetCurrent;
    property Locked: Boolean read GetLocked;
  end;

procedure ValidateCommentPrefix(const Prefix: string);

implementation

uses
  SysUtils, DateUtils, ScuClock, ScuErrors, ScuJSON, ScuVersionNumbers;

procedure ValidateCommentPrefix(const Prefix: string);
var
  Value: Char;
begin
  if (Prefix = '') or (Length(Prefix) > 16) or (Trim(Prefix) <> Prefix) then
    raise EScuError.Create('Expected a nonempty comment prefix of at most 16 bytes.');
  for Value in Prefix do
    if Value < #32 then
      raise EScuError.Create('The comment prefix must be printable and on one line.');
end;

procedure ParseVersion(const Name: string; out Major: Integer; out Minor: Int64);
var
  Dot, Index: SizeInt;
  MinorText: string;
  Valid: Boolean;
begin
  Dot := Pos('.', Name);
  MinorText := Copy(Name, Dot + 1, MaxInt);
  Valid := (Length(MinorText) > 0) and (Length(MinorText) <= 10);
  for Index := 1 to Length(MinorText) do
    Valid := Valid and (MinorText[Index] in ['0'..'9']);
  if (Dot <= 1) or not TryStrToInt(Copy(Name, 1, Dot - 1), Major) or
    not Valid or not TryStrToInt64(MinorText, Minor) or (Major < 0) or
    (Copy(Name, 1, Dot - 1) <> IntToStr(Major)) then
    raise EScuError.CreateFmt('Invalid version "%s". Expected MAJOR.MINOR.', [Name]);
end;

function LaterVersion(const Name, Previous: string; Legacy: Boolean = False): Boolean;
var
  Major, PreviousMajor: Integer;
  Minor, PreviousMinor: Int64;
  Fraction, PreviousFraction: string;
begin
  ParseVersion(Name, Major, Minor);
  ParseVersion(Previous, PreviousMajor, PreviousMinor);
  if Major <> PreviousMajor then
    Exit(Major > PreviousMajor);
  if Legacy then
    Exit(Minor > PreviousMinor);
  Fraction := Copy(Name, Pos('.', Name) + 1, MaxInt);
  PreviousFraction := Copy(Previous, Pos('.', Previous) + 1, MaxInt);
  while (Fraction <> '') and (Fraction[Length(Fraction)] = '0') do
    SetLength(Fraction, Length(Fraction) - 1);
  while (PreviousFraction <> '') and (PreviousFraction[Length(PreviousFraction)] = '0') do
    SetLength(PreviousFraction, Length(PreviousFraction) - 1);
  Result := CompareStr(Fraction, PreviousFraction) > 0;
end;

constructor TVersionHistory.Create(Entries: TJSONArray; Latest: Integer);
var
  Index, Base, PreviousBase, Major: Integer;
  StoredBase: Int64;
  Item: TJSONObject;
  Minor: Int64;
  Name, PreviousName: string;
  IsLocked: Boolean;
  Stamp: TDateTime;
  Context: string;
begin
  inherited Create;
  FSerialized := Entries;
  SetLength(FEntries, Entries.Count);
  PreviousBase := 0;
  PreviousName := '';
  for Index := 0 to Length(FEntries) - 1 do
  begin
    Item := Entry(Index);
    Name := Field(Item, 'name', jtString).AsString;
    ParseVersion(Name, Major, Minor);
    FEntries[Index].CommentPrefix := Field(Item, 'comment_prefix', jtString).AsString;
    ValidateCommentPrefix(FEntries[Index].CommentPrefix);
    StoredBase := IntegerField(Item, 'base_revision');
    if (StoredBase < 0) or (StoredBase > High(Integer)) then
      raise EScuError.Create('Invalid version base revision.');
    Base := StoredBase;
    IsLocked := Field(Item, 'locked', jtBoolean).AsBoolean;
    FEntries[Index].Name := Name;
    FEntries[Index].BaseRevision := Base;
    FEntries[Index].Locked := IsLocked;
    Context := 'Version "' + Name + '"';
    if Assigned(Item.Find('locked_utc')) then
    begin
      FEntries[Index].LockedUTC := Field(Item, 'locked_utc', jtString, Context).AsString;
      if not IsLocked or not TryISO8601ToDate(FEntries[Index].LockedUTC, Stamp) or
        (UtcTimestamp(Stamp) <> FEntries[Index].LockedUTC) then
        raise EScuError.CreateFmt('Invalid lock timestamp for version "%s".', [Name]);
    end;
    if Assigned(Item.Find('description')) then
      FEntries[Index].Description := Field(Item, 'description', jtString, Context).AsString;
    if (Base > Latest) or (Base < PreviousBase) or ((Index = 0) and (Base <> 0)) or
      ((Index < Length(FEntries) - 1) and not IsLocked) or
      ((Index > 0) and not (LaterVersion(Name, PreviousName) or LaterVersion(Name, PreviousName, True))) then
      raise EScuError.Create('Invalid version history.');
    PreviousBase := Base;
    PreviousName := Name;
  end;
end;

function TVersionHistory.Entry(Index: Integer): TJSONObject;
begin
  if not (FSerialized.Items[Index] is TJSONObject) then
    raise EScuError.Create('Invalid version history entry.');
  Result := TJSONObject(FSerialized.Items[Index]);
end;

function TVersionHistory.GetCurrent: string;
begin
  Result := FEntries[Length(FEntries) - 1].Name;
end;

function TVersionHistory.GetLocked: Boolean;
begin
  Result := FEntries[Length(FEntries) - 1].Locked;
end;

function TVersionHistory.BaseRevision(Index: Integer): Integer;
begin
  Result := FEntries[Index].BaseRevision;
end;

function TVersionHistory.EndRevision(Index, Latest: Integer): Integer;
begin
  if Index < Length(FEntries) - 1 then
    Result := BaseRevision(Index + 1)
  else
    Result := Latest;
end;

function TVersionHistory.TryPrevious(out Name: string; out Last: Integer): Boolean;
begin
  Result := Length(FEntries) > 1;
  if not Result then
    Exit;
  // Every version before the current one is locked.
  Name := FEntries[Length(FEntries) - 2].Name;
  Last := BaseRevision(Length(FEntries) - 1);
end;

function TVersionHistory.GetCount: Integer;
begin
  Result := Length(FEntries);
end;

function TVersionHistory.GetEntry(Index: Integer): TVersionEntry;
begin
  Result := FEntries[Index];
end;

procedure TVersionHistory.Lock(const Description: string);
var
  Index: Integer;
  LockedUTC: string;
  Item: TJSONObject;
begin
  if Locked then
    raise EScuError.CreateFmt('Version %s is already locked.', [Current]);
  if Trim(Description) = '' then
    raise EScuError.Create('A nonempty version description is required.');
  LockedUTC := UtcTimestamp(UtcNow);
  Index := High(FEntries);
  Item := Entry(Index);
  Item.Booleans['locked'] := True;
  Item.Strings['locked_utc'] := LockedUTC;
  Item.Strings['description'] := Description;
  FEntries[Index].Locked := True;
  FEntries[Index].LockedUTC := LockedUTC;
  FEntries[Index].Description := Description;
end;

procedure TVersionHistory.Start(const Name, Prefix: string; Latest: Integer);
var
  Major, Index: Integer;
  Minor: Int64;
  Item: TJSONObject;
begin
  ParseVersion(Name, Major, Minor);
  if Length(FEntries) > 0 then
  begin
    if not Locked then
      raise EScuError.CreateFmt('Lock version %s before starting a new version.', [Current]);
    if not LaterVersion(Name, Current) then
      raise EScuError.CreateFmt('The new version must be greater than %s.', [Current]);
    for Index := 0 to Length(FEntries) - 1 do
      if FEntries[Index].Name = Name then
        raise EScuError.CreateFmt('Version "%s" already exists.', [Name]);
  end;
  Item := TJSONObject.Create;
  FSerialized.Add(Item);
  Item.Add('name', Name);
  Item.Add('base_revision', Latest);
  Item.Add('locked', False);
  Item.Add('comment_prefix', Prefix);
  Index := Length(FEntries);
  SetLength(FEntries, Index + 1);
  FEntries[Index].Name := Name;
  FEntries[Index].BaseRevision := Latest;
  FEntries[Index].Locked := False;
  FEntries[Index].CommentPrefix := Prefix;
end;

function TVersionHistory.NextVersion(Increment: Int64): string;
var
  Major, Places, Index: Integer;
  Minor, NewMajor, Scale: Int64;
begin
  ParseVersion(Current, Major, Minor);
  Places := Length(Current) - Pos('.', Current);
  if Places = 1 then
  begin
    Places := 2;
    Minor := Minor * 10;
  end;
  Scale := 100;
  for Index := 3 to Places do
    Scale := Scale * 10;
  Minor := Minor + (Increment mod 100) * (Scale div 100);
  NewMajor := Int64(Major) + (Increment div 100) + (Minor div Scale);
  if NewMajor > High(Integer) then
    raise EScuError.Create('The next library version is out of range.');
  Result := IntToStr(NewMajor) + Copy(FormatFixed(Minor mod Scale, Places), 2, MaxInt);
end;

function TVersionHistory.IndexOf(const Name: string): Integer;
begin
  for Result := 0 to Length(FEntries) - 1 do
    if FEntries[Result].Name = Name then
      Exit;
  raise EScuError.CreateFmt('Version "%s" does not exist.', [Name]);
end;

procedure TVersionHistory.Bounds(const Name: string; Latest: Integer; out Base, Last: Integer);
var
  Index: Integer;
begin
  Index := IndexOf(Name);
  Base := BaseRevision(Index);
  Last := EndRevision(Index, Latest);
end;

function TVersionHistory.CommentPrefix(const Name: string): string;
begin
  Result := FEntries[IndexOf(Name)].CommentPrefix;
end;

procedure TVersionHistory.SetCommentPrefix(const Prefix: string; Latest: Integer);
var
  Index: Integer;
begin
  ValidateCommentPrefix(Prefix);
  Index := Length(FEntries) - 1;
  if Locked or (BaseRevision(Index) <> Latest) then
    raise EScuError.Create('Set the comment prefix before the open version receives its first revision.');
  Entry(Index).Strings['comment_prefix'] := Prefix;
  FEntries[Index].CommentPrefix := Prefix;
end;

procedure TVersionHistory.ListNames(Latest, MinimumRevision: Integer; Dest: TStrings);
var
  Index: Integer;
begin
  for Index := 0 to Length(FEntries) - 1 do
    if EndRevision(Index, Latest) >= MinimumRevision then
      Dest.Add(FEntries[Index].Name);
end;

function TVersionHistory.AtRevision(Revision: Integer): string;
var
  First, Last, Middle: Integer;
begin
  First := 0;
  Last := Length(FEntries) - 1;
  while First < Last do
  begin
    Middle := First + (Last - First + 1) div 2;
    // A version's base revision belongs to an earlier version.
    if BaseRevision(Middle) < Revision then
      First := Middle
    else
      Last := Middle - 1;
  end;
  Result := FEntries[First].Name;
end;

procedure TVersionHistory.DeleteEmpty(const Name: string; Latest: Integer);
begin
  if Name <> Current then
    raise EScuError.CreateFmt('Only the current version (%s) can be deleted.', [Current]);
  if Count = 1 then
    raise EScuError.Create('Cannot delete the only library version.');
  if Locked then
    raise EScuError.CreateFmt('Version %s is locked.', [Name]);
  if BaseRevision(Count - 1) <> Latest then
    raise EScuError.CreateFmt('Version %s contains deck revisions and cannot be deleted.', [Name]);
  FSerialized.Delete(Count - 1);
  SetLength(FEntries, Count - 1);
end;

end.
