unit ScuFilePatternCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function EditVersionTracker(var Context: TCommandContext): string;
function EditFilePatterns(var Context: TCommandContext): string;

implementation

uses
  Classes, SysUtils, ScuEdit, ScuFiles, ScuErrors;

function EditVersionTracker(var Context: TCommandContext): string;
var Updated: RawByteString;
begin
  if Context.LibraryFile.VersionTracker = '' then
    raise EScuError.Create('Configure version_tracker with an output filename first.');
  Updated := EditTextFile(Context.LibraryFile, Context.LibraryFile.VersionTracker,
    Context.LibraryFile.TrackerTemplate, 1024 * 1024);
  Context.FormerTracker.FileName := Context.LibraryFile.VersionTracker;
  SetCommandTrackerTemplate(Context, Updated);
  Result := 'Saved version tracker template.';
end;

function EditFilePatterns(var Context: TCommandContext): string;
const
  MaxPatternFileSize = 1024 * 1024;
var
  Patterns: TStringList;
  Index: Integer;
  Updated: RawByteString;
  RecoveryPath, RecoveryDirectory, RecoveryError: string;
begin
  Patterns := TStringList.Create;
  try
    for Index := 0 to Context.LibraryFile.FilePatternCount - 1 do
      Patterns.Add(Context.LibraryFile.FilePatterns[Index]);
    Updated := EditTextFile(Context.LibraryFile, 'file_patterns.txt', Patterns.Text,
      MaxPatternFileSize);
    try
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
    except
      on E: EScuError do
      begin
        RecoveryDirectory := '';
        try
          RecoveryDirectory := MakeTempDirectory('scu-patterns-recovery');
          RecoveryPath := RecoveryDirectory + '/file_patterns.txt';
          AtomicWrite(RecoveryPath, Updated);
        except
          on SaveError: ECommandCancelled do raise;
          on SaveError: Exception do
          begin
            RecoveryError := SaveError.Message;
            if RecoveryDirectory <> '' then RemoveDir(RecoveryDirectory);
            raise EScuError.Create(E.Message + ' Could not preserve edited patterns: ' + RecoveryError);
          end;
        end;
        raise EScuError.Create(E.Message + ' Edited patterns were preserved in "' + RecoveryPath + '".');
      end;
    end;
    Result := Format('Saved %d file pattern(s).', [Patterns.Count]);
  finally
    Patterns.Free;
  end;
end;

end.
