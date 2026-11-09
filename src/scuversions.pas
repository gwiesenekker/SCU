unit ScuVersions;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON;

type
  TVersionHistory = class
  private
    FEntries: TJSONArray;
    function Entry(Index: Integer): TJSONObject;
    function GetCurrent: string;
    function GetLocked: Boolean;
    function BaseRevision(Index: Integer): Integer;
    function EndRevision(Index, Latest: Integer): Integer;
    function IndexOf(const Name: string): Integer;
  public
    constructor Create(Entries: TJSONArray; Latest: Integer);
    procedure Lock;
    procedure Start(const Name, Prefix: string; Latest: Integer);
    function NextVersion(Increment: Int64): string;
    function CommentPrefix(const Name: string): string;
    procedure SetCommentPrefix(const Prefix: string; Latest: Integer);
    procedure Bounds(const Name: string; Latest: Integer; out Base, Last: Integer);
    procedure List(Latest: Integer; Dest: TStrings);
    procedure ListNames(Latest, MinimumRevision: Integer; Dest: TStrings);
    function AtRevision(Revision: Integer): string;
    function TryPrevious(out Name: string; out Last: Integer): Boolean;
    property Current: string read GetCurrent;
    property Locked: Boolean read GetLocked;
  end;

procedure ValidateCommentPrefix(const Prefix: string);

implementation

uses
  SysUtils, ScuIO, ScuJSON, ScuVersionNumbers;

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

procedure ParseVersion(const Name: string; out Major, Minor: Integer);
var
  Dot: SizeInt;
  MinorText: string;
begin
  Dot := Pos('.', Name);
  MinorText := Copy(Name, Dot + 1, MaxInt);
  if (Dot <= 1) or not TryStrToInt(Copy(Name, 1, Dot - 1), Major) or
    not TryStrToInt(MinorText, Minor) or (Major < 0) or (Minor < 0) or
    (Copy(Name, 1, Dot - 1) <> IntToStr(Major)) or
    ((MinorText <> IntToStr(Minor)) and ((Minor > 9) or (MinorText <> '0' + IntToStr(Minor)))) then
    raise EScuError.CreateFmt('Invalid version "%s". Expected MAJOR.MINOR.', [Name]);
end;

function LaterVersion(const Name, Previous: string): Boolean;
var
  Major, Minor, PreviousMajor, PreviousMinor: Integer;
begin
  ParseVersion(Name, Major, Minor);
  ParseVersion(Previous, PreviousMajor, PreviousMinor);
  Result := (Major > PreviousMajor) or ((Major = PreviousMajor) and (Minor > PreviousMinor));
end;

constructor TVersionHistory.Create(Entries: TJSONArray; Latest: Integer);
var
  Index, Base, PreviousBase, Major, Minor: Integer;
  Name, PreviousName: string;
  IsLocked: Boolean;
begin
  inherited Create;
  FEntries := Entries;
  PreviousBase := 0;
  PreviousName := '';
  for Index := 0 to FEntries.Count - 1 do
  begin
    Name := Field(Entry(Index), 'name', jtString).AsString;
    ParseVersion(Name, Major, Minor);
    ValidateCommentPrefix(Field(Entry(Index), 'comment_prefix', jtString).AsString);
    Base := BaseRevision(Index);
    IsLocked := Field(Entry(Index), 'locked', jtBoolean).AsBoolean;
    if (Base > Latest) or (Base < PreviousBase) or ((Index = 0) and (Base <> 0)) or
      ((Index < FEntries.Count - 1) and not IsLocked) or
      ((Index > 0) and not LaterVersion(Name, PreviousName)) then
      raise EScuError.Create('Invalid version history.');
    PreviousBase := Base;
    PreviousName := Name;
  end;
end;

function TVersionHistory.Entry(Index: Integer): TJSONObject;
begin
  if not (FEntries.Items[Index] is TJSONObject) then
    raise EScuError.Create('Invalid version history entry.');
  Result := TJSONObject(FEntries.Items[Index]);
end;

function TVersionHistory.GetCurrent: string;
begin
  Result := Field(Entry(FEntries.Count - 1), 'name', jtString).AsString;
end;

function TVersionHistory.GetLocked: Boolean;
begin
  Result := Field(Entry(FEntries.Count - 1), 'locked', jtBoolean).AsBoolean;
end;

