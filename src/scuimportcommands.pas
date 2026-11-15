unit ScuImportCommands;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function ImportDeckCommand(var Context: TCommandContext): string;
function WorkingDirectory(const Context: TCommandContext): string;
procedure RefreshImportedFiles(const Context: TCommandContext);

implementation

uses
  ScuWorkingExports, ScuExportTypes, ScuLibraryNames, Classes, Contnrs, SysUtils, ScuCodec, ScuErrors, ScuFiles, ScuFileScan, ScuLibrary,
  ScuExportManifest, ScuSignals, ScuTable, ScuTerminal;

type
  TDeckImporter = class
  private
    FRows: TStringList;
    FNew, FChanged, FDeleted, FUnchanged: Integer;
    FExports: TExportManifest;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Imported(var Context: TCommandContext; const Deck, Path, RelativePath: string);
    procedure Deleted(var Context: TCommandContext; const Deck: string);
    function Finish(var Context: TCommandContext): string;
  end;

constructor TDeckImporter.Create;
begin
  inherited Create;
  FRows := TStringList.Create;
  FRows.Sorted := True;
  FRows.CaseSensitive := True;
end;

destructor TDeckImporter.Destroy;
begin
  FExports.Free;
  FRows.Free;
  inherited Destroy;
end;

procedure TDeckImporter.Imported(var Context: TCommandContext;
  const Deck, Path, RelativePath: string);
var
  Snapshot: TLibrarySnapshot;
  Bytes: RawByteString;
  Sequence: Integer;
  Existed: Boolean;
  Status: string;
  Entry: TExportRecord;
  Selection: TDeckSelection;
begin
  CheckSessionInterrupt;
  if not Assigned(FExports) then
    FExports := TExportManifest.Create(ExtractFileDir(Context.LibraryPath));
  if FExports.IsGeneratedFile(ExtractFileName(Path)) then
    raise EScuError.Create('Refusing to import generated expansion "' + Path + '". Import the original source with COPY directives and macros instead.');
  Existed := Context.LibraryFile.TryDeckSnapshot(Deck, Context.LibraryFile.Revision, Snapshot);
  Bytes := ReadBytes(Path, MaxDeckSize, [rbNoFollow]);
  Sequence := Context.LibraryFile.Store(Context.Database, Deck, Bytes, [],
    PrefixArgument(Context.Command), RelativePath);
  Selection := Context.LibraryFile.SelectDeck(Deck, '', '');
  Entry := Default(TExportRecord);
  Entry.FileName := RelativePath;
  Entry.Deck := Deck;
  Entry.LibraryVersion := Selection.Snapshot.Version;
  if Sequence = 0 then Entry.DeckVersion := Context.LibraryFile.DeckVersion[Selection.RootRevision]
  else Entry.DeckVersion := Context.LibraryFile.DeckVersion[Sequence];
  Entry.SHA256 := AuditSHA256(Bytes);
  QueueWorkingExport(Context.Database, Entry);
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

procedure TDeckImporter.Deleted(var Context: TCommandContext; const Deck: string);
var
  Sequence: Integer;
  Entry: TExportRecord;
