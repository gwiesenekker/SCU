unit ScuVerifyDecks;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function VerificationDirectory(const Context: TCommandContext): string;
function VerifyDecks(var Context: TCommandContext): string;

implementation

uses
  Classes, SysUtils, FPJSON, ScuCodec, ScuErrors, ScuExpand, ScuExportManifest,
  ScuFiles, ScuLibrary, ScuSignals, ScuTable, ScuTerminal;

type
  TDeckVerifier = class
  private
    FContext: ^TCommandContext;
    FTable: TScuTable;
    FSeen, FDetails, FAttention: TStringList;
    FCount, FDifferences: Integer;
    function CurrentBytes(Entry: TJSONObject; var Latest: string): RawByteString;
    procedure CheckEntry(Entry: TJSONObject);
    procedure FindUntracked;
    procedure AddRow(const Name, Deck, Mode, Exported, Latest, Status: string);
    function AttentionReason(const Mode, Status, Exported, Latest: string): string;
    procedure WriteAttention;
  public
    constructor Create(var Context: TCommandContext);
    destructor Destroy; override;
    function Run: string;
  end;

function VerificationDirectory(const Context: TCommandContext): string;
begin
  Result := Context.Command['output_directory'];
  if SameText(Result, 'scu$library_directory') then
    Result := ExtractFileDir(CanonicalFile(Context.LibraryPath));
end;

constructor TDeckVerifier.Create(var Context: TCommandContext);
begin
  inherited Create;
  FContext := @Context;
  FTable := TScuTable.Create(['File', 'Mode', 'Exported', 'Latest', 'Status']);
  FDetails := TStringList.Create;
  FAttention := TStringList.Create;
  FSeen := TStringList.Create;
  FSeen.Sorted := True;
  FSeen.CaseSensitive := True;
  FSeen.Duplicates := dupIgnore;
end;

destructor TDeckVerifier.Destroy;
begin
  FAttention.Free;
  FDetails.Free;
  FSeen.Free;
  FTable.Free;
  inherited Destroy;
end;

function TDeckVerifier.CurrentBytes(Entry: TJSONObject; var Latest: string): RawByteString;
var
  Source: TDeckSource;
  Expander: TDeckExpander;
  Deck: string;
begin
  Deck := Entry.Strings['deck_name'];
  if Entry.Strings['mode'] = 'extract' then
  begin
    Source := FContext^.LibraryFile.Extract(FContext^.Database, Deck,
      FContext^.Snapshots.Selected.LibraryRevision, FContext^.Snapshots.Selected.Version);
    Latest := Source.DeckVersion;
    Exit(Source.Bytes);
  end;
  Expander := TDeckExpander.Create(FContext^.LibraryFile, FContext^.Database,
    FContext^.Snapshots.Selected.LibraryRevision, FContext^.Snapshots.Selected.Version,
    Entry.Strings['comment_prefix'], FContext^.Snapshots.Selected.Version, Entry.Strings['expansion_utc']);
  try
    Result := Expander.Expand(Deck);
    Latest := Expander.RootDeckVersion;
  finally
    Expander.Free;
  end;
end;

function TDeckVerifier.AttentionReason(const Mode, Status, Exported, Latest: string): string;
var
  Base: string;
  Interrupted: Boolean;

  procedure Explain(const Text: string);
  begin
    if (Result <> '') and not (Result[Length(Result)] in ['.', '!', '?']) then
      Result := Result + '.';
    Result := Result + ' ' + Text;
  end;

