unit ScuEdit;

{$mode objfpc}{$H+}

interface

uses
  ScuLibrary;

function EditDeck(LibraryFile: TDeckLibrary; const Deck: string): Integer;

implementation

uses
  SysUtils, Classes, BaseUnix, Process, FPJSON, ScuIO, ScuCodec, ScuSignals;

function EditorPath(const Name: string): string;
var
  Paths: TStringList;
  Directory, Candidate: string;

  function Executable(const Path: string): Boolean;
  var
    Info: Stat;
  begin
    Result := (fpStat(Path, Info) = 0) and FPS_ISREG(Info.st_mode) and (fpAccess(Path, X_OK) = 0);
  end;

begin
  if Pos('/', Name) > 0 then
  begin
    if Executable(Name) then
      Exit(ExpandFileName(Name));
  end
  else
  begin
    Paths := TStringList.Create;
    try
      ExtractStrings([':'], [], PChar(GetEnvironmentVariable('PATH')), Paths);
      for Directory in Paths do
      begin
        Candidate := IncludeTrailingPathDelimiter(Directory) + Name;
        if Executable(Candidate) then
          Exit(ExpandFileName(Candidate));
      end;
    finally
      Paths.Free;
    end;
  end;
  raise EScuError.CreateFmt('Could not find executable editor "%s".', [Name]);
end;

procedure RemoveWorkingDirectory(const Path: string);
var
  Search: TSearchRec;
  Item: string;
  Info: Stat;
begin
  if FindFirst(Path + '/*', faAnyFile, Search) = 0 then
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      Item := Path + '/' + Search.Name;
      if (fpLStat(Item, Info) = 0) and FPS_ISDIR(Info.st_mode) then
        RemoveWorkingDirectory(Item)
      else
        fpUnlink(Item);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  RemoveDir(Path);
end;

function EditDeck(LibraryFile: TDeckLibrary; const Deck: string): Integer;
var
  Name, TempDir, Path: string;
  Source: TDeckSource;
  Updated: RawByteString;
  Editor: TProcess;
  Args: TJSONArray;
  Index: Integer;
begin
  LibraryFile.RequireOpenVersion;
  Name := DeckName(Deck);
  Source := LibraryFile.Extract(Name, LibraryFile.Revision, LibraryFile.CurrentVersion);
  TempDir := MakeTempDirectory('scu-edit');
  Path := IncludeTrailingPathDelimiter(TempDir) + Name;
  try
    AtomicWrite(Path, Source.Bytes);
    Editor := TProcess.Create(nil);
    try
      Args := LibraryFile.Editor;
      Editor.Executable := EditorPath(Args.Strings[0]);
      for Index := 1 to Args.Count - 1 do
        Editor.Parameters.Add(Args.Strings[Index]);
      Editor.Parameters.Add(Path);
      WaitForChild(Editor);
      if SessionSignal <> 0 then
        raise EScuError.Create('Editor interrupted.');
      if ChildExitStatus(Editor) <> 0 then
        raise EScuError.CreateFmt('Editor failed with exit status %d.', [ChildExitStatus(Editor)]);
    finally
      Editor.Free;
    end;
    if not RegularFileExists(Path) then
      raise EScuError.Create('The editor removed the working file.');
    Updated := ReadBytes(Path, MaxDeckSize);
    if Updated = Source.Bytes then
      Result := 0
    else
      Result := LibraryFile.Store(Name, Updated);
  finally
    RemoveWorkingDirectory(TempDir);
  end;
end;

end.
