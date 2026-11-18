unit ScuVerifyDecks;
{$mode objfpc}{$H+}
interface
uses ScuCommandHandler;
function VerificationDirectory(const Context: TCommandContext): string;
function VerifyDecks(var Context: TCommandContext): string;
implementation
uses
  ScuArchiveCompatibility, ScuWorkingExports, Classes, SysUtils, FPJSON, ScuCodec, ScuErrors, ScuDeckExport, ScuExportTypes, ScuExportManifest,
  ScuFiles, ScuExportPaths, ScuLibrary, ScuSignals, ScuTable, ScuTerminal, ScuExportNames;
type
  TDeckFileIssue = (dfMissing, dfEdited, dfOutdated, dfDeleted, dfInterrupted, dfUntracked, dfUnavailable);
  TDeckFileIssues = set of TDeckFileIssue;
  TDeckFileCheck = record
    FileName, Deck, Exported, Latest, Error: string;
    Mode: TExportMode;
    HasMode: Boolean;
    Issues: TDeckFileIssues;
  end;
  TDeckVerifier = class
  private
    FContext: TCommandContext; // Resources are borrowed for this command only.
    FTable: TScuTable;
    FSeen, FDetails, FAttention: TStringList;
    FFileKeys: TExportFileKeys;
    FCount, FDifferences: Integer;
    FLegacyCopy: Boolean;
    function CurrentBytes(const Entry: TExportRecord; const Selection: TDeckSelection): TRenderedDeck;
    procedure CheckEntry(const Entry: TExportRecord);
    procedure FindUntracked;
    procedure AddRow(const Check: TDeckFileCheck);
    procedure WriteAttention;
  public
    constructor Create(const Context: TCommandContext);
    destructor Destroy; override;
    function Run: string;
  end;

function VerificationDirectory(const Context: TCommandContext): string;
begin
  Result := Context.Command['output_directory'];
  if SameText(Result, ExportDirectorySelector) then
    Exit(DefaultExportDirectory(Context.LibraryPath));
  if SameText(Result, 'scu$library_directory') then
    Result := ExtractFileDir(CanonicalFile(Context.LibraryPath));
end;

function IssueLabel(const Issues: TDeckFileIssues): string;
begin
  if dfInterrupted in Issues then Exit('interrupted');
  if dfUnavailable in Issues then Exit('unavailable');
  if dfDeleted in Issues then Exit('deleted');
  if dfUntracked in Issues then Exit('untracked');
  if dfMissing in Issues then Exit('missing');
  if [dfEdited, dfOutdated] <= Issues then Exit('outdated+edited');
  if dfOutdated in Issues then Exit('outdated');
  if dfEdited in Issues then Exit('edited');
  Result := 'current';
end;

function AttentionReason(const Check: TDeckFileCheck; const Version: string): string;
  procedure Explain(const Text: string);
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + Text;
  end;
begin
  Result := '';
  if dfUnavailable in Check.Issues then
    Explain('unavailable: ' + Check.Error)
  else
  begin
    if dfDeleted in Check.Issues then
      Explain(Format('deleted. Deck is deleted in library version %s at %s.', [Version, Check.Latest]))
    else if dfOutdated in Check.Issues then
    begin
      Explain('outdated.');
      if Check.Exported <> Check.Latest then
        Explain(Format('Exported deck version %s; latest deck version %s.', [Check.Exported, Check.Latest]))
      else if Check.Mode = emExpand then
        Explain('Generated output differs from the selected snapshot (release macro expansion).')
      else Explain('Stored source bytes differ from the recorded export.');
    end;
    if dfMissing in Check.Issues then Explain('missing. Output file does not exist.');
    if dfEdited in Check.Issues then Explain('locally modified. File checksum differs from its recorded export.');
    if dfUntracked in Check.Issues then Explain('untracked. No export record exists for this file.');
  end;
  if dfInterrupted in Check.Issues then
    Explain('interrupted export. Recovery could not confirm completion; re-export this file with replace=yes to resolve it.');
end;

constructor TDeckVerifier.Create(const Context: TCommandContext);
begin
  inherited Create;
  FContext := Context;
  FTable := TScuTable.Create(['File', 'Mode', 'Exported', 'Latest', 'Status']);
  FDetails := TStringList.Create;
  FAttention := TStringList.Create;
  FFileKeys := TExportFileKeys.Create;
  FSeen := TStringList.Create;
  FSeen.Sorted := True;
  FSeen.CaseSensitive := True;
  FSeen.Duplicates := dupIgnore;
