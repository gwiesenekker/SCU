unit ScuHistory;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TCommandHistory = class
  private
    FEntries: TStringList;
    FPath: string;
  public
    destructor Destroy; override;
    procedure Load;
    procedure Remember(const Line: string);
    property Entries: TStringList read FEntries;
  end;

implementation

uses
  SysUtils, BaseUnix, FPJSON, JSONScanner, ScuErrors, ScuFiles, ScuLocks;

const
  MaxHistoryEntries = 100;
  MaxSavedCommandSize = 64 * 1024;
  MaxHistorySize = MaxHistoryEntries * (6 * MaxSavedCommandSize + 4) + 16;

function EnsureDirectory(const Path: string): Boolean;
var
  Parent: string;
begin
  if DirectoryExists(Path) then
    Exit(True);
  Parent := ExtractFileDir(ExcludeTrailingPathDelimiter(Path));
  Result := (Parent <> '') and (Parent <> Path) and EnsureDirectory(Parent) and
    (CreateDir(Path) or DirectoryExists(Path));
end;

function CommandHistoryPath: string;
var
  StateDir, Directory: string;
  Info: Stat;
begin
  StateDir := GetEnvironmentVariable('XDG_STATE_HOME');
  if Copy(StateDir, 1, 1) <> DirectorySeparator then
  begin
    StateDir := GetEnvironmentVariable('HOME');
    if Copy(StateDir, 1, 1) <> DirectorySeparator then
      Exit('');
    StateDir := IncludeTrailingPathDelimiter(StateDir) + '.local/state';
  end;
  if not EnsureDirectory(StateDir) then
    raise EScuError.CreateFmt('Could not create state directory %s.', [StateDir]);
  Directory := IncludeTrailingPathDelimiter(StateDir) + 'scu';
  if (fpMkDir(Directory, &700) <> 0) and (fpGetErrNo <> ESysEEXIST) then
    RaiseSystemError('Could not create SCU state directory "' + Directory + '"', fpGetErrNo);
  if fpLStat(Directory, Info) <> 0 then
    RaiseSystemError('Could not inspect SCU state directory "' + Directory + '"', fpGetErrNo);
  if not FPS_ISDIR(Info.st_mode) or (Info.st_uid <> fpGetEUID) or
    ((Info.st_mode and &022) <> 0) then
    raise EScuError.CreateFmt('Expected a user-owned SCU state directory at %s.', [Directory]);
  Result := IncludeTrailingPathDelimiter(Directory) + 'history.json';
end;

procedure ReadHistoryFile(const Path: string; Entries: TStrings);
var
  Scanner: TJSONScanner;
  Token: TJSONToken;
  Bytes: RawByteString;
  Line: string;

  function NextToken: TJSONToken;
  begin
    repeat
      Result := Scanner.FetchToken;
    until Result <> tkWhitespace;
  end;

  procedure InvalidHistory;
  begin
    raise EScuError.CreateFmt('Invalid command history in "%s".', [Path]);
  end;

begin
  if not RegularFileExists(Path) then
    Exit;
  Bytes := ReadBytes(Path, MaxHistorySize);
  if Pos(#0, Bytes) > 0 then
    InvalidHistory;
  // The scanner gives us UTF-8 bytes directly, even in a non-UTF-8 locale.
  Scanner := TJSONScanner.Create(Bytes, [joUTF8, joStrict]);
  try
    if NextToken <> tkSquaredBraceOpen then
      InvalidHistory;
    Token := NextToken;
    if Token <> tkSquaredBraceClose then
      repeat
        if (Token <> tkString) or (Entries.Count = MaxHistoryEntries) then
          InvalidHistory;
        Line := Scanner.CurTokenString;
        if (Length(Line) > MaxSavedCommandSize) or (Pos(#0, Line) > 0) then
          InvalidHistory;
        Entries.Add(Line);
        Token := NextToken;
        if Token = tkSquaredBraceClose then
          Break;
        if Token <> tkComma then
          InvalidHistory;
        Token := NextToken;
      until False;
    if NextToken <> tkEOF then
      InvalidHistory;
  finally
    Scanner.Free;
  end;
end;

procedure AddHistoryEntry(Entries: TStrings; const Line: string);
begin
  if Entries.Count = MaxHistoryEntries then
    Entries.Delete(0);
  Entries.Add(Line);
end;

procedure SaveHistoryCommand(const Path, Line: string);
var
  Lock: TFileLock;
  Entries: TStringList;
  Document: TJSONArray;
  Command: string;
  Bytes: RawByteString;
begin
  if Length(Line) > MaxSavedCommandSize then
    Exit;
  Lock := TFileLock.Create(Path + '.lock');
  try
    Entries := TStringList.Create;
    try
      ReadHistoryFile(Path, Entries);
      AddHistoryEntry(Entries, Line);
      Document := TJSONArray.Create;
      try
        for Command in Entries do
        begin
          Bytes := Command;
          SetCodePage(Bytes, CP_UTF8, False);
          Document.Add(UTF8String(Bytes));
        end;
        AtomicWrite(Path, Document.AsJSON + #10);
      finally
        Document.Free;
      end;
    finally
      Entries.Free;
    end;
  finally
    Lock.Free;
  end;
end;

destructor TCommandHistory.Destroy;
begin
  FEntries.Free;
  inherited Destroy;
end;

procedure TCommandHistory.Load;
begin
  if Assigned(FEntries) then
    Exit;
  FEntries := TStringList.Create;
  try
    FPath := CommandHistoryPath;
    if FPath <> '' then
      ReadHistoryFile(FPath, FEntries);
  except
    on E: Exception do
    begin
      FEntries.Clear;
      WriteLn(StdErr, 'scu: Could not load command history. ', E.Message);
      FPath := '';
    end;
  end;
end;

procedure TCommandHistory.Remember(const Line: string);
begin
  if not Assigned(FEntries) or (Trim(Line) = '') then
    Exit;
  AddHistoryEntry(FEntries, Line);
  if FPath = '' then
    Exit;
  try
    SaveHistoryCommand(FPath, Line);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'scu: Could not save command history. ', E.Message);
      FPath := '';
    end;
  end;
end;

end.