function TVersionHistory.BaseRevision(Index: Integer): Integer;
var
  Value: Int64;
begin
  Value := IntegerField(Entry(Index), 'base_revision');
  if (Value < 0) or (Value > High(Integer)) then
    raise EScuError.Create('Invalid version base revision.');
  Result := Value;
end;

function TVersionHistory.EndRevision(Index, Latest: Integer): Integer;
begin
  if Index < FEntries.Count - 1 then
    Result := BaseRevision(Index + 1)
  else
    Result := Latest;
end;

function TVersionHistory.TryPrevious(out Name: string; out Last: Integer): Boolean;
begin
  Result := FEntries.Count > 1;
  if not Result then
    Exit;
  // Every version before the current one is locked.
  Name := Field(Entry(FEntries.Count - 2), 'name', jtString).AsString;
  Last := BaseRevision(FEntries.Count - 1);
end;

procedure TVersionHistory.Lock;
begin
  if Locked then
    raise EScuError.CreateFmt('Version %s is already locked.', [Current]);
  Entry(FEntries.Count - 1).Booleans['locked'] := True;
end;

procedure TVersionHistory.Start(const Name, Prefix: string; Latest: Integer);
var
  Major, Minor: Integer;
  Item: TJSONObject;
begin
  ParseVersion(Name, Major, Minor);
  if FEntries.Count > 0 then
  begin
    if not Locked then
      raise EScuError.CreateFmt('Lock version %s before starting a new version.', [Current]);
    if not LaterVersion(Name, Current) then
      raise EScuError.CreateFmt('The new version must be greater than %s.', [Current]);
  end;
  Item := TJSONObject.Create;
  FEntries.Add(Item);
  Item.Add('name', Name);
  Item.Add('base_revision', Latest);
  Item.Add('locked', False);
  Item.Add('comment_prefix', Prefix);
end;

function TVersionHistory.NextVersion(Increment: Int64): string;
var
  Major, Minor: Integer;
  Units: Int64;
begin
  ParseVersion(Current, Major, Minor);
  Units := Int64(Major) * 100 + Minor;
  if Increment > Int64(High(Integer)) * 100 + 99 - Units then
    raise EScuError.Create('The next library version is out of range.');
  Result := FormatFixed(Units + Increment, 2);
end;

function TVersionHistory.IndexOf(const Name: string): Integer;
begin
  for Result := 0 to FEntries.Count - 1 do
    if Field(Entry(Result), 'name', jtString).AsString = Name then
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
  Result := Field(Entry(IndexOf(Name)), 'comment_prefix', jtString).AsString;
end;

procedure TVersionHistory.SetCommentPrefix(const Prefix: string; Latest: Integer);
var
  Index: Integer;
begin
  ValidateCommentPrefix(Prefix);
  Index := FEntries.Count - 1;
  if Locked or (BaseRevision(Index) <> Latest) then
    raise EScuError.Create('Set the comment prefix before the open version receives its first revision.');
  Entry(Index).Strings['comment_prefix'] := Prefix;
end;

procedure TVersionHistory.List(Latest: Integer; Dest: TStrings);
var
  Index: Integer;
  State: string;
begin
  for Index := 0 to FEntries.Count - 1 do
  begin
    if Field(Entry(Index), 'locked', jtBoolean).AsBoolean then
      State := 'locked'
    else
      State := 'open';
    Dest.Add(Format('%s'#9'%s'#9'%d'#9'%d', [Field(Entry(Index), 'name', jtString).AsString,
      State, BaseRevision(Index), EndRevision(Index, Latest)]));
  end;
end;

procedure TVersionHistory.ListNames(Latest, MinimumRevision: Integer; Dest: TStrings);
var
  Index: Integer;
begin
  for Index := 0 to FEntries.Count - 1 do
    if EndRevision(Index, Latest) >= MinimumRevision then
      Dest.Add(Field(Entry(Index), 'name', jtString).AsString);
end;

function TVersionHistory.AtRevision(Revision: Integer): string;
var
  First, Last, Middle: Integer;
begin
  First := 0;
  Last := FEntries.Count - 1;
  while First < Last do
  begin
    Middle := First + (Last - First + 1) div 2;
    // A version's base revision belongs to an earlier version.
    if BaseRevision(Middle) < Revision then
      First := Middle
    else
      Last := Middle - 1;
  end;
  Result := Field(Entry(First), 'name', jtString).AsString;
end;

end.