begin
  CheckSessionInterrupt;
  Entry := Default(TExportRecord);
  Entry.FileName := Context.LibraryFile.DeckSourcePath(Context.Database, Deck);
  Entry.Deck := Deck;
  Entry.LibraryVersion := Context.LibraryFile.CurrentVersion;
  Entry.DeckVersion := Context.LibraryFile.DeckVersion[Context.LibraryFile.SelectDeck(Deck, '', '').RootRevision];
  Entry.SHA256 := AuditSHA256('');
  QueueWorkingExport(Context.Database, Entry, True);
  Sequence := Context.LibraryFile.Delete(Context.Database, Deck);
  FRows.Add(Deck + #9 + Context.LibraryFile.DeckVersion[Sequence] + #9 + 'deleted');
  Inc(FDeleted);
end;

function TDeckImporter.Finish(var Context: TCommandContext): string;
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
      Table.WriteTo(Context.Output, Context.Output.Columns);
    finally
      Table.Free;
    end;
  end;
  Context.Snapshots.Selected := Context.LibraryFile.CurrentSnapshot;
  Result := Format('Imported %d new, %d changed, %d deleted; %d unchanged.',
    [FNew, FChanged, FDeleted, FUnchanged]);
end;

procedure ImportPatterns(var Context: TCommandContext; Report: TDeckImporter; const Directory: string);
var
  Patterns: TStringList;
  Scan: TLibraryFileScan;
  Decks: TDeckListEntries;
  Index: Integer;
  Path, PreviousPath: string;
  Snapshot: TLibrarySnapshot;
  Owners: TFPHashObjectList;
  Owner: TDeckFileBinding;
begin
  Patterns := TStringList.Create;
  Scan := nil;
  Owners := TFPHashObjectList.Create(True);
  try
    for Index := 0 to Context.LibraryFile.FilePatternCount - 1 do
      Patterns.Add(Context.LibraryFile.FilePatterns[Index]);
    Decks := Context.LibraryFile.DeckList(Context.LibraryFile.Revision);
    for Index := 0 to Length(Decks) - 1 do
      if Context.LibraryFile.DeckFileBacked(Context.Database, Decks[Index].Name) then
      begin
        Path := Context.LibraryFile.DeckSourcePath(Context.Database, Decks[Index].Name);
        Owner := TDeckFileBinding(Owners.Find(Path));
        if Assigned(Owner) then
          Owner.Deck := ''
        else
        begin
          Owner := TDeckFileBinding.Create;
          Owner.Deck := Decks[Index].Name;
          Owners.Add(Path, Owner);
        end;
      end;
    Scan := TLibraryFileScan.Create(Directory, Context.LibraryPath, Patterns, Owners);
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
      if Context.LibraryFile.DeckFileBacked(Context.Database, Decks[Index].Name) and
        Scan.Includes(Path) and not RegularFileExists(Directory + Path) then
        Report.Deleted(Context, Decks[Index].Name);
    end;
  finally
    Scan.Free;
    Owners.Free;
    Patterns.Free;
  end;
end;

function WorkingDirectory(const Context: TCommandContext): string;
begin
  Result := ExtractFileDir(CanonicalFile(Context.LibraryPath));
end;

procedure RefreshImportedFiles(const Context: TCommandContext);
begin
  try
    Context.Database.BeginTransaction;
    CheckSessionInterrupt;
    RefreshWorkingExports(Context.Database, Context.LibraryPath);
    CheckSessionInterrupt;
    Context.Database.Commit;
  except
    on E: ECommandCancelled do
    begin
      raise ECommandCancelled.Create('Import was saved; working-file manifest refresh was cancelled and remains pending.');
    end;
    on E: Exception do
      raise EScuError.Create('Import was saved; its working-file manifest update remains pending: ' + E.Message);
  end;
end;

function ImportDeckCommand(var Context: TCommandContext): string;
var
  Deck, Path, Directory: string;
  Report: TDeckImporter;
begin
  Context.LibraryFile.RequireOpenVersion;
  Directory := IncludeTrailingPathDelimiter(ExtractFileDir(Context.LibraryPath));
  Deck := Context.Command.Argument('deck_name');
  Path := Context.Command.Argument('source_file');
  if Context.Command.Provided['deck_name'] and (Deck = '') then
    raise EScuError.Create('deck_name was supplied empty. Omit it entirely to snapshot file_patterns.');
  if Context.Command.Provided['source_file'] and (Path = '') then
    raise EScuError.Create('source_file was supplied empty. Omit it to use the recorded source filename.');
  if Path <> '' then ValidateSourceFileName(Path);
  if (Deck = '') and (Path <> '') then
    raise EScuError.Create('Specify deck_name when using source_file; omit both to scan file_patterns.');
  if (Deck = '') and (Context.LibraryFile.FilePatternCount = 0) then
    Exit('No file patterns are configured. Use edit_file_patterns.');
  Report := TDeckImporter.Create;
  try
    if Deck = '' then
      ImportPatterns(Context, Report, Directory)
    else
    begin
      Deck := DeckName(ResolveDeck(Context));
      if Path = '' then
      begin
        Path := Context.LibraryFile.DeckSourcePath(Context.Database, Deck);
        if Pos('/', Path) > 0 then
          raise EScuError.Create('The recorded deck source is in a subdirectory. Specify source_file as a filename in the library directory.');
      end;
  Report.Imported(Context, Deck, Directory + Path, Path);
    end;
    Result := Report.Finish(Context);
  finally
    Report.Free;
  end;
end;

end.
