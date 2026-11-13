unit ScuEdit;

{$mode objfpc}{$H+}

interface

uses
  ScuLibrary, ScuSQLite;

function EditTextFile(LibraryFile: TDeckLibrary; const Name: string;
  const Original: RawByteString; Limit: Int64): RawByteString;
function EditDeck(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary; const Deck: string): Integer;

implementation

uses
  SysUtils, Classes, BaseUnix, Process, ScuErrors, ScuFiles, ScuCodec, ScuProcess, ScuSignals;

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
  // On Unix the symlink flag includes dangling links in the listing.
  {$push}{$warn SYMBOL_PLATFORM off}
  if FindFirst(Path + '/*', faAnyFile or faSymLink, Search) = 0 then
  {$pop}
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

function EditTextFile(LibraryFile: TDeckLibrary; const Name: string;
  const Original: RawByteString; Limit: Int64): RawByteString;
var
  TempDir, Path: string;
  Editor: TProcess;
  Index, Status: Integer;
begin
  TempDir := MakeTempDirectory('scu-edit');
  Path := IncludeTrailingPathDelimiter(TempDir) + Name;
  try
    AtomicWrite(Path, Original);
    Editor := TProcess.Create(nil);
    try
      Editor.Executable := EditorPath(LibraryFile.EditorArguments[0]);
      for Index := 1 to LibraryFile.EditorCount - 1 do
        Editor.Parameters.Add(LibraryFile.EditorArguments[Index]);
      Editor.Parameters.Add(Path);
      Status := WaitForChild(Editor, [cpHandlesInterrupt]);
      if SessionEnding then
        raise EScuError.Create('Editor interrupted.');
      if Status <> 0 then
        raise EScuError.CreateFmt('Editor failed with exit status %d.', [Status]);
    finally
      Editor.Free;
    end;
    if not RegularFileExists(Path) then
      raise EScuError.Create('The editor removed the working file.');
    Result := ReadBytes(Path, Limit);
  finally
    RemoveWorkingDirectory(TempDir);
  end;
end;

function EditDeck(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary; const Deck: string): Integer;
var
  Name: string;
  Source: TDeckSource;
  Updated: RawByteString;
begin
  LibraryFile.RequireOpenVersion;
  Name := DeckName(Deck);
  Source := LibraryFile.Extract(Database, Name, LibraryFile.Revision, LibraryFile.CurrentVersion);
  Updated := EditTextFile(LibraryFile, Name, Source.Bytes, MaxDeckSize);
  if Updated = Source.Bytes then
    Result := 0
  else
    Result := LibraryFile.Store(Database, Name, Updated);
end;

end.
