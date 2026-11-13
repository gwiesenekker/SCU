unit ScuFileScan;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TLibraryFileScan = class
  private
    FDirectory, FLibraryPath: string;
    FPatterns, FFiles: TStringList;
    function GetCount: Integer;
    function GetDeck(Index: Integer): string;
    function GetRelativePath(Index: Integer): string;
    procedure ScanDirectory;
    procedure AddFile(const RelativePath: string);
  public
    constructor Create(const Directory, LibraryPath: string; Patterns: TStrings);
    destructor Destroy; override;
    function Find(const Deck: string): Integer;
    function Includes(const RelativePath: string): Boolean;
    property Count: Integer read GetCount;
    property Decks[Index: Integer]: string read GetDeck;
    property RelativePaths[Index: Integer]: string read GetRelativePath;
  end;

implementation

uses
  SysUtils, BaseUnix, ScuErrors, ScuFiles, ScuLibraryModel, ScuLibraryPaths, ScuSignals;

function fnmatch(Pattern, Name: PChar; Flags: LongInt): LongInt; cdecl; external 'c';

const
  MatchNoEscape = 2;
  MatchPeriod = 4;

constructor TLibraryFileScan.Create(const Directory, LibraryPath: string; Patterns: TStrings);
var
  Pattern: string;
begin
  inherited Create;
  FDirectory := IncludeTrailingPathDelimiter(CanonicalDirectory(Directory));
  FLibraryPath := LibraryPath;
  FPatterns := TStringList.Create;
  FPatterns.Assign(Patterns);
  for Pattern in FPatterns do
    ValidateFilePattern(Pattern);
  FFiles := TStringList.Create;
  FFiles.CaseSensitive := True;
  FFiles.Sorted := True;
  ScanDirectory;
end;

destructor TLibraryFileScan.Destroy;
begin
  FFiles.Free;
  FPatterns.Free;
  inherited Destroy;
end;

procedure TLibraryFileScan.ScanDirectory;
var
  Directory: pDir;
  Entry: pDirent;
  Name, Path: string;
  Info: Stat;
begin
  Directory := fpOpenDir(PChar(FDirectory));
  if Directory = nil then
    RaiseSystemError('Could not scan directory "' + FDirectory + '"', fpGetErrNo);
  try
    repeat
      CheckSessionInterrupt;
      fpSetErrNo(0);
      Entry := fpReadDir(Directory^);
      if Entry = nil then
      begin
        if fpGetErrNo <> 0 then
          RaiseSystemError('Could not read directory "' + FDirectory + '"', fpGetErrNo);
        Break;
      end;
      Name := StrPas(@Entry^.d_name[0]);
      if (Name = '.') or (Name = '..') or not Includes(Name) then
        Continue;
      Path := FDirectory + Name;
      if fpLStat(Path, Info) <> 0 then
        RaiseSystemError('Could not inspect selected file "' + Path + '"', fpGetErrNo);
      if FPS_ISLNK(Info.st_mode) then
        raise EScuError.Create('Cannot snapshot a symbolic link: "' + Path + '".');
      if not FPS_ISDIR(Info.st_mode) then
      begin
        if not FPS_ISREG(Info.st_mode) then
          raise EScuError.Create('Expected a regular file: "' + Path + '".');
        AddFile(Name);
      end;
    until False;
  finally
    fpCloseDir(Directory^);
  end;
end;

procedure TLibraryFileScan.AddFile(const RelativePath: string);
var
  Deck: string;
  Index: Integer;
begin
  Deck := DeckName(ExtractFileName(RelativePath));
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
  if (Pos('/', RelativePath) > 0) or (Pos('\', RelativePath) > 0) then
    Exit(False);
  if IsLibraryStoragePath(FDirectory + RelativePath, FLibraryPath) or
    (ExtractFileName(RelativePath) = '.scu-exports.json') then
    Exit(False);
  for Pattern in FPatterns do
    if fnmatch(PChar(Pattern), PChar(RelativePath), MatchNoEscape or MatchPeriod) = 0 then
      Exit(True);
  Result := False;
end;

end.
