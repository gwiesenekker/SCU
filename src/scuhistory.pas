unit ScuHistory;

{$mode objfpc}{$H+}

interface

uses
  FPJSON;

const
  MaxHistoryEntries = 100;

function CommandHistoryPath: string;
function ReadCommandHistory(const Path: string): TJSONArray;
procedure SaveHistoryCommand(const Path, Line: string);

implementation

uses
  SysUtils, BaseUnix, ScuIO, ScuJSON;

const
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
    RaiseLastOSError(fpGetErrNo);
  if fpLStat(Directory, Info) <> 0 then
    RaiseLastOSError(fpGetErrNo);
  if not FPS_ISDIR(Info.st_mode) or (Info.st_uid <> fpGetEUID) or
    ((Info.st_mode and &022) <> 0) then
    raise EScuError.CreateFmt('Expected a user-owned SCU state directory at %s.', [Directory]);
  Result := IncludeTrailingPathDelimiter(Directory) + 'history.json';
end;

function ReadCommandHistory(const Path: string): TJSONArray;
var
  Data: TJSONData;
  Bytes: RawByteString;
  Index: Integer;
  PreviousCodePage: TSystemCodePage;
begin
  if not RegularFileExists(Path) then
    Exit(TJSONArray.Create);
  Bytes := ReadBytes(Path, MaxHistorySize);
  // FPC 3.2.2 can transcode JSON strings through the default code page.
  PreviousCodePage := DefaultSystemCodePage;
  DefaultSystemCodePage := CP_UTF8;
  try
    Data := ParseJSON(Bytes);
  finally
    DefaultSystemCodePage := PreviousCodePage;
  end;
  try
    if not (Data is TJSONArray) or (Data.Count > MaxHistoryEntries) then
      raise EScuError.Create('Invalid command history.');
    for Index := 0 to Data.Count - 1 do
      if (Data.Items[Index].JSONType <> jtString) or
        (Length(Data.Items[Index].AsString) > MaxSavedCommandSize) or
        (Pos(#0, Data.Items[Index].AsString) > 0) then
        raise EScuError.Create('Invalid command history entry.');
    Result := TJSONArray(Data);
  except
    Data.Free;
    raise;
  end;
end;

procedure SaveHistoryCommand(const Path, Line: string);
var
  Lock: TLibraryLock;
  History: TJSONArray;
begin
  if Length(Line) > MaxSavedCommandSize then
    Exit;
  Lock := TLibraryLock.Create(Path + '.lock');
  try
    History := ReadCommandHistory(Path);
    try
      if History.Count = MaxHistoryEntries then
        History.Delete(0);
      History.Add(Line);
      AtomicWrite(Path, History.AsJSON + #10);
    finally
      History.Free;
    end;
  finally
    Lock.Free;
  end;
end;

end.
