unit ScuEdit;

{$mode objfpc}{$H+}

interface

uses
  ScuLibrary;

function EditDeck(LibraryFile: TDeckLibrary; const Deck: string): Integer;

implementation

uses
  SysUtils, Process, FPJSON, ScuIO, ScuCodec;

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
      Editor.Executable := Args.Strings[0];
      for Index := 1 to Args.Count - 1 do
        Editor.Parameters.Add(Args.Strings[Index]);
      Editor.Parameters.Add(Path);
      Editor.Options := [poWaitOnExit];
      Editor.Execute;
      if Editor.ExitStatus <> 0 then
        raise EScuError.CreateFmt('Editor failed with exit status %d.', [Editor.ExitStatus]);
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
    DeleteFile(Path);
    RemoveDir(TempDir);
  end;
end;

end.
