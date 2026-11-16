unit ScuFileScan;

{$mode objfpc}{$H+}

interface

uses
  Classes, Contnrs;

type
  TDeckFileBinding = class
  public
    Deck: string;
  end;

  TLibraryFileScan = class
  private
    FDirectory, FLibraryPath: string;
    FPatterns, FFiles, FOwnerPaths: TStringList;
    FOwners: TFPHashObjectList; // Borrowed only while constructing the scan.
    function GetCount: Integer;
    function GetDeck(Index: Integer): string;
    function GetRelativePath(Index: Integer): string;
    procedure ScanDirectory;
    procedure AddFile(const RelativePath: string);
    function FindOwner(const RelativePath: string): TDeckFileBinding;
  public
    constructor Create(const Directory, LibraryPath: string; Patterns: TStrings;
      Owners: TFPHashObjectList = nil);
    destructor Destroy; override;
    function Find(const Deck: string): Integer;
    function Includes(const RelativePath: string): Boolean;
    property Count: Integer read GetCount;
    property Decks[Index: Integer]: string read GetDeck;
    property RelativePaths[Index: Integer]: string read GetRelativePath;
  end;

function MatchesFilePattern(const Pattern, Name: string): Boolean;

implementation

uses
  SysUtils, ScuDirectoryScan, ScuErrors, ScuFiles, ScuLibraryNames, ScuLockTypes, ScuLibraryPaths, ScuSignals, ScuPlatformPaths{$IFDEF WINDOWS}, ScuPlatformScanWindows{$ENDIF};

{$IFDEF WINDOWS}
type
  TOwnerPaths = class(TStringList)
  protected
    function CompareStrings(const Left, Right: string): Integer; override;
  end;
function TOwnerPaths.CompareStrings(const Left, Right: string): Integer;
begin
  Result := CompareFileNames(Left, Right);
end;
{$ENDIF}

function MatchesFilePattern(const Pattern, Name: string): Boolean;
begin
  Result := ScuDirectoryScan.MatchesFilePattern(Pattern, Name);
end;

constructor TLibraryFileScan.Create(const Directory, LibraryPath: string; Patterns: TStrings;
  Owners: TFPHashObjectList);
var
  Pattern: string;
  {$IFDEF WINDOWS}Index: Integer;{$ENDIF}
begin
  inherited Create;
  FDirectory := IncludeTrailingPathDelimiter(CanonicalDirectory(Directory));
  FLibraryPath := LibraryPath;
  FPatterns := TStringList.Create;
  FPatterns.Assign(Patterns);
  FOwners := Owners;
  for Pattern in FPatterns do
    ValidateFilePattern(Pattern);
  FFiles := TStringList.Create;
  FFiles.CaseSensitive := True;
  FFiles.Sorted := True;
  {$IFDEF WINDOWS}
  if Assigned(FOwners) then
  begin
    FOwnerPaths := TOwnerPaths.Create;
    for Index := 0 to FOwners.Count - 1 do
      FOwnerPaths.AddObject(FOwners.NameOfIndex(Index), FOwners.Items[Index]);
    FOwnerPaths.Sorted := True;
    for Index := 1 to FOwnerPaths.Count - 1 do
      if CompareFileNames(FOwnerPaths[Index - 1], FOwnerPaths[Index]) = 0 then
      begin
        FOwnerPaths.Objects[Index - 1] := nil;
        FOwnerPaths.Objects[Index] := nil;
      end;
  end;
  {$ENDIF}
  ScanDirectory;
  FOwners := nil;
end;

destructor TLibraryFileScan.Destroy;
begin
  FOwnerPaths.Free;
  FFiles.Free;
  FPatterns.Free;
  inherited Destroy;
end;

procedure TLibraryFileScan.ScanDirectory;
var
  Directory: TDirectoryScan;
  Name, Path: string;
begin
  Directory := TDirectoryScan.Create(FDirectory);
  try
    repeat
      CheckSessionInterrupt;
      if not Directory.Next(Name) then Break;
      if (Name = '.') or (Name = '..') or not Includes(Name) then Continue;
      Path := FDirectory + Name;
      if Directory.SelectedRegularFile(Name) then
      begin
        if IsSQLiteFile(Path) or IsSQLiteCompanion(Path) then Continue;
        AddFile(Name);
      end;
    until False;
  finally
    Directory.Free;
  end;
end;

function TLibraryFileScan.FindOwner(const RelativePath: string): TDeckFileBinding;
{$IFDEF WINDOWS}
var Index: Integer;
{$ENDIF}
begin
  Result := nil;
  if not Assigned(FOwners) then Exit;
  {$IFDEF WINDOWS}
  Index := FOwnerPaths.IndexOf(RelativePath);
  if Index >= 0 then
  begin
    Result := TDeckFileBinding(FOwnerPaths.Objects[Index]);
    if Result = nil then
      raise EScuError.Create('Several decks track source "' + RelativePath + '". Import them individually.');
  end;
  {$ELSE}
  Result := TDeckFileBinding(FOwners.Find(RelativePath));
  {$ENDIF}
end;

procedure TLibraryFileScan.AddFile(const RelativePath: string);
var
  Deck: string;
  Index: Integer;
  Owner: TDeckFileBinding;
begin
  ValidateSourceFileName(RelativePath);
  Owner := FindOwner(RelativePath);
  if Assigned(Owner) then
  begin
    if Owner.Deck = '' then
      raise EScuError.Create('Several decks track source "' + RelativePath + '". Import them individually.');
    Deck := Owner.Deck;
  end
  else
  begin
    try
      Deck := DeckName(ExtractFileName(RelativePath));
    except
      on E: EScuError do Deck := 'file-' + FileNameDigest(RelativePath);
    end;
  end;
  Index := Find(Deck);
  if Index >= 0 then
  begin
    if RelativePaths[Index] <> RelativePath then
      raise EScuError.CreateFmt('Files "%s" and "%s" both map to deck "%s".',
        [RelativePaths[Index], RelativePath, Deck]);
    Exit;
  end;
  FFiles.Add(Deck + '=' + RelativePath);
end;

function TLibraryFileScan.GetCount: Integer;
begin
  Result := FFiles.Count;
end;

function TLibraryFileScan.GetDeck(Index: Integer): string;
begin
  Result := FFiles.Names[Index];
end;

function TLibraryFileScan.GetRelativePath(Index: Integer): string;
begin
  Result := FFiles.ValueFromIndex[Index];
end;

function TLibraryFileScan.Find(const Deck: string): Integer;
begin
  Result := FFiles.IndexOfName(Deck);
end;

function TLibraryFileScan.Includes(const RelativePath: string): Boolean;
var
  Pattern: string;
begin
  if (Pos('/', RelativePath) > 0)
    {$IFDEF WINDOWS}or (Pos('\', RelativePath) > 0){$ENDIF} then
    Exit(False);
  if IsPlatformOutputLockName(ExtractFileName(RelativePath)) then Exit(False);
  if IsLibraryStoragePath(FDirectory + RelativePath, FLibraryPath) or
    SameStoragePath(ExtractFileName(RelativePath), '.scu-exports.json') then
    Exit(False);
  for Pattern in FPatterns do
    if MatchesFilePattern(Pattern, RelativePath) then
      Exit(True);
  Result := False;
end;

end.
