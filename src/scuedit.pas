unit ScuEdit;

{$mode objfpc}{$H+}

interface

uses
  ScuLibrary, ScuSQLite;

function EditTextFile(LibraryFile: TDeckLibrary; const Name: string;
  const Original: RawByteString; Limit: Int64): RawByteString;
function EditLockDescription(const LibraryPath: string; out Version: string): string;
function EditDeck(LibraryFile: TDeckLibrary; Database: TSQLiteLibrary; const Deck: string): Integer;

implementation

uses
  SysUtils, Classes, Process, ScuErrors, ScuFiles, ScuCodec, ScuProcess, ScuSignals, ScuCleanupFiles;

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
      Editor.Executable := ResolveEditorExecutable(LibraryFile.EditorArguments[0]);
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

function EditLockDescription(const LibraryPath: string; out Version: string): string;
var
  Database: TSQLiteLibrary;
  LibraryFile: TDeckLibrary;
begin
  Database := TSQLiteLibrary.OpenRead(LibraryPath);
  try
    LibraryFile := TDeckLibrary.Load(LibraryPath, Database);
  finally
    Database.Free;
  end;
  try
    LibraryFile.RequireOpenVersion;
    Version := LibraryFile.CurrentVersion;
    Result := EditTextFile(LibraryFile, 'lock-description.txt', '', 1024 * 1024);
    CheckSessionInterrupt;
    if Trim(Result) = '' then
      raise ECommandCancelled.Create('Lock cancelled: empty description.');
    if Result[Length(Result)] = #10 then
    begin
      SetLength(Result, Length(Result) - 1);
      if Result[Length(Result)] = #13 then SetLength(Result, Length(Result) - 1);
    end;
  finally
    LibraryFile.Free;
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
