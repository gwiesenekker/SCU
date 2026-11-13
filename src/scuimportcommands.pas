unit ScuImportCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function ImportDeckCommand(var Context: TCommandContext): string;

implementation

uses
  Classes, SysUtils, ScuCodec, ScuErrors, ScuFiles, ScuFileScan, ScuLibrary,
  ScuSignals, ScuTable, ScuTerminal;

type
  TImportReport = class
  private
    FRows: TStringList;
    FNew, FChanged, FDeleted, FUnchanged: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Imported(var Context: TCommandContext; const Deck, Path, RelativePath: string);
    procedure Deleted(var Context: TCommandContext; const Deck: string);
    function Finish(var Context: TCommandContext): string;
  end;

constructor TImportReport.Create;
begin
  inherited Create;
  FRows := TStringList.Create;
  FRows.Sorted := True;
  FRows.CaseSensitive := True;
end;

destructor TImportReport.Destroy;
begin
  FRows.Free;
  inherited Destroy;
end;

procedure TImportReport.Imported(var Context: TCommandContext;
  const Deck, Path, RelativePath: string);
var
  Snapshot: TLibrarySnapshot;
  Bytes: RawByteString;
  Sequence: Integer;
  Existed: Boolean;
  Status: string;
begin
  CheckSessionInterrupt;
  Existed := Context.LibraryFile.TryDeckSnapshot(Deck, Context.LibraryFile.Revision, Snapshot);
  Bytes := ReadBytes(Path, MaxDeckSize);
  Sequence := Context.LibraryFile.Store(Context.Database, Deck, Bytes, False,
    PrefixArgument(Context.Command), RelativePath);
  if Sequence = 0 then
  begin
    Inc(FUnchanged);
    Exit;
  end;
  if Existed then
  begin
    Status := 'changed';
    Inc(FChanged);
  end
  else
  begin
    Status := 'new';
    Inc(FNew);
  end;
  FRows.Add(Deck + #9 + Context.LibraryFile.DeckVersion[Sequence] + #9 + Status);
end;

procedure TImportReport.Deleted(var Context: TCommandContext; const Deck: string);
var
  Sequence: Integer;
begin
  CheckSessionInterrupt;
  Sequence := Context.LibraryFile.Delete(Context.Database, Deck);
  FRows.Add(Deck + #9 + Context.LibraryFile.DeckVersion[Sequence] + #9 + 'deleted');
  Inc(FDeleted);
end;

function TImportReport.Finish(var Context: TCommandContext): string;
var
  Table: TScuTable;
  Row: string;
begin
  if FRows.Count > 0 then
  begin
    Table := TScuTable.Create(['Deck name', 'Deck version', 'Status']);
    try
      for Row in FRows do
        Table.AddDelimitedRow(Row);
      Table.WriteTo(Context.Output, TerminalColumns(StdOutputHandle));
    finally
      Table.Free;
    end;
  end;
  Context.Snapshots.Selected := Context.LibraryFile.CurrentSnapshot;
  Result := Format('Imported %d new, %d changed, %d deleted; %d unchanged.',
    [FNew, FChanged, FDeleted, FUnchanged]);
end;

procedure ImportPatterns(var Context: TCommandContext; Report: TImportReport; const Directory: string);
var
  Patterns: TStringList;
  Scan: TLibraryFileScan;
  Decks: TDeckListEntries;
  Index: Integer;
  Path, PreviousPath: string;
  Snapshot: TLibrarySnapshot;
begin
  Patterns := TStringList.Create;
  Scan := nil;
  try
    for Index := 0 to Context.LibraryFile.FilePatternCount - 1 do
      Patterns.Add(Context.LibraryFile.FilePatterns[Index]);
    Scan := TLibraryFileScan.Create(Directory, Context.LibraryPath, Patterns);
    Decks := Context.LibraryFile.DeckList(Context.LibraryFile.Revision);
    // Preflight basename collisions with a deck whose other source still exists.
    for Index := 0 to Scan.Count - 1 do
      if Context.LibraryFile.TryDeckSnapshot(Scan.Decks[Index], Context.LibraryFile.Revision, Snapshot) then
      begin
        PreviousPath := Context.LibraryFile.DeckSourcePath(Context.Database, Scan.Decks[Index]);
        if (PreviousPath <> Scan.RelativePaths[Index]) and
          RegularFileExists(Directory + PreviousPath) then
          raise EScuError.CreateFmt('Deck "%s" already has source "%s"; cannot also import "%s".',
            [Scan.Decks[Index], PreviousPath, Scan.RelativePaths[Index]]);
      end;
    for Index := 0 to Scan.Count - 1 do
      Report.Imported(Context, Scan.Decks[Index], Directory + Scan.RelativePaths[Index], Scan.RelativePaths[Index]);
    for Index := 0 to Length(Decks) - 1 do
    begin
      CheckSessionInterrupt;
      Path := Context.LibraryFile.DeckSourcePath(Context.Database, Decks[Index].Name);
      if Scan.Includes(Path) and (Scan.Find(Decks[Index].Name) < 0) then
        Report.Deleted(Context, Decks[Index].Name);
    end;
  finally
    Scan.Free;
    Patterns.Free;
  end;
end;

function ImportDeckCommand(var Context: TCommandContext): string;
var
  Deck, Path, Directory: string;
  Report: TImportReport;
begin
  Context.LibraryFile.RequireOpenVersion;
  Directory := IncludeTrailingPathDelimiter(ExtractFileDir(Context.LibraryPath));
  Deck := Context.Command.Argument('deck_name');
  Path := Context.Command.Argument('source_file');
  if (Pos('/', Path) > 0) or (Pos('\', Path) > 0) or
    ((Length(Path) > 1) and (Path[2] = ':')) or (Path = '.') or (Path = '..') then
    raise EScuError.Create('source_file must be a filename without a directory component, in the library directory.');
  if (Deck = '') and (Path <> '') then
    raise EScuError.Create('Specify deck_name when using source_file; omit both to scan file_patterns.');
  if (Deck = '') and (Context.LibraryFile.FilePatternCount = 0) then
    Exit('No file patterns are configured. Use edit_file_patterns.');
  Report := TImportReport.Create;
  try
    if Deck = '' then
      ImportPatterns(Context, Report, Directory)
    else
    begin
      Deck := DeckName(ResolveDeck(Context));
      if Path = '' then
      begin
        Path := Context.LibraryFile.DeckSourcePath(Context.Database, Deck);
        if (Pos('/', Path) > 0) or (Pos('\', Path) > 0) then
          raise EScuError.Create('The recorded deck source is in a subdirectory. Specify source_file as a filename in the library directory.');
      end;
      Report.Imported(Context, Deck, Directory + Path, '');
    end;
    Result := Report.Finish(Context);
  finally
    Report.Free;
  end;
end;

end.
