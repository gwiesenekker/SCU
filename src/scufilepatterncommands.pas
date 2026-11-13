unit ScuFilePatternCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function EditFilePatterns(var Context: TCommandContext): string;

implementation

uses
  Classes, SysUtils, ScuEdit, ScuErrors;

function EditFilePatterns(var Context: TCommandContext): string;
const
  MaxPatternFileSize = 1024 * 1024;
var
  Patterns: TStringList;
  Index: Integer;
  Updated: RawByteString;
begin
  Patterns := TStringList.Create;
  try
    for Index := 0 to Context.LibraryFile.FilePatternCount - 1 do
      Patterns.Add(Context.LibraryFile.FilePatterns[Index]);
    Updated := EditTextFile(Context.LibraryFile, 'file_patterns.txt', Patterns.Text,
      MaxPatternFileSize);
    if Pos(#0, Updated) > 0 then
      raise EScuError.Create('File patterns cannot contain NUL bytes.');
    Patterns.Text := Updated;
    for Index := Patterns.Count - 1 downto 0 do
    begin
      Patterns[Index] := Trim(Patterns[Index]);
      if Patterns[Index] = '' then
        Patterns.Delete(Index);
    end;
    Context.LibraryFile.SetFilePatterns(Patterns);
    Result := Format('Saved %d file pattern(s).', [Patterns.Count]);
  finally
    Patterns.Free;
  end;
end;

end.