begin
  Result := Status;
  Base := Status;
  Interrupted := Pos('interrupted export', Base) = 1;
  if Interrupted then
    Delete(Base, 1, Length('interrupted export; '));
  if Pos('unavailable:', Base) <> 1 then
  begin
    if Pos('deleted', Base) = 1 then
      Explain(Format('Deck is deleted in library version %s at %s.',
        [FContext^.Snapshots.Selected.Version, Latest]))
    else if Pos('outdated', Base) = 1 then
    begin
      if Exported <> Latest then
        Explain(Format('Exported deck version %s; latest deck version %s.', [Exported, Latest]))
      else if Mode = 'expand' then
        Explain('Generated output differs from the selected snapshot (COPY or macro expansion).')
      else
        Explain('Stored source bytes differ from the recorded export.');
    end;
    if (Base = 'missing') or (Pos('; missing', Base) > 0) then
      Explain('Output file does not exist.');
    if (Base = 'locally modified') or (Pos('; locally modified', Base) > 0) then
      Explain('File checksum differs from its recorded export.');
    if Base = 'untracked' then
      Explain('No export record exists for this file.');
  end;
  if Interrupted then
    Explain('Recovery could not confirm completion; re-export this file to resolve it.');
end;

procedure TDeckVerifier.WriteAttention;
var
  Item: string;
  Columns: SizeInt;
begin
  if FAttention.Count = 0 then
    Exit;
  Columns := TerminalColumns(StdOutputHandle);
  FContext^.Output.WriteLine('');
  FContext^.Output.WriteLine(FormatTerminalLines('Needs attention:', Columns));
  for Item in FAttention do
  begin
    CheckSessionInterrupt;
    FContext^.Output.WriteLine(FormatTerminalLines(Item, Columns, 2));
  end;
end;

procedure TDeckVerifier.AddRow(const Name, Deck, Mode, Exported, Latest, Status: string);
var
  LabelText: string;
begin
  LabelText := Status;
  if Pos('interrupted export', Status) = 1 then
    LabelText := 'interrupted'
  else if Pos('unavailable:', Status) = 1 then
    LabelText := 'unavailable'
  else if Pos('deleted', Status) = 1 then
    LabelText := 'deleted'
  else if Status = 'locally modified' then
    LabelText := 'edited'
  else if Status = 'outdated; locally modified' then
    LabelText := 'outdated+edited';
  FTable.AddRow([Name, Mode, Exported, Latest, LabelText]);
  if (Name <> Deck) and (Name <> Deck + '.scu') then
    FDetails.Add(Format('File "%s" is deck "%s".', [StringToJSONString(Name), Deck]));
  if Status <> 'current' then
    FAttention.Add(Format('Deck "%s", file "%s": %s', [Deck, StringToJSONString(Name),
      AttentionReason(Mode, Status, Exported, Latest)]));
end;

procedure TDeckVerifier.CheckEntry(Entry: TJSONObject);
var
  Name, Path, Latest, Status, OriginalHash, ActualHash, ExpectedHash: string;
  Bytes: RawByteString;
  Outdated, Modified: Boolean;
  Selection: TDeckSelection;
  DeletedSource: TDeckSource;
begin
  CheckSessionInterrupt;
  Name := Entry.Strings['file'];
  FSeen.Add(Name);
  if Entry.Strings['library'] <> CanonicalFile(FContext^.LibraryPath) then
    Exit;
  Inc(FCount);
  Path := IncludeTrailingPathDelimiter(FContext^.OutputDirectory) + Name;
  Latest := '-';
  Status := '';
  OriginalHash := Entry.Strings['sha256'];
  ActualHash := '';
  try
    if RegularFileExists(Path) then
      ActualHash := AuditSHA256(ReadBytes(Path, MaxDeckSize));
    Selection := FContext^.LibraryFile.SelectDeck(Entry.Strings['deck_name'],
      FContext^.Snapshots.Selected.Version, '');
    if Selection.RootRevision > 0 then
      Latest := FContext^.LibraryFile.DeckVersion[Selection.RootRevision];
    if (Selection.RootRevision > 0) and FContext^.LibraryFile.RevisionDeleted[Selection.RootRevision] then
    begin
      DeletedSource := FContext^.LibraryFile.Extract(FContext^.Database, Entry.Strings['deck_name'],
        Selection.RootRevision, FContext^.Snapshots.Selected.Version, True);
      Latest := DeletedSource.DeckVersion;
      Status := 'deleted';
      if ActualHash = '' then
        Status := Status + '; missing'
      else if ActualHash <> OriginalHash then
        Status := Status + '; locally modified';
    end
    else
    begin
      Bytes := CurrentBytes(Entry, Latest);
      ExpectedHash := AuditSHA256(Bytes);
      Outdated := (Latest <> Entry.Strings['deck_version']) or (ExpectedHash <> OriginalHash);
      Modified := (ActualHash <> '') and (ActualHash <> OriginalHash);
      if ActualHash = '' then
        Status := 'missing'
      else if (ActualHash = ExpectedHash) and not Outdated then
        Status := 'current'
      else
      begin
        if Outdated then
          Status := 'outdated';
        if Modified then
        begin
          if Status <> '' then
            Status := Status + '; ';
          Status := Status + 'locally modified';
        end;
      end;
    end;
  except
    on E: ECommandCancelled do raise;
    on E: EScuError do Status := 'unavailable: ' + E.Message;
  end;
  if Latest = '' then
    Latest := '-';
  if Entry.Get('interrupted_export', False) then
  begin
    if Status = 'current' then
      Status := 'interrupted export'
    else
      Status := 'interrupted export; ' + Status;
  end;
  if Status <> 'current' then
    Inc(FDifferences);
  AddRow(Name, Entry.Strings['deck_name'], Entry.Strings['mode'], Entry.Strings['deck_version'], Latest, Status);