end;

destructor TDeckVerifier.Destroy;
begin
  FAttention.Free; FDetails.Free; FSeen.Free; FFileKeys.Free; FTable.Free;
  inherited Destroy;
end;

function TDeckVerifier.CurrentBytes(const Entry: TExportRecord; const Selection: TDeckSelection): TRenderedDeck;
begin
  Result := RenderDeck(FContext.LibraryFile, FContext.Database, Entry.Deck, Selection,
    Entry.Mode, Entry.ExpansionUTC);
end;

procedure TDeckVerifier.AddRow(const Check: TDeckFileCheck);
var ModeName: string;
begin
  if Check.HasMode then ModeName := ExportModeName(Check.Mode) else ModeName := '-';
  FTable.AddRow([Check.FileName, ModeName, Check.Exported, Check.Latest, IssueLabel(Check.Issues)]);
  if (Check.FileName <> Check.Deck) and (Check.FileName <> Check.Deck + '.scu') then
    FDetails.Add(Format('File "%s" is deck "%s".', [StringToJSONString(Check.FileName), Check.Deck]));
  if Check.Issues <> [] then
  begin
    Inc(FDifferences);
    FAttention.Add(Format('Deck "%s", file "%s": %s', [Check.Deck, StringToJSONString(Check.FileName),
      AttentionReason(Check, FContext.Snapshots.Selected.Version)]));
  end;
end;

procedure TDeckVerifier.WriteAttention;
var Item: string;
begin
  if FAttention.Count = 0 then Exit;
  FContext.Output.WriteLine('');
  FContext.Output.WriteLine(FormatTerminalLines('Needs attention:', FContext.Output.Columns));
  for Item in FAttention do
  begin
    CheckSessionInterrupt;
    FContext.Output.WriteLine(FormatTerminalLines(Item, FContext.Output.Columns, 2));
  end;
end;

procedure TDeckVerifier.CheckEntry(const Entry: TExportRecord);
var
  Check: TDeckFileCheck;
  Path, ActualHash: string;
  Rendered: TRenderedDeck;
  Selection: TDeckSelection;
  Source: TDeckSource;
begin
  CheckSessionInterrupt;
  FSeen.Add(FFileKeys.Key(Entry.FileName));
  if not SameExportLibrary(Entry.LibraryPath, CanonicalFile(FContext.LibraryPath)) then Exit;
  Inc(FCount);
  Check := Default(TDeckFileCheck);
  Check.FileName := Entry.FileName;
  Check.Deck := Entry.Deck;
  Check.Mode := Entry.Mode;
  Check.HasMode := True;
  Check.Exported := Entry.DeckVersion;
  Check.Latest := '-';
  Path := IncludeTrailingPathDelimiter(FContext.OutputDirectory) + Entry.FileName;
  ActualHash := '';
  try
    CheckExportTarget(Path);
    if RegularFileExists(Path) then ActualHash := AuditSHA256(ReadBytes(Path, MaxDeckSize));
    if ActualHash = '' then Include(Check.Issues, dfMissing)
    else if ActualHash <> Entry.SHA256 then Include(Check.Issues, dfEdited);
    Selection := FContext.LibraryFile.SelectDeck(Entry.Deck, FContext.Snapshots.Selected.Version, '');
    if Selection.RootRevision > 0 then Check.Latest := FContext.LibraryFile.DeckVersion[Selection.RootRevision];
    if (Selection.RootRevision > 0) and FContext.LibraryFile.RevisionDeleted[Selection.RootRevision] then
    begin
      Source := FContext.LibraryFile.ReadDeckMetadata(FContext.Database, Entry.Deck,
        Selection.RootRevision, FContext.Snapshots.Selected.Version, [deoAllowDeleted]);
      Check.Latest := Source.DeckVersion;
      Include(Check.Issues, dfDeleted);
    end
    else
    begin
      Rendered := CurrentBytes(Entry, Selection);
      FLegacyCopy := FLegacyCopy or Rendered.LegacyCopy;
      Check.Latest := Rendered.DeckVersion;
      if (Check.Latest <> Entry.DeckVersion) or (AuditSHA256(Rendered.Bytes) <> Entry.SHA256) then
        Include(Check.Issues, dfOutdated);
    end;
  except
    on E: EScuError do begin Include(Check.Issues, dfUnavailable); Check.Error := E.Message; end;
  end;
  if Entry.Interrupted then Include(Check.Issues, dfInterrupted);
  AddRow(Check);
