unit ScuGuiMain;
{$mode objfpc}{$H+}
interface
uses ScuGuiOptions, uManualForm, Classes, SysUtils, Contnrs, Forms, Controls, ExtCtrls, Menus, ComCtrls, ScuCommand,
  ScuCommands, Graphics, FPJSON, ScuGuiLayout, ScuGuiProcess, ScuGuiTab, ScuGuiPreferences, ScuGuiLiveDiff;
type
  TGuiJobKind = (gjCommand, gjSave, gjDiff);
  TGuiJob = class
    Command: TScuCommand;
    Kind: TGuiJobKind;
    Document: TScuEditorTab; // Borrowed; tabs cannot close while jobs run.
    Response: RawByteString;
    TemplateDirectory: string;
    destructor Destroy; override;
  end;
  TScuMainForm = class(TScuWorkspaceForm)
  private
    FCatalog: TCommandCatalog;
    FPreferences: TScuGuiPreferences;
    FProcess: TGuiCommandProcess;
    FJobs: TObjectList;
    FCloseRequests: TList;
    FTimer: TTimer;
    FPreview: TGuiLiveDiff;
    FPreviewPending, FHasPrevious: Boolean;
    FPreviewDue, FDiffGeneration: QWord;
    FPreviewLogKey: string;
    FLibraryPath, FExecutable, FLastError, FLogPending: string;
    FUpdating, FDiffPending, FAfterClose, FQuitAfterClose: Boolean;
    FOpenAfterClose: string;
    FCloseTabAfter: TScuEditorTab;
    FManual: TManualForm;
    FVersionLocked: Boolean;
    FLockMenu, FUnlockMenu: TMenuItem;
    FOpenMenu, FCloseMenu, FCreateMenu, FPublishMenu, FQuitMenu: TMenuItem;
    FLogMenu: TPopupMenu;
    FLogCopy, FLogSelectAll: TMenuItem;
    function ActiveDocument: TScuEditorTab;
    function GetBusy: Boolean;
    function Comparing: Boolean;
    procedure LogLine(const Message: string);
    procedure Error(const Message: string);
    procedure CommandError(const CommandName, Details: string);
    procedure LogPopup(Sender: TObject);
    procedure LogCopy(Sender: TObject);
    procedure LogSelectAll(Sender: TObject);
    procedure OutputReceived(Sender: TObject; const Bytes: RawByteString);
    procedure CommandFinished(Sender: TObject; ExitCode: Integer);
    procedure Tick(Sender: TObject);
    function LiveSelected: Boolean;
    procedure ScheduleLiveDiff;
    procedure StartLiveDiff;
    procedure PollLiveDiff;
    procedure CancelScheduledPreview;
    function AddJob(const CommandName: string; const Parameters: array of string;
      Kind: TGuiJobKind = gjCommand; Document: TScuEditorTab = nil): TGuiJob;
    procedure StartNext;
    procedure QueueSave(Document: TScuEditorTab);
    procedure SaveAll;
    procedure RefreshActions;
    function DeckListIndex(const Deck: string): Integer;
    procedure RefreshDecks;
    procedure RefreshVersions(KeepSelection: Boolean = False);
    procedure RequestDiff;
    procedure SelectionChanged(Sender: TObject);
    procedure VersionChanged(Sender: TObject);
    procedure TabChanged(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure ExtractClick(Sender: TObject);
    procedure ExtractAllClick(Sender: TObject);
    procedure CloseTabClick(Sender: TObject);
    procedure CloseDocument(Document: TScuEditorTab);
    procedure TabCloseRequested(Sender: TObject; Page: TTabSheet);
    procedure DocumentChanged(Sender: TObject);
    procedure ManualClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure PublishClick(Sender: TObject);
    procedure FileMenuClick(Sender: TObject);
    procedure LockVersionClick(Sender: TObject);
    procedure UnlockVersionClick(Sender: TObject);
    procedure CreateVersionClick(Sender: TObject);
    procedure QuitClick(Sender: TObject);
    procedure PreferencesClick(Sender: TObject);
    procedure Closing(Sender: TObject; var CanClose: Boolean);
    procedure KeyPressed(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ClearLibrary;
    procedure FinishTransition;
    function RequestTransition(const NewLibrary: string; Quit: Boolean): Boolean;
  protected
    function ConfirmDeckClose(Document: TScuEditorTab): Integer; virtual;
    procedure DisplayCommandError(const CommandName, Details: string); virtual;
    function PromptNewVersion(var Version: string): Boolean; virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure OpenLibrary(const Path: string);
    procedure OpenInitialLibrary(const Path: string);
    procedure CloseLibrary;
    procedure OpenDeck(const Deck: string);
    procedure SaveActive;
    procedure ExtractActive;
    procedure ExtractAll;
    procedure PublishVersion(const Version: string);
    procedure CreateNewVersion(const Version: string = '');
    procedure ApplyLibraryOptions(Dialog: TScuOptionsDialog);
    procedure SetEditorFont(Value: TFont);
    property Preferences: TScuGuiPreferences read FPreferences;
    property LibraryPath: string read FLibraryPath;
    property Busy: Boolean read GetBusy;
    property LastError: string read FLastError;
  end;
implementation
uses ButtonPanel, Dialogs, StdCtrls, LCLType, LCLProc, ScuGuiCommands, ScuGuiReader,
  ScuLibrary, ScuLibraryPaths, ScuFiles, ScuCleanupFiles, ScuPlatformPaths;
destructor TGuiJob.Destroy;
begin
  if TemplateDirectory <> '' then RemoveWorkingDirectory(TemplateDirectory);
  Command.Free;
  inherited Destroy;
end;
function MenuEntry(Owner: TComponent; Parent: TMenuItem; const Caption, Shortcut: string;
  Handler: TNotifyEvent): TMenuItem;
begin
  Result := TMenuItem.Create(Owner); Result.Caption := Caption;
  Result.ShortCut := TextToShortCut(Shortcut); Result.OnClick := Handler; Parent.Add(Result);
end;
constructor TScuMainForm.Create(AOwner: TComponent);
var EditMenu, HelpMenu: TMenuItem;
begin
  inherited Create(AOwner);
  FExecutable := IncludeTrailingPathDelimiter(ExtractFileDir(InvocationExecutablePath)) + ExecutableName('scu');
  FCatalog := TCommandCatalog.Create(IncludeTrailingPathDelimiter(ExtractFileDir(FExecutable)) + 'commands.json', True);
  FJobs := TObjectList.Create(True); FCloseRequests := TList.Create;
  FProcess := TGuiCommandProcess.Create;
  FProcess.OnOutput := @OutputReceived; FProcess.OnFinished := @CommandFinished;
  FTimer := TTimer.Create(Self); FTimer.Interval := 20; FTimer.OnTimer := @Tick;
  FOpenMenu := MenuEntry(Self, FFileMenu, '&Open library…', 'Ctrl+O', @OpenClick);
  FCloseMenu := MenuEntry(Self, FFileMenu, '&Close library', '', @CloseClick);
  FFileMenu.OnClick := @FileMenuClick;
  FLockMenu := MenuEntry(Self, FFileMenu, '&Lock version…', '', @LockVersionClick);
  FUnlockMenu := MenuEntry(Self, FFileMenu, '&Unlock version', '', @UnlockVersionClick);
  FCreateMenu := MenuEntry(Self, FFileMenu, '&Create new version…', '', @CreateVersionClick);
  FPublishMenu := MenuEntry(Self, FFileMenu, '&Publish version…', '', @PublishClick);
  MenuEntry(Self, FFileMenu, '-', '', nil);
  FQuitMenu := MenuEntry(Self, FFileMenu, '&Quit', 'Ctrl+Q', @QuitClick);
  EditMenu := TMenuItem.Create(Self); EditMenu.Caption := '&Edit'; Menu.Items.Add(EditMenu);
  MenuEntry(Self, EditMenu, '&Preferences…', '', @PreferencesClick);
  HelpMenu := TMenuItem.Create(Self); HelpMenu.Caption := '&Help'; Menu.Items.Add(HelpMenu);
  MenuEntry(Self, HelpMenu, '&Manual', 'F1', @ManualClick);
  FLogMenu := TPopupMenu.Create(Self); FLogMenu.OnPopup := @LogPopup;
  FLogCopy := TMenuItem.Create(Self); FLogCopy.Caption := 'Copy'; FLogCopy.OnClick := @LogCopy; FLogMenu.Items.Add(FLogCopy);
  FLogSelectAll := TMenuItem.Create(Self); FLogSelectAll.Caption := 'Select All'; FLogSelectAll.OnClick := @LogSelectAll;
  FLogMenu.Items.Add(FLogSelectAll); FLog.PopupMenu := FLogMenu;
  FPreferences := TScuGuiPreferences.Create;
  try FPreferences.Load; except on E: Exception do Error(E.Message); end;
  FSaveButton.OnClick := @SaveClick; FExtractButton.OnClick := @ExtractClick;
  FExtractAllButton.OnClick := @ExtractAllClick; FCloseTabButton.OnClick := @CloseTabClick;
  FTabBar.OnClose := @TabCloseRequested;
  FDeckList.OnClick := @SelectionChanged; FTabs.OnChange := @TabChanged;
  FFromVersion.OnChange := @VersionChanged; FToVersion.OnChange := @VersionChanged;
  KeyPreview := True; OnKeyDown := @KeyPressed; OnCloseQuery := @Closing;
  RefreshActions;
end;
destructor TScuMainForm.Destroy;
begin
  if Assigned(FTimer) then FTimer.Enabled := False;
  FUpdating := True;
  if Assigned(FPreview) then begin FPreview.WaitFor; FPreview.Free; end;
  FProcess.Free; FJobs.Free; FCloseRequests.Free; FCatalog.Free; FPreferences.Free;
  inherited Destroy;
end;
function TScuMainForm.ActiveDocument: TScuEditorTab;
begin
  Result := nil;
  if FTabs.ActivePage is TScuEditorTab then Result := TScuEditorTab(FTabs.ActivePage);
end;
function TScuMainForm.GetBusy: Boolean;
begin Result := Assigned(FProcess) and (FProcess.Running or (FJobs.Count > 0) or
  Assigned(FPreview) or FPreviewPending); end;
function TScuMainForm.Comparing: Boolean;
begin
  Result := ((FJobs.Count = 1) and (TGuiJob(FJobs[0]).Kind = gjDiff)) or
    ((FJobs.Count = 0) and (Assigned(FPreview) or FPreviewPending));
end;
procedure TScuMainForm.LogLine(const Message: string);
begin
  FLog.Lines.Add(Message);
  if FLog.Lines.Count > 5500 then
  begin
    FLog.Lines.BeginUpdate;
    try while FLog.Lines.Count > 5000 do FLog.Lines.Delete(0);
    finally FLog.Lines.EndUpdate; end;
  end;
  FLog.TopLine := FLog.Lines.Count;
end;
procedure TScuMainForm.Error(const Message: string);
begin FLastError := Message; FStatus.SimpleText := Message; LogLine('Error: ' + Message); end;
procedure TScuMainForm.DisplayCommandError(const CommandName, Details: string);
begin MessageDlg('SCU — ' + CommandName + ' failed', Details, mtError, [mbOK], 0); end;
procedure TScuMainForm.CommandError(const CommandName, Details: string);
var Summary, MessageText: string; I: Integer;
begin
  Summary := Trim(Details);
  for I := Length(Summary) downto 1 do
    if Summary[I] = #10 then begin Summary := Copy(Summary, I+1, MaxInt); Break; end;
  Error(CommandName + ' failed: ' + Summary);
  MessageText := Details;
  if (CommandName = 'import_deck') and (Pos('locked', LowerCase(Details)) > 0) then
    MessageText := MessageText + LineEnding + LineEnding +
      'Use File → Create new version… and save again. Your editor buffer has been retained.';
  DisplayCommandError(CommandName, MessageText);
end;
procedure TScuMainForm.LogPopup(Sender: TObject);
begin
  FLogCopy.Enabled := FLog.SelText <> '';
  FLogSelectAll.Enabled := FLog.Text <> '';
end;
procedure TScuMainForm.LogCopy(Sender: TObject);
begin FLog.CopyToClipboard; end;
procedure TScuMainForm.LogSelectAll(Sender: TObject);
begin FLog.SelectAll; end;
procedure TScuMainForm.OutputReceived(Sender: TObject; const Bytes: RawByteString);
var At: Integer; Job: TGuiJob;
begin
  if FJobs.Count > 0 then
  begin
    Job := TGuiJob(FJobs[0]);
    if Job.Kind = gjDiff then
    begin
      if Length(Job.Response) < 8 * 1024 * 1024 then
        Job.Response := Job.Response + Copy(Bytes, 1, 8 * 1024 * 1024 - Length(Job.Response));
    end
    else
    begin
      Job.Response := Job.Response + Bytes;
      if Length(Job.Response) > 65536 then Delete(Job.Response, 1, Length(Job.Response)-65536);
    end;
  end;
  FLogPending := FLogPending + Bytes;
  At := Pos(#10, FLogPending);
  while At > 0 do
  begin
    LogLine(Copy(FLogPending, 1, At - 1)); Delete(FLogPending, 1, At);
    At := Pos(#10, FLogPending);
  end;
  if Length(FLogPending) > 65536 then
  begin LogLine(FLogPending); FLogPending := ''; end;
end;
procedure TScuMainForm.Tick(Sender: TObject);
begin
  FProcess.Poll; PollLiveDiff;
  if FPreviewPending and not Assigned(FPreview) and not FProcess.Running and
    (FJobs.Count = 0) and (GetTickCount64 >= FPreviewDue) then StartLiveDiff;
end;
function TScuMainForm.LiveSelected: Boolean;
begin Result := (FFromVersion.Text = LiveDeckVersionSelector) or (FToVersion.Text = LiveDeckVersionSelector); end;
procedure TScuMainForm.ScheduleLiveDiff;
begin
  Inc(FDiffGeneration);
  if (FJobs.Count > 0) and (TGuiJob(FJobs[0]).Kind <> gjDiff) then
  begin FDiffPending := True; Exit; end;
  FPreviewPending := True; FPreviewDue := GetTickCount64 + 150;
  RefreshActions;
end;
procedure TScuMainForm.CancelScheduledPreview;
begin
  if FPreviewPending and not Assigned(FPreview) and not FProcess.Running then
  begin FPreviewPending := False; Inc(FDiffGeneration); RefreshActions; end;
end;
procedure TScuMainForm.StartLiveDiff;
var Document: TScuEditorTab; Draft, OldBytes, NewBytes: RawByteString;
  OldLabel, NewLabel, LogKey: string; Stored: TGuiDeck;
  procedure Resolve(const Selector: string; out Bytes: RawByteString; out LabelText: string);
  begin
    if Selector = LiveDeckVersionSelector then
    begin Bytes := Draft; LabelText := Document.Deck + '@' + LiveDeckVersionSelector + ' (editor buffer)'; end
    else
    begin
      Stored := ReadGuiDeckVersion(FLibraryPath, Document.Deck, Selector);
      Bytes := Stored.Bytes; LabelText := Document.Deck + '@' + Stored.DeckVersion;
      if Stored.Deleted then LabelText := '/dev/null';
    end;
  end;
begin
  FPreviewPending := False; FDiffPending := False; Document := ActiveDocument;
  if not Assigned(Document) or not LiveSelected then begin RefreshActions; Exit; end;
  try
    Draft := Document.SourceBytes;
    Resolve(FFromVersion.Text, OldBytes, OldLabel); Resolve(FToVersion.Text, NewBytes, NewLabel);
    LogKey := Document.Deck + ': ' + FFromVersion.Text + ' -> ' + FToVersion.Text;
    if LogKey <> FPreviewLogKey then
    begin LogLine('Preview diff: ' + LogKey + ' (editor buffer; no library command).'); FPreviewLogKey := LogKey; end;
    FPreview := TGuiLiveDiff.Create(OldBytes, NewBytes, OldLabel, NewLabel, FDiffGeneration);
    FStatus.SimpleText := 'Comparing live editor buffer…'; RefreshActions;
  except on E: Exception do begin Error(E.Message); StartNext; end; end;
end;
procedure TScuMainForm.PollLiveDiff;
var Preview: TGuiLiveDiff;
begin
  if not Assigned(FPreview) or not FPreview.Finished then Exit;
  Preview := FPreview; FPreview := nil;
  try
    Preview.WaitFor;
    if Preview.Generation = FDiffGeneration then
    begin
      if Preview.Error <> '' then Error(Preview.Error)
      else begin FDiff.Text := Preview.Text; FStatus.SimpleText := 'Live comparison updated; no library changes.'; end;
    end;
  finally Preview.Free; end;
  StartNext;
end;
function TScuMainForm.AddJob(const CommandName: string; const Parameters: array of string;
  Kind: TGuiJobKind; Document: TScuEditorTab): TGuiJob;
var Job: TGuiJob;
begin
  Job := TGuiJob.Create;
  try
    Job.Command := GuiCommand(FCatalog, CommandName, Parameters);
    Job.Kind := Kind; Job.Document := Document;
    FJobs.Add(Job); Result := Job; Job := nil;
  finally Job.Free; end;
end;
procedure TScuMainForm.StartNext;
var Job: TGuiJob; CloseTarget: TScuEditorTab; Failure, FailedCommand: string;
begin
  if FProcess.Running or Assigned(FPreview) or FPreviewPending then Exit;
  if FJobs.Count = 0 then
  begin
    RefreshActions;
    while FCloseRequests.Count > 0 do
    begin
      CloseTarget := TScuEditorTab(FCloseRequests[0]); FCloseRequests.Delete(0);
      CloseDocument(CloseTarget);
      if Busy then Exit;
    end;
    if Assigned(FCloseTabAfter) then
    begin
      FUpdating := True;
      try FreeAndNil(FCloseTabAfter); finally FUpdating := False; end;
      FTabBar.ShowActiveTab; RefreshVersions; FDiffPending := True;
    end;
    if FAfterClose then begin FinishTransition; Exit; end;
    if FDiffPending then begin FDiffPending := False; RequestDiff; end;
    Exit;
  end;
  Job := TGuiJob(FJobs[0]);
  try
    if Job.Kind = gjSave then Job.Document.PrepareSave;
    LogLine('scu> ' + CommandText(Job.Command));
    FStatus.SimpleText := 'Running ' + Job.Command.Name + '…';
    FProcess.Start(FExecutable, FLibraryPath, Job.Command);
    RefreshActions;
  except
    on E: Exception do
    begin
      Failure := E.Message; FailedCommand := Job.Command.Name;
      FJobs.Clear; FCloseRequests.Clear; FAfterClose := False; FCloseTabAfter := nil;
      FDiffPending := False; FPreviewPending := False; RefreshActions;
      CommandError(FailedCommand, Failure);
    end;
  end;
end;
procedure TScuMainForm.CommandFinished(Sender: TObject; ExitCode: Integer);
var Job: TGuiJob; Failed, ShowDialog: Boolean; Failure, FailedCommand: string;
begin
  if FLogPending <> '' then begin LogLine(FLogPending); FLogPending := ''; end;
  Job := TGuiJob(FJobs[0]); Failed := ExitCode <> 0; FailedCommand := Job.Command.Name;
  ShowDialog := Job.Kind <> gjDiff; Failure := '';
  try
    if Failed then
    begin
      Failure := Trim(Job.Response);
      if Failure = '' then Failure := 'Command exited with status ' + IntToStr(ExitCode) + '.';
    end
    else
    begin
      if Job.Kind = gjSave then
      begin
        Job.Document.AcceptSave(ReadGuiDeck(FLibraryPath, Job.Document.Deck));
        RefreshDecks; RefreshVersions(True); FDiffPending := True;
      end;
      if Job.Command.Name = 'lock_version' then FVersionLocked := True;
      if (Job.Command.Name = 'unlock_version') or (Job.Command.Name = 'create_version') then
        FVersionLocked := False;
      if (Job.Command.Name = 'create_version') or (Job.Command.Name = 'configure_library') then
      begin RefreshDecks; RefreshVersions(True); FDiffPending := Assigned(ActiveDocument); end;
      FStatus.SimpleText := Job.Command.Name + ' completed.';
    end;
    if (Job.Kind = gjDiff) and not FDiffPending and (Job.Document = ActiveDocument) then
      FDiff.Text := Job.Response;
  except on E: Exception do begin Failure := E.Message; Failed := True; end; end;
  FJobs.Delete(0);
  if Failed then
  begin
    FJobs.Clear; FCloseRequests.Clear; FAfterClose := False; FCloseTabAfter := nil;
    FDiffPending := False; FPreviewPending := False; Inc(FDiffGeneration);
    RefreshActions;
    if ShowDialog then CommandError(FailedCommand, Failure) else Error(Failure);
  end;
  StartNext;
end;
procedure TScuMainForm.QueueSave(Document: TScuEditorTab);
begin
  if Assigned(Document) and Document.Dirty then
    AddJob('import_deck', ['deck_name=' + Document.Deck, 'source_file=' + Document.SourceName], gjSave, Document);
end;
procedure TScuMainForm.SaveAll;
var I: Integer;
begin for I := 0 to FTabs.PageCount - 1 do QueueSave(TScuEditorTab(FTabs.Pages[I])); end;
procedure TScuMainForm.SaveActive;
begin CancelScheduledPreview; if Busy then Exit; FLastError := ''; QueueSave(ActiveDocument); StartNext; end;
procedure TScuMainForm.ExtractActive;
var Document: TScuEditorTab;
begin
  CancelScheduledPreview; if Busy then Exit; Document := ActiveDocument; if not Assigned(Document) then Exit;
  FLastError := ''; QueueSave(Document);
  AddJob('extract_deck', ['deck_name=' + Document.Deck]); StartNext;
end;
procedure TScuMainForm.ExtractAll;
begin
  CancelScheduledPreview; if Busy or (FLibraryPath = '') then Exit;
  FLastError := ''; SaveAll; AddJob('extract_version', []); StartNext;
end;
procedure TScuMainForm.PublishVersion(const Version: string);
begin
  CancelScheduledPreview; if Busy or (FLibraryPath = '') then Exit;
  FLastError := ''; SaveAll; AddJob('release_version', ['version=' + Version]); StartNext;
end;
procedure TScuMainForm.CreateNewVersion(const Version: string);
var Desired: string;
begin
  CancelScheduledPreview;
  if (FLibraryPath = '') or (Busy and not Comparing) then Exit;
  Desired := Version;
  if Desired = '' then Desired := ReadGuiLibraryState(FLibraryPath).NextVersion;
  FLastError := ''; FPreviewPending := False; Inc(FDiffGeneration);
  AddJob('create_version', ['version=' + Desired]); StartNext; RefreshActions;
end;
procedure TScuMainForm.ApplyLibraryOptions(Dialog: TScuOptionsDialog);
var Parameters: array of string; Directory, Path: string; I: Integer; Job: TGuiJob;
begin
  CancelScheduledPreview;
  if (FLibraryPath = '') or (Busy and not Comparing) then Exit;
  Dialog.CollectChanges;
  SetLength(Parameters, Dialog.Changes.Count + Ord(Dialog.TrackerChanged));
  if Length(Parameters) = 0 then Exit;
  for I := 0 to Dialog.Changes.Count - 1 do Parameters[I] := Dialog.Changes[I];
  Directory := '';
  try
    if Dialog.TrackerChanged then
    begin
      Directory := MakeTempDirectory('scu-gui-tracker');
      Path := IncludeTrailingPathDelimiter(Directory) + 'template.txt';
      AtomicWrite(Path, Dialog.TrackerField.Text);
      Parameters[High(Parameters)] := 'tracker_template_file=' + Path;
    end;
    Job := AddJob('configure_library', Parameters);
    Job.TemplateDirectory := Directory;
    Directory := '';
  finally
    if Directory <> '' then RemoveWorkingDirectory(Directory);
  end;
  FLastError := ''; FPreviewPending := False; Inc(FDiffGeneration);
  StartNext; RefreshActions;
end;
procedure TScuMainForm.RefreshActions;
var Idle, Opened, Browsing: Boolean;
begin
  if not Assigned(FProcess) then Exit;
  Idle := not Busy; Opened := FLibraryPath <> '';
  Browsing := Idle or Comparing;
  FOpenMenu.Enabled := Idle; FCloseMenu.Enabled := Idle and Opened;
  FLockMenu.Enabled := Browsing and Opened and not FVersionLocked;
  FUnlockMenu.Enabled := Browsing and Opened and FVersionLocked;
  FCreateMenu.Enabled := (Idle or Comparing) and Opened;
  FPublishMenu.Enabled := Idle and Opened; FQuitMenu.Enabled := Idle;
  FSaveButton.Enabled := Idle and Assigned(ActiveDocument);
  FExtractButton.Enabled := FSaveButton.Enabled; FCloseTabButton.Enabled := FSaveButton.Enabled;
  FExtractAllButton.Enabled := Idle and Opened;
  FTabs.Enabled := Browsing; FDeckList.Enabled := Browsing; FTabBar.Enabled := Browsing;
  FTabBar.RefreshTabs;
  FFromVersion.Enabled := Browsing and Assigned(ActiveDocument); FToVersion.Enabled := FFromVersion.Enabled;
end;
function TScuMainForm.DeckListIndex(const Deck: string): Integer;
begin
  for Result := 0 to FDeckList.Items.Count - 1 do
    if FDeckList.Items[Result] = Deck then Exit;
  Result := -1;
end;

procedure TScuMainForm.RefreshDecks;
var Entries: TDeckListEntries; Entry: TDeckListEntry; Selected: string;
begin
  Selected := ''; if FDeckList.ItemIndex >= 0 then Selected := FDeckList.Items[FDeckList.ItemIndex];
  Entries := ReadGuiDecks(FLibraryPath);
  FUpdating := True;
  FDeckList.Items.BeginUpdate;
  try
    FDeckList.Items.Clear;
    for Entry in Entries do FDeckList.Items.Add(Entry.Name);
    FDeckList.ItemIndex := DeckListIndex(Selected);
  finally FDeckList.Items.EndUpdate; FUpdating := False; end;
end;
procedure TScuMainForm.OpenInitialLibrary(const Path: string);
begin
  try OpenLibrary(Path);
  except on E: Exception do
    {$IFDEF WINDOWS}CommandError('Open library', E.Message);{$ELSE}
    WriteLn(StdErr, E.Message);{$ENDIF}
  end;
end;
procedure TScuMainForm.OpenLibrary(const Path: string);
var Normalized: string; State: TGuiLibraryState;
begin
  if Busy then raise Exception.Create('Wait for the current command before opening a library.');
  Normalized := CanonicalFile(NormalizeLibraryName(Path));
  State := ReadGuiLibraryState(Normalized, False); // Validate before replacing the existing session.
  if FLibraryPath <> '' then
  begin RequestTransition(Normalized, False); Exit; end;
  FVersionLocked := State.Locked;
  FLibraryPath := Normalized; FLastError := ''; Caption := 'SCU — ' + ExtractFileName(FLibraryPath);
  RefreshDecks; AddJob('display_library', []); StartNext;
end;
procedure TScuMainForm.OpenDeck(const Deck: string);
var I: Integer; Tab: TScuEditorTab;
begin
  if (Busy and not Comparing) or (FLibraryPath = '') then Exit;
  for I := 0 to FTabs.PageCount - 1 do
    if TScuEditorTab(FTabs.Pages[I]).Deck = Deck then
    begin
      FUpdating := True;
      try FTabs.ActivePage := FTabs.Pages[I]; finally FUpdating := False; end;
      FTabBar.ShowActiveTab; RefreshVersions; RequestDiff; Exit;
    end;
  Tab := TScuEditorTab.CreateDeck(Self, FLibraryPath, Deck, ReadGuiDeck(FLibraryPath, Deck));
  Tab.OnStateChanged := @DocumentChanged;
  Tab.Editor.Font.Assign(FPreferences.EditorFont);
  FUpdating := True;
  try Tab.PageControl := FTabs; FTabs.ActivePage := Tab; finally FUpdating := False; end;
  FTabBar.ShowActiveTab; RefreshVersions; RequestDiff; RefreshActions;
end;
procedure TScuMainForm.RefreshVersions(KeepSelection: Boolean);
var Versions: TStringList; Document: TScuEditorTab; FromChoice, ToChoice: string;
begin
  FromChoice := FFromVersion.Text; ToChoice := FToVersion.Text;
  FUpdating := True; Versions := TStringList.Create;
  try
    FFromVersion.Items.Clear; FToVersion.Items.Clear; Document := ActiveDocument;
    if not Assigned(Document) then begin FDiff.Clear; Exit; end;
    FDeckList.ItemIndex := DeckListIndex(Document.Deck);
    ReadGuiVersions(FLibraryPath, Document.Deck, Versions);
    FFromVersion.Items.Add(CurrentDeckVersionSelector); FFromVersion.Items.Add(PreviousDeckVersionSelector);
    FHasPrevious := Versions.Count > 1;
    FFromVersion.Items.Add(LiveDeckVersionSelector);
    FFromVersion.Items.AddStrings(Versions); FToVersion.Items.Assign(FFromVersion.Items);
    FFromVersion.ItemIndex := FFromVersion.Items.IndexOf(CurrentDeckVersionSelector);
    FToVersion.ItemIndex := FToVersion.Items.IndexOf(LiveDeckVersionSelector);
    if KeepSelection then
    begin
      if FFromVersion.Items.IndexOf(FromChoice) >= 0 then FFromVersion.ItemIndex := FFromVersion.Items.IndexOf(FromChoice);
      if FToVersion.Items.IndexOf(ToChoice) >= 0 then FToVersion.ItemIndex := FToVersion.Items.IndexOf(ToChoice);
    end;
  finally Versions.Free; FUpdating := False; end;
end;
procedure TScuMainForm.RequestDiff;
var Document: TScuEditorTab;
begin
  if FUpdating then Exit;
  Inc(FDiffGeneration); FPreviewPending := False;
  Document := ActiveDocument;
  if not Assigned(Document) then begin FDiffPending := False; RefreshActions; Exit; end;
  if Busy then begin FDiffPending := True; Exit; end;
  if ((FFromVersion.Text = PreviousDeckVersionSelector) or (FToVersion.Text = PreviousDeckVersionSelector)) and not FHasPrevious then
  begin FDiff.Text := 'No previous stored deck version. Save another revision to compare.'; RefreshActions; Exit; end;
  if LiveSelected then begin ScheduleLiveDiff; Exit; end;
  FPreviewLogKey := '';
  AddJob('display_deck_diff', ['deck_name=' + Document.Deck,
    'from_snapshot=' + FFromVersion.Text, 'to_snapshot=' + FToVersion.Text,
    'output_format=unified', 'ignore_space_changes=no'], gjDiff, Document);
  StartNext;
end;
procedure TScuMainForm.SelectionChanged(Sender: TObject);
begin
  if FUpdating or (FDeckList.ItemIndex < 0) then Exit;
  try OpenDeck(FDeckList.Items[FDeckList.ItemIndex]); except on E: Exception do Error(E.Message); end;
end;
procedure TScuMainForm.TabChanged(Sender: TObject);
begin
  if FUpdating then Exit;
  try FTabBar.ShowActiveTab; RefreshVersions; RequestDiff; RefreshActions; except on E: Exception do Error(E.Message); end;
end;
procedure TScuMainForm.VersionChanged(Sender: TObject);
begin if not FUpdating then RequestDiff; end;
procedure TScuMainForm.SaveClick(Sender: TObject);
begin try SaveActive; except on E: Exception do Error(E.Message); end; end;
procedure TScuMainForm.ExtractClick(Sender: TObject);
begin try ExtractActive; except on E: Exception do Error(E.Message); end; end;
procedure TScuMainForm.ExtractAllClick(Sender: TObject);
begin try ExtractAll; except on E: Exception do Error(E.Message); end; end;
procedure TScuMainForm.DocumentChanged(Sender: TObject);
begin
  FTabBar.RefreshTabs;
  if (Sender = ActiveDocument) and LiveSelected and not FUpdating then ScheduleLiveDiff;
end;
procedure TScuMainForm.TabCloseRequested(Sender: TObject; Page: TTabSheet);
begin
  if Page is TScuEditorTab then CloseDocument(TScuEditorTab(Page));
end;
procedure TScuMainForm.CloseTabClick(Sender: TObject);
begin CloseDocument(ActiveDocument); end;
function TScuMainForm.ConfirmDeckClose(Document: TScuEditorTab): Integer;
begin
  Result := MessageDlg('Save modified deck?', Document.Deck, mtConfirmation, [mbYes, mbNo, mbCancel], 0);
end;
procedure TScuMainForm.CloseDocument(Document: TScuEditorTab);
var Answer: Integer;
begin
  if not Assigned(Document) then Exit;
  if Busy then
  begin
    if Comparing and (FCloseRequests.IndexOf(Document) < 0) then FCloseRequests.Add(Document);
    Exit;
  end;
  if Document.Dirty then
  begin
    Answer := ConfirmDeckClose(Document);
    if Answer = mrCancel then Exit;
    if Answer = mrYes then
    begin FCloseTabAfter := Document; QueueSave(Document); StartNext; Exit; end;
  end;
  FUpdating := True;
  try Document.Free; finally FUpdating := False; end;
  FTabBar.ShowActiveTab; RefreshVersions; RequestDiff; RefreshActions;
end;
procedure TScuMainForm.ManualClick(Sender: TObject);
begin
  if FManual = nil then FManual := TManualForm.Create(Self);
  FManual.Show;
  FManual.BringToFront;
end;

procedure TScuMainForm.OpenClick(Sender: TObject);
var Dialog: TOpenDialog;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := 'Open SCU library'; Dialog.Filter := 'SCU SQLite libraries|*.sqlite';
    Dialog.Options := [ofFileMustExist, ofPathMustExist];
    if Dialog.Execute then
      try OpenLibrary(Dialog.FileName); except on E: Exception do Error(E.Message); end;
  finally Dialog.Free; end;
end;
procedure TScuMainForm.CloseClick(Sender: TObject);
begin CloseLibrary; end;
procedure TScuMainForm.PublishClick(Sender: TObject);
var Version: string;
begin
  Version := 'scu$current_version';
  if InputQuery('Publish version', 'Library version', Version) then
    try PublishVersion(Version); except on E: Exception do Error(E.Message); end;
end;
procedure TScuMainForm.FileMenuClick(Sender: TObject);
begin
  if (FLibraryPath = '') or (Busy and not Comparing) then Exit;
  try
    FVersionLocked := ReadGuiLibraryState(FLibraryPath, False).Locked;
    RefreshActions;
  except on E: Exception do Error(E.Message); end;
end;

procedure TScuMainForm.LockVersionClick(Sender: TObject);
var Dialog: TForm; Memo: TMemo; Buttons: TButtonPanel; LabelText: TLabel;
  Version, Description: string;
begin
  if (FLibraryPath = '') or (Busy and not Comparing) then Exit;
  try
    Version := ReadGuiLibraryState(FLibraryPath, False).CurrentVersion;
    Dialog := TForm.CreateNew(Self);
    try
      Dialog.Caption := 'Lock version ' + Version;
      Dialog.Position := poOwnerFormCenter;
      Dialog.ClientWidth := 520; Dialog.ClientHeight := 280;
      Dialog.BorderWidth := 12;
      Dialog.Color := clBtnFace;
      LabelText := TLabel.Create(Dialog); LabelText.Parent := Dialog; LabelText.Align := alTop;
      LabelText.BorderSpacing.Bottom := 6;
      LabelText.Caption := 'Describe the saved changes in version ' + Version + ':';
      Buttons := TButtonPanel.Create(Dialog); Buttons.Parent := Dialog;
      Buttons.ShowButtons := [pbOK, pbCancel];
      Buttons.ShowBevel := False;
      Buttons.Color := Dialog.Color;
      Buttons.ParentBackground := False;
      Buttons.BorderSpacing.Around := 0;
      Buttons.BorderSpacing.Top := 12;
      Buttons.OKButton.Caption := 'Lock version';
      Memo := TMemo.Create(Dialog); Memo.Parent := Dialog; Memo.Align := alClient;
      Memo.ScrollBars := ssAutoVertical; Memo.WantReturns := True;
      Dialog.ActiveControl := Memo;
      repeat
        if Dialog.ShowModal <> mrOK then Exit;
        Description := Memo.Text;
        if Trim(Description) <> '' then Break;
        LabelText.Caption := 'Enter a description before locking version ' + Version + ':';
      until False;
    finally Dialog.Free; end;
    if ReadGuiLibraryState(FLibraryPath, False).CurrentVersion <> Version then
      raise Exception.Create('The current version changed while entering the description.');
    CancelScheduledPreview;
    FLastError := '';
    AddJob('lock_version', ['description=' + Description]); StartNext;
  except on E: Exception do CommandError('lock_version', E.Message); end;
end;

procedure TScuMainForm.UnlockVersionClick(Sender: TObject);
begin
  if (FLibraryPath = '') or (Busy and not Comparing) then Exit;
  try
    CancelScheduledPreview;
    FLastError := '';
    AddJob('unlock_version', []); StartNext;
  except on E: Exception do CommandError('unlock_version', E.Message); end;
end;

function TScuMainForm.PromptNewVersion(var Version: string): Boolean;
begin Result := InputQuery('Create new version', 'New library version', Version); end;
procedure TScuMainForm.CreateVersionClick(Sender: TObject);
var Version: string;
begin
  try
    Version := ReadGuiLibraryState(FLibraryPath).NextVersion;
    if PromptNewVersion(Version) then CreateNewVersion(Version);
  except on E: Exception do CommandError('create_version', E.Message); end;
end;
procedure TScuMainForm.SetEditorFont(Value: TFont);
var I: Integer; SavedFont: TFont;
begin
  SavedFont := TFont.Create;
  try
    SavedFont.Assign(FPreferences.EditorFont);
    FPreferences.EditorFont.Assign(Value);
    try FPreferences.Save;
    except FPreferences.EditorFont.Assign(SavedFont); raise; end;
  finally SavedFont.Free; end;
  for I := 0 to FTabs.PageCount - 1 do
    TScuEditorTab(FTabs.Pages[I]).Editor.Font.Assign(FPreferences.EditorFont);
end;
procedure TScuMainForm.PreferencesClick(Sender: TObject);
var Dialog: TScuOptionsDialog; Configuration: TJSONObject; State: TGuiLibraryState;
begin
  Configuration := nil; Dialog := nil;
  try
    try
      State := Default(TGuiLibraryState);
      if (FLibraryPath <> '') and (not Busy or Comparing) then
      begin Configuration := ReadGuiConfiguration(FLibraryPath); State := ReadGuiLibraryState(FLibraryPath); end;
      Dialog := TScuOptionsDialog.CreateOptions(Self, FPreferences.EditorFont, Configuration, State.PrefixEditable);
      if Dialog.ShowModal = mrOK then
      begin
        Dialog.CollectChanges;
        if (Dialog.EditorFont.Name <> FPreferences.EditorFont.Name) or
          (Dialog.EditorFont.Size <> FPreferences.EditorFont.Size) or
          (Dialog.EditorFont.Style <> FPreferences.EditorFont.Style) then SetEditorFont(Dialog.EditorFont);
        ApplyLibraryOptions(Dialog);
      end;
    except on E: Exception do CommandError('preferences', E.Message); end;
  finally Dialog.Free; Configuration.Free; end;
end;
procedure TScuMainForm.QuitClick(Sender: TObject);
begin Close; end;
procedure TScuMainForm.ClearLibrary;
begin
  FPreviewPending := False; FPreviewLogKey := ''; Inc(FDiffGeneration);
  FUpdating := True;
  try
    FCloseRequests.Clear;
    while FTabs.PageCount > 0 do FTabs.Pages[0].Free;
    FDeckList.Clear; FDiff.Clear; FFromVersion.Clear; FToVersion.Clear;
    FTabBar.RefreshTabs;
    FLibraryPath := ''; FDiffPending := False; Caption := 'Source Code Utility';
    FStatus.SimpleText := 'Library closed.';
  finally FUpdating := False; end;
  RefreshActions;
end;
function TScuMainForm.RequestTransition(const NewLibrary: string; Quit: Boolean): Boolean;
var I, Answer: Integer; Dirty: Boolean;
begin
  Result := False;
  if Busy then begin Error('Wait for the current command to finish before closing.'); Exit; end;
  Dirty := False;
  for I := 0 to FTabs.PageCount - 1 do Dirty := Dirty or TScuEditorTab(FTabs.Pages[I]).Dirty;
  if Dirty then
  begin
    Answer := MessageDlg('Save modified decks?', 'Save all modified tabs before closing?',
      mtConfirmation, [mbYes, mbNo, mbCancel], 0);
    if Answer = mrCancel then Exit;
    if Answer = mrYes then
    begin
      FAfterClose := True; FQuitAfterClose := Quit; FOpenAfterClose := NewLibrary;
      SaveAll; StartNext; Exit;
    end;
  end;
  ClearLibrary; Result := True;
  if NewLibrary <> '' then OpenLibrary(NewLibrary);
end;
procedure TScuMainForm.FinishTransition;
var NextLibrary: string; Quit: Boolean;
begin
  NextLibrary := FOpenAfterClose; Quit := FQuitAfterClose;
  FAfterClose := False; FOpenAfterClose := ''; FQuitAfterClose := False;
  ClearLibrary;
  if Quit then Close else if NextLibrary <> '' then OpenLibrary(NextLibrary);
end;
procedure TScuMainForm.CloseLibrary;
begin RequestTransition('', False); end;
procedure TScuMainForm.Closing(Sender: TObject; var CanClose: Boolean);
begin CanClose := RequestTransition('', True); end;
procedure TScuMainForm.KeyPressed(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if not (ssCtrl in Shift) then Exit;
  case Key of
    VK_S: begin SaveClick(Self); Key := 0; end;
    VK_W: begin CloseTabClick(Self); Key := 0; end;
    VK_TAB: if not Busy or Comparing then
      begin FTabBar.Cycle(ssShift in Shift); Key := 0; end;
  end;
end;
end.