end;

procedure TDeckVerifier.FindUntracked;
var
  Names: TStringList;
  Name, FileName, Path: string;
  Suffix: Integer;
begin
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    Names.CaseSensitive := True;
    Names.Duplicates := dupIgnore;
    FContext^.LibraryFile.ChangedDecks(0, FContext^.Snapshots.Selected.LibraryRevision, Names);
    for Name in Names do
      for Suffix := 0 to 1 do
      begin
        FileName := Name;
        if Suffix = 1 then
          FileName := Name + '.scu';
        if FSeen.IndexOf(FileName) >= 0 then
          Continue;
        CheckSessionInterrupt;
        Path := IncludeTrailingPathDelimiter(FContext^.OutputDirectory) + FileName;
        if RegularFileExists(Path) then
        begin
          FSeen.Add(FileName);
          Inc(FCount);
          Inc(FDifferences);
          AddRow(FileName, Name, '-', '-', '-', 'untracked');
        end;
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
  Manifest := TExportManifest.Create(FContext^.OutputDirectory);
  Files := nil;
  try
    Files := TStringList.Create;
    Files.CaseSensitive := True;
    Files.Sorted := True;
    for Index := 0 to Manifest.Count - 1 do
      Files.AddObject(Manifest[Index].Strings['file'], Manifest[Index]);
    for Index := 0 to Files.Count - 1 do
      CheckEntry(TJSONObject(Files.Objects[Index]));
    FindUntracked;
    FTable.WriteTo(FContext^.Output, TerminalColumns(StdOutputHandle));
    if FDetails.Count > 0 then
    begin
      FContext^.Output.WriteLine('');
      for Detail in FDetails do
      begin
        CheckSessionInterrupt;
        FContext^.Output.WriteLine(FormatTerminalLines(Detail, TerminalColumns(StdOutputHandle), 2));
      end;
    end;
    WriteAttention;
    if FDifferences > 0 then
    begin
      FContext^.Output.Flush;
      raise EScuError.CreateFmt('%d of %d deck file(s) need attention.', [FDifferences, FCount]);
    end;
    Result := Format('Verified %d deck file(s) against version %s. No errors were found.', [FCount, FContext^.Snapshots.Selected.Version]);
  finally
    Files.Free;
    Manifest.Free;
  end;
end;

function VerifyDecks(var Context: TCommandContext): string;
var
  Verifier: TDeckVerifier;
begin
  Context.Snapshots.Selected := Context.LibraryFile.ParseLibrarySnapshot(Context.Command['version']);
  Context.Snapshots.OutputDirectory := Context.OutputDirectory;
  Verifier := TDeckVerifier.Create(Context);
  try
    Result := Verifier.Run;
  finally
    Verifier.Free;
  end;
end;

end.