end;

procedure TDeckVerifier.FindUntracked;
var
  Names: TStringList;
  Name, Path: string;
  Selection: TDeckSelection;
  Source: TDeckSource;
  Check: TDeckFileCheck;
begin
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    Names.CaseSensitive := True;
    Names.Duplicates := dupIgnore;
    FContext.LibraryFile.ChangedDecks(0, FContext.Snapshots.Selected.LibraryRevision, Names);
    for Name in Names do
      begin
        if not FContext.LibraryFile.TryDeckSnapshot(Name, FContext.Snapshots.Selected.LibraryRevision, Selection.Snapshot) then Continue;
        Check := Default(TDeckFileCheck);
        Check.FileName := Name;
        Check.Deck := Name;
        Check.Exported := '-'; Check.Latest := '-';
        CheckSessionInterrupt;
        try
          Source := FContext.LibraryFile.ReadDeckMetadata(FContext.Database, Name, Selection.Snapshot.LibraryRevision);
          Check.FileName := Source.SourcePath;
          ValidateExportFileName(Check.FileName);
          if FSeen.IndexOf(FFileKeys.Key(Check.FileName)) >= 0 then Continue;
          Path := IncludeTrailingPathDelimiter(FContext.OutputDirectory) + Check.FileName;
          CheckExportTarget(Path);
          if not RegularFileExists(Path) then Continue;
          Include(Check.Issues, dfUntracked);
        except
          on E: ECommandCancelled do raise;
          on E: EScuError do begin Include(Check.Issues, dfUnavailable); Check.Error := E.Message; end;
        end;
        FSeen.Add(FFileKeys.Key(Check.FileName));
        Inc(FCount);
        AddRow(Check);
      end;
  finally
    Names.Free;
  end;
end;

function TDeckVerifier.Run: string;
var
  Manifest: TExportManifest;
  Files: TStringList;
  Index: Integer;
  Detail: string;
begin
  RequireArchiveSourceNames(FContext.LibraryFile, FContext.Database);
  if SameExportLibrary(FContext.OutputDirectory, ExtractFileDir(CanonicalFile(FContext.LibraryPath))) then
    RefreshWorkingExports(FContext.Database, FContext.LibraryPath);
  Manifest := TExportManifest.Create(FContext.OutputDirectory);
  Files := nil;
  try
    Manifest.Recover;
    Files := TStringList.Create;
    Files.CaseSensitive := True; Files.Sorted := True;
    for Index := 0 to Manifest.Count - 1 do Files.AddObject(Manifest[Index].FileName, TObject(PtrInt(Index)));
    for Index := 0 to Files.Count - 1 do CheckEntry(Manifest[PtrInt(Files.Objects[Index])]);
    FindUntracked;
    if FLegacyCopy then FContext.Output.Report('Warning: COPY is no longer expanded; COPY directives are released as literal source.');
    FTable.WriteTo(FContext.Output, FContext.Output.Columns);
    if FDetails.Count > 0 then FContext.Output.WriteLine('');
    for Detail in FDetails do
      FContext.Output.WriteLine(FormatTerminalLines(Detail, FContext.Output.Columns, 2));
    WriteAttention;
    if FDifferences > 0 then
    begin
      FContext.Output.Flush;
      raise EScuError.CreateFmt('%d of %d deck file(s) need attention.', [FDifferences, FCount]);
    end;
    Result := Format('Verified %d deck file(s) against version %s. No errors were found.', [FCount, FContext.Snapshots.Selected.Version]);
  finally
    Files.Free; Manifest.Free;
  end;
end;

function VerifyDecks(var Context: TCommandContext): string;
var Verifier: TDeckVerifier;
begin
  Context.Snapshots.Selected := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['version']);
  Context.Snapshots.OutputDirectory := Context.OutputDirectory;
  Verifier := TDeckVerifier.Create(Context);
  try Result := Verifier.Run; finally Verifier.Free; end;
end;
end.
