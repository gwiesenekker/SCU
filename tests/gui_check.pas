program gui_check;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} {$IFDEF WINDOWS}Windows, ScuPlatformProcessStringsWindows,{$ENDIF} Interfaces, Forms, Classes, SysUtils, Controls, StdCtrls, ExtCtrls, ButtonPanel,
  ComCtrls, Graphics, Types, SynEdit, uManualForm, FPImage, Dialogs, Menus, FPJSON, ScuGuiOptions, LCLType, ScuGuiTabs, ScuGuiMain, ScuGuiTab, ScuFiles, ScuGuiReader, ScuGuiLiveDiff, ScuSQLite, ScuSQLiteDB, ScuPlatformPaths, ScuGuiPlatform;
type TErrorHandler = class
  procedure Failed(Sender: TObject; E: Exception);
end;
type
  TTestMainForm = class(TScuMainForm)
  public
    CloseAnswer, ClosePrompts, ErrorDialogs: Integer;
    LastDialogCommand, LastDialogDetails, PrefilledVersion: string;
    procedure AnswerLockDialog(Answer: PtrInt);
    procedure DisplayCommandError(const CommandName, Details: string); override;
    function PromptNewVersion(var Version: string): Boolean; override;
    function ConfirmDeckClose(Document: TScuEditorTab): Integer; override;
  end;
  TSplitterAccess = class(TSplitter);
  TTabBarAccess = class(TScuTabBar);
function TTestMainForm.ConfirmDeckClose(Document: TScuEditorTab): Integer;
begin Inc(ClosePrompts); Result := CloseAnswer; end;
procedure TTestMainForm.DisplayCommandError(const CommandName, Details: string);
begin Inc(ErrorDialogs); LastDialogCommand := CommandName; LastDialogDetails := Details; end;
function TTestMainForm.PromptNewVersion(var Version: string): Boolean;
begin PrefilledVersion := Version; Result := True; end;
var Main: TTestMainForm; Errors: TErrorHandler; Checks: Integer; InvocationArguments: TStringList;
function CheckArgument(Index: Integer): string;
begin
  if Index = 0 then Result := InvocationExecutablePath else Result := InvocationArguments[Index - 1];
end;
procedure Check(Value: Boolean; const Message: string);
begin
  Inc(Checks);
  if not Value then raise Exception.Create(Message);
end;
procedure TErrorHandler.Failed(Sender: TObject; E: Exception);
begin WriteLn(StdErr, 'GUI exception: ', E.Message); Halt(1); end;
procedure Pump;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 15000;
  repeat
    Application.ProcessMessages; Sleep(5);
    if GetTickCount64 > Deadline then raise Exception.Create('GUI command timeout');
  until not Main.Busy;
  Application.ProcessMessages;
end;
procedure CheckPaneDrag(Pane: TWinControl; Edge: TAlign);
var Split: TSplitterAccess; I, Initial, Requested: Integer;
  function PaneSize: Integer;
  begin
    if Edge = alBottom then Result := Pane.Height else Result := Pane.Width;
  end;
  procedure Drag(Delta: Integer);
  var Start, Finish: TPoint;
  begin
    Start := Split.ClientToScreen(Point(Split.Width div 2, Split.Height div 2));
    Finish := Start;
    if Edge = alBottom then Dec(Finish.Y, Delta)
    else if Edge = alRight then Dec(Finish.X, Delta)
    else Inc(Finish.X, Delta);
    Split.StartSplitterMove(Start);
    if Edge = alLeft then Split.MoveSplitter(Delta div 2)
    else Split.MoveSplitter(-(Delta div 2));
    Application.ProcessMessages;
    Split.StopSplitterMove(Finish);
    Application.ProcessMessages;
  end;
begin
  Split := nil;
  for I := 0 to Pane.Parent.ControlCount - 1 do
    if (Pane.Parent.Controls[I] is TSplitter) and (Pane.Parent.Controls[I].Align = Edge) then
      Split := TSplitterAccess(Pane.Parent.Controls[I]);
  Check(Assigned(Split), 'Pane has a splitter');
  Check(Split.ResizeControl = Pane, 'Splitter targets the adjacent pane: ' + IntToStr(Ord(Edge)));
  Initial := PaneSize;
  Drag(40);
  Requested := Initial + 40;
  Check(Abs(PaneSize - Requested) <= 1, 'Drag enlarges pane: ' + IntToStr(Ord(Edge)));
  Main.RefreshLayout;
  Check(Abs(PaneSize - Requested) <= 1, 'Layout keeps dragged size: ' + IntToStr(Ord(Edge)));
  Drag(-40);
  Check(Abs(PaneSize - Initial) <= 1, 'Reverse drag restores pane size');
end;
procedure CheckManual;
var
  Entry: TMenuItem;
  Manual: TManualForm;
  Search: TEdit;
begin
  Entry := Main.Menu.FindItem(VK_F1, fkShortCut);
  Check(Assigned(Entry), 'Help menu contains Manual');
  Entry.Click;
  Application.ProcessMessages;
  Manual := TManualForm(Main.FindComponent('ManualWindow'));
  Check(Assigned(Manual) and Manual.Visible, 'Manual opens before library selection');
  Check(TSynEdit(Manual.FindComponent('ManualText')).ReadOnly, 'Manual uses a read-only SynEdit');
  Check(Length(Manual.Document.Headings) >= 8, 'Markdown sections populate the manual');
  Search := TEdit(Manual.FindComponent('ManualSearch'));
  Search.Text := 'disvh';
  Check(Length(Manual.Matches) > 1, 'Manual search finds version history');
  TButton(Manual.FindComponent('ManualNext')).Click;
  Manual.RenderForColumns(60);
  Check(Manual.MatchIndex = 1, 'Resizing preserves the selected search result');
  Manual.Close;
  Entry.Click;
  Check(Main.FindComponent('ManualWindow') = Manual, 'Reopen the existing manual window');
  Manual.Close;
end;

procedure Inspect(Parent: TWinControl);
var I: Integer; Child: TControl;
begin
  for I := 0 to Parent.ControlCount - 1 do
  begin
    Child := Parent.Controls[I];
    if not Child.Visible then Continue;
    if (Parent is TPanel) or (Parent is TForm) or (Parent is TTabSheet) then
      Check((Child.Left >= -2) and (Child.Top >= -2) and
        (Child.Left + Child.Width <= Parent.ClientWidth + 3) and
        (Child.Top + Child.Height <= Parent.ClientHeight + 3),
        Parent.ClassName + '/' + Child.ClassName + ' outside parent at ' +
        IntToStr(Child.Left) + ',' + IntToStr(Child.Top) + ' size ' +
        IntToStr(Child.Width) + 'x' + IntToStr(Child.Height) + ' parent ' +
        IntToStr(Parent.ClientWidth) + 'x' + IntToStr(Parent.ClientHeight));
    if (Child is TLabel) and not TLabel(Child).WordWrap then
      Check((Child.Width >= TLabel(Child).Canvas.TextWidth(TLabel(Child).Caption)) and
        (Child.Height >= TLabel(Child).Canvas.TextHeight('Ag')), 'Clipped label ' + TLabel(Child).Caption);
    if (Child is TPanel) or (Child is TPageControl) or (Child is TTabSheet) or (Child is TScrollBox) then Inspect(TWinControl(Child));
  end;
end;
procedure CheckFieldLabel(Control: TControl);
var I: Integer; LabelControl: TControl;
begin
  for I := 0 to Control.Parent.ControlCount-1 do
  begin
    LabelControl := Control.Parent.Controls[I];
    if LabelControl is TLabel then
      Check(LabelControl.Top+LabelControl.Height <= Control.Top, 'Preferences label sits above its input: ' + TLabel(LabelControl).Caption);
  end;
end;
procedure ClickTab(Index: Integer; CloseButton: Boolean);
var Bounds: TRect;
begin
  Main.TabBar.ShowActiveTab;
  if CloseButton then Bounds := Main.TabBar.CloseBounds(Index) else Bounds := Main.TabBar.TabBounds(Index);
  Check(Bounds.Right > Bounds.Left, 'Visible tab hit target');
  if CloseButton then
    TTabBarAccess(Main.TabBar).MouseDown(mbLeft, [], (Bounds.Left+Bounds.Right) div 2, (Bounds.Top+Bounds.Bottom) div 2)
  else TTabBarAccess(Main.TabBar).MouseDown(mbLeft, [], Bounds.Left+8, (Bounds.Top+Bounds.Bottom) div 2);
  Application.ProcessMessages;
end;
procedure CheckOverflow;
var Host: TForm; Pages: TPageControl; Bar: TScuTabBar; Page: TTabSheet; I: Integer; Key: Word; Bounds: TRect;
begin
  Host := TForm.CreateNew(nil);
  try
    Host.Width := 400; Host.Height := 180;
    Bar := TScuTabBar.Create(Host); Bar.Parent := Host; Bar.Align := alTop;
    Pages := TPageControl.Create(Host); Pages.Parent := Host; Pages.Align := alClient;
    Pages.ShowTabs := False; Bar.Pages := Pages;
    for I := 0 to 19 do
    begin Page := TTabSheet.Create(Host); Page.PageControl := Pages; Page.Caption := 'Long-deck-name-' + IntToStr(I) + '.pas'; end;
    Host.Show; Application.ProcessMessages;
    Pages.ActivePageIndex := 0; Bar.ShowActiveTab; Bar.Cycle(True);
    Check(Pages.ActivePageIndex = 19, 'Reverse tab cycle wraps');
    Bounds := Bar.TabBounds(19);
    Check(Bounds.Right > Bounds.Left, 'Overflow scrolls active tab into view');
    Bar.Cycle(False); Check(Pages.ActivePageIndex = 0, 'Forward tab cycle wraps');
    Key := VK_END; TTabBarAccess(Bar).KeyDown(Key, []);
    Check(Pages.ActivePageIndex = 19, 'End key selects last tab');
    Key := VK_HOME; TTabBarAccess(Bar).KeyDown(Key, []);
    Check(Pages.ActivePageIndex = 0, 'Home key selects first tab');
    Host.Width := 250; Bar.ShowActiveTab; Application.ProcessMessages;
    Bounds := Bar.TabBounds(0);
    Check((Bounds.Right > Bounds.Left) and (Bounds.Right <= Bar.Width), 'Narrow tab header remains bounded');
  finally Host.Free; end;
end;
function AuditCount: Int64;
var Database: TSQLiteLibrary; Statement: TSQLiteStatement;
begin
  Database := TSQLiteLibrary.OpenRead(CheckArgument(1));
  try
    Statement := Database.Prepare('SELECT count(*) FROM audit_records');
    try Statement.Step; Result := Statement.Integers[0]; finally Statement.Free; end;
  finally Database.Free; end;
end;
procedure ChooseDiff(const FromChoice, ToChoice: string);
begin
  Main.FromVersion.ItemIndex := Main.FromVersion.Items.IndexOf(FromChoice);
  Main.ToVersion.ItemIndex := Main.ToVersion.Items.IndexOf(ToChoice);
  Check((Main.FromVersion.ItemIndex >= 0) and (Main.ToVersion.ItemIndex >= 0), 'Comparison selectors exist');
  Main.ToVersion.OnChange(Main.ToVersion);
end;
procedure SnapshotWindow(Window: TForm; const Path: string); forward;
procedure TTestMainForm.AnswerLockDialog(Answer: PtrInt);
var Dialog: TForm; I: Integer; Memo: TMemo; Buttons: TButtonPanel; LabelFound: Boolean;
begin
  Dialog := nil;
  for I := 0 to Screen.FormCount - 1 do
    if fsModal in Screen.Forms[I].FormState then Dialog := Screen.Forms[I];
  Check(Assigned(Dialog), 'Lock description opens a modal dialog');
  Check(Dialog.Caption = 'Lock version 1.0', 'Lock dialog identifies the current version');
  Memo := nil; Buttons := nil; LabelFound := False;
  for I := 0 to Dialog.ComponentCount - 1 do
  begin
    if Dialog.Components[I] is TButtonPanel then Buttons := TButtonPanel(Dialog.Components[I]);
    if Dialog.Components[I] is TMemo then Memo := TMemo(Dialog.Components[I]);
    if Dialog.Components[I] is TLabel then
      LabelFound := LabelFound or (Pos('version 1.0', TLabel(Dialog.Components[I]).Caption) > 0);
  end;
  Check(LabelFound and Assigned(Memo), 'Current version is visible beside the multiline description');
  if (Answer = mrCancel) and (ParamCount > 1) then
    SnapshotWindow(Dialog, ChangeFileExt(CheckArgument(2), '-lock.png'));
  Memo.Text := 'First line' + LineEnding + 'Second line';
  Check(Assigned(Buttons) and (Buttons.ButtonOrder = boDefault), 'Dialog uses platform button order');
  Check(Buttons.OKButton.Caption = 'Lock version', 'Primary button names the action');
  if Answer = mrCancel then Buttons.CancelButton.Click else Buttons.OKButton.Click;
end;
procedure SnapshotWindow(Window: TForm; const Path: string);
var Bitmap: TBitmap; PNG: TPortableNetworkGraphic;
begin
  Window.Repaint; Application.ProcessMessages; Sleep(60); Application.ProcessMessages;
  Bitmap := Window.GetFormImage; PNG := TPortableNetworkGraphic.Create;
  try PNG.Assign(Bitmap); PNG.SaveToFile(Path);
  finally PNG.Free; Bitmap.Free; end;
end;
var Tab, Other: TScuEditorTab; ListMarker: TObject; Path, OldDisk: string; I: Integer; EditorFont: TFont; BeforeAudit: Int64; OriginalBytes, OriginalDisk: RawByteString; OriginalVersion: string; Configuration: TJSONObject; State: TGuiLibraryState;
  Options: TScuOptionsDialog; Parameters: array of string; VersionItem, LockItem, UnlockItem: TMenuItem; BeforeDialogs: Integer;
begin
  InitializePlatformPaths;
  {$IFDEF WINDOWS}
  // Wine replaces LOCALAPPDATA during startup. Override it inside this test
  // process only, so font persistence never touches the real user profile.
  if WindowsEnvironmentValue('SCU_GUI_TEST_CONFIG') <> '' then
    SetEnvironmentVariableW('LOCALAPPDATA', PWideChar(UTF8Decode(WindowsEnvironmentValue('SCU_GUI_TEST_CONFIG'))));
  {$ENDIF}
  InvocationArguments := TStringList.Create; ReadInvocationArguments(InvocationArguments);
  RequireDerivedFormResource := False; Application.Initialize;
  Errors := TErrorHandler.Create; Application.OnException := @Errors.Failed;
  Main := TTestMainForm.Create(nil);
  try
    Main.Show; Application.ProcessMessages;
    CheckPaneDrag(Main.LogView.Parent, alBottom);
    CheckPaneDrag(Main.DeckList.Parent, alLeft);
    CheckPaneDrag(Main.DiffView.Parent, alRight);
    CheckManual;
    Check(Main.Preferences.EditorFont.Name = DefaultGuiFont, 'Platform default editor font');
    Check(Main.LogView.Font.Name = DefaultGuiFont, 'Platform default log font');
    Check(Main.DiffView.Font.Name = DefaultGuiFont, 'Platform default diff font');
    {$IFDEF WINDOWS}
    BeforeDialogs := Main.ErrorDialogs;
    Main.OpenInitialLibrary(IncludeTrailingPathDelimiter(ExtractFileDir(CheckArgument(1))) + 'missing.sqlite');
    Check(Main.ErrorDialogs = BeforeDialogs + 1, 'Startup failure displays one dialog without stderr');
    Check(Main.LastDialogCommand = 'Open library', 'Startup dialog identifies the operation');
    Check(Main.LibraryPath = '', 'Failed startup leaves no library open');
    Check(Pos('missing.sqlite', Main.LastError) > 0, 'Startup failure is retained in the log');
    {$ENDIF}

    Main.OpenLibrary(CheckArgument(1)); Pump;
    Check(Main.LastError = '', Main.LastError);
    Check(Main.DeckList.Count = 2, 'Deck list');
    Check(Assigned(Main.LogView.PopupMenu), 'Log has a context menu');
    Check(Main.LogView.PopupMenu.Items[0].Caption = 'Copy', 'Log menu Copy');
    Check(Main.LogView.PopupMenu.Items[1].Caption = 'Select All', 'Log menu Select All');
    Main.LogView.BlockBegin := Point(1,1); Main.LogView.BlockEnd := Point(1,1);
    Main.LogView.PopupMenu.OnPopup(Main.LogView.PopupMenu);
    Check(not Main.LogView.PopupMenu.Items[0].Enabled, 'Copy disabled without selection');
    Main.LogView.PopupMenu.Items[1].Click;
    Main.LogView.PopupMenu.OnPopup(Main.LogView.PopupMenu);
    Check(Main.LogView.PopupMenu.Items[0].Enabled and (Main.LogView.SelText <> ''), 'Select All makes log text copyable');

    Main.OpenDeck('main.pas'); Pump;
    Tab := TScuEditorTab(Main.EditorTabs.ActivePage);
    Check(Tab.Caption = 'main.pas', 'Initial tab title');
    Check(Tab.SourceBytes = ReadGuiDeck(CheckArgument(1), 'main.pas').Bytes, 'Initial text round-trip count=' + IntToStr(Tab.Editor.Lines.Count) + ' bytes=' + Tab.SourceBytes);
    Check(Main.FromVersion.Text = 'scu$current_deck_version', 'Default From is latest stored deck');
    Check(Main.ToVersion.Text = LiveDeckVersionSelector, 'Default To is live buffer');
    Check(Pos('No differences.', Main.DiffView.Text) > 0, 'Clean buffer has no default differences');
    Check(Main.FromVersion.Items[0] = 'scu$current_deck_version', 'First version choice uses canonical selector');
    Check(Main.ToVersion.Items[0] = 'scu$current_deck_version', 'To choice uses the same canonical selector');
    Check(Main.FromVersion.Items[1] = 'scu$previous_deck_version', 'Previous version choice');
    ChooseDiff('scu$previous_deck_version', 'scu$current_deck_version'); Pump;
    ListMarker := TObject.Create;
    try
      Main.DeckList.Items.Objects[0] := ListMarker;
      Main.ToVersion.ItemIndex := Main.ToVersion.Items.IndexOf('1.0-0.000');
      Main.ToVersion.OnChange(Main.ToVersion);
      Check(Main.Busy, 'Comparison runs asynchronously');
      Check(Main.DeckList.Enabled and Main.EditorTabs.Enabled, 'Browsing stays enabled during diff');
      Check(Main.FromVersion.Enabled and Main.ToVersion.Enabled, 'Version selectors stay enabled');
      Check(Main.DeckList.Items.Objects[0] = ListMarker, 'No immediate deck list rebuild');
      Main.ToVersion.ItemIndex := 0;
      Main.ToVersion.OnChange(Main.ToVersion);
      Pump;
      Check(Main.DeckList.Items.Objects[0] = ListMarker, 'No deck list rebuild after comparison');
      Check(Main.DeckList.ItemIndex = 0, 'Comparison preserves selected deck');
      Check(Main.ToVersion.ItemIndex = 0, 'Latest selected version retained');
      Check(Pos('// SECOND', Main.DiffView.Text) > 0, 'Latest comparison replaces stale output');
      // Switching decks while the previous comparison is still running must
      // neither block browsing nor publish the previous deck's diff.
      Main.FromVersion.OnChange(Main.FromVersion);
      Main.OpenDeck('other.cpp');
      Check(Main.EditorTabs.ActivePage.Caption = 'other.cpp', 'Deck switch allowed during diff');
      Pump;
      Check(Pos('No differences.', Main.DiffView.Text) > 0, 'Old-deck output discarded for default live preview');
      Main.OpenDeck('main.pas'); Pump;
    finally Main.DeckList.Items.Objects[0] := nil; ListMarker.Free; end;

    OriginalBytes := Tab.SourceBytes;
    OriginalDisk := ReadBytes(ExtractFileDir(CheckArgument(1)) + '/Main.pas', 1024*1024);
    OriginalVersion := ReadGuiDeck(CheckArgument(1), 'main.pas').DeckVersion;
    BeforeAudit := AuditCount;
    Check(Main.FromVersion.Items.IndexOf(LiveDeckVersionSelector) >= 0, 'Live selector in From dropdown');
    Check(Main.ToVersion.Items.IndexOf(LiveDeckVersionSelector) >= 0, 'Live selector in To dropdown');
    Tab.Editor.CaretXY := Point(1,2); Tab.Editor.SelText := '// LIVE PREVIEW' + #10;
    ChooseDiff('scu$current_deck_version', LiveDeckVersionSelector); Pump;
    Check(Pos('+// LIVE PREVIEW', Main.DiffView.Text) > 0, 'Live destination shows unsaved insertion');
    Check(Pos('scu$live_deck_version', Main.DiffView.Text) > 0, 'Live endpoint is labeled');
    Check(Tab.Dirty, 'Preview keeps tab dirty');
    ChooseDiff(LiveDeckVersionSelector, 'scu$current_deck_version'); Pump;
    Check(Pos('-// LIVE PREVIEW', Main.DiffView.Text) > 0, 'Live source reverses diff direction');
    ChooseDiff('1.0-0.000', LiveDeckVersionSelector); Pump;
    Check(Pos('// FIRST', Main.DiffView.Text) > 0, 'Live preview resolves an explicit older revision');
    ChooseDiff(LiveDeckVersionSelector, LiveDeckVersionSelector); Pump;
    Check(Pos('No differences.', Main.DiffView.Text) > 0, 'Both live endpoints compare the same buffer');
    ChooseDiff('scu$current_deck_version', LiveDeckVersionSelector);
    Tab.Editor.CaretXY := Point(1,2); Tab.Editor.SelText := '// LATEST LIVE EDIT' + #10;
    Pump;
    Check(Pos('+// LATEST LIVE EDIT', Main.DiffView.Text) > 0, 'Typing refreshes the live preview');
    Check(Main.DeckList.Enabled and Main.EditorTabs.Enabled, 'Live preview leaves browsing enabled');
    Check(ReadGuiDeck(CheckArgument(1), 'main.pas').Bytes = OriginalBytes, 'Preview never stores draft bytes');
    Check(ReadGuiDeck(CheckArgument(1), 'main.pas').DeckVersion = OriginalVersion, 'Preview creates no revision');
    Check(ReadBytes(ExtractFileDir(CheckArgument(1)) + '/Main.pas', 1024*1024) = OriginalDisk, 'Preview never writes working file');
    Check(AuditCount = BeforeAudit, 'Preview emits no audit commands');
    Tab.Editor.Undo; Tab.Editor.Undo; Pump;
    Check(not Tab.Dirty, 'Undo live edits restores clean tab');
    Check(Pos('No differences.', Main.DiffView.Text) > 0, 'Live preview follows undo');
    ChooseDiff('scu$previous_deck_version', 'scu$current_deck_version'); Pump;
    Check(Pos('scu> display_deck_diff', Main.LogView.Text) > 0, 'Stored comparison still uses CLI command');

    Tab.Editor.CaretXY := Point(1,2); Tab.Editor.SelText := '// GUI EDIT' + #10; Application.ProcessMessages;
    Check(Tab.Caption = 'main.pas*', 'Dirty tab title: ' + Tab.Caption + ' bytes=' + Tab.SourceBytes);
    Main.SaveActive; Pump;
    Check(Main.LastError = '', Main.LastError);
    Check(Tab.Caption = 'main.pas', 'Saved tab title');
    Check(Pos('// GUI EDIT', ReadGuiDeck(CheckArgument(1), 'main.pas').Bytes) > 0, 'Save through backend');
    Check(Pos('// GUI EDIT', Main.DiffView.Text) > 0, 'Diff refreshed after save');
    EditorFont := TFont.Create;
    try
      EditorFont.Name := DefaultGuiFont; EditorFont.Size := 13; Main.SetEditorFont(EditorFont);
    finally EditorFont.Free; end;
    Check(Tab.Editor.Font.Size = 13, 'Font preference applies to open tab');
    Main.OpenDeck('other.cpp'); Pump;
    Check(Main.EditorTabs.PageCount = 2, 'Multiple editor tabs');
    Other := TScuEditorTab(Main.EditorTabs.ActivePage);
    Check(Other.Editor.Font.Size = 13, 'Font preference applies to new tab');
    Check(Other.SourceBytes = 'int other = 1;' + #13#10 + '// no final newline', 'CRLF and final newline preserved');
    Other.Editor.BlockBegin := Point(1,1); Other.Editor.BlockEnd := Point(15,1);
    Other.Editor.SelText := 'int other = 2;'; Application.ProcessMessages;
    ChooseDiff('scu$current_deck_version', LiveDeckVersionSelector); Pump;
    Check(Pos('+int other = 2;', Main.DiffView.Text) > 0, 'Live preview works without a previous revision');
    Main.SaveActive; Pump;
    Check(Main.ToVersion.Text = LiveDeckVersionSelector, 'Save retains live selection');
    Check(Pos('No differences.', Main.DiffView.Text) > 0, 'Saved buffer matches latest stored version');
    Check(ReadGuiDeck(CheckArgument(1), 'other.cpp').Bytes = 'int other = 2;' + #13#10 + '// no final newline', 'Saved CRLF');
    Main.OpenDeck('main.pas'); Pump;
    Check((Main.ToVersion.Text = LiveDeckVersionSelector) and (Pos('No differences.', Main.DiffView.Text) > 0), 'Default live preview follows selected tab');
    Main.ExtractActive; Pump;
    Check(Main.LastError = '', Main.LastError);
    Check(Pos('GUI-BUILD-START', Main.LogView.Text) > 0, 'Build stdout streamed');
    Check(Pos('GUI-BUILD-DONE', Main.LogView.Text) > 0, 'Build completion output');
    ChooseDiff('scu$current_deck_version', LiveDeckVersionSelector); Pump;
    Tab.Editor.CaretXY := Point(1,2); Tab.Editor.SelText := '// BATCH MAIN' + #10;
    Other.Editor.CaretXY := Point(1,1); Other.Editor.SelText := '// BATCH OTHER' + #10;
    Main.ExtractAll; Pump;
    Check(Main.LastError = '', Main.LastError);
    Check(not Tab.Dirty and not Other.Dirty, 'Batch saves complete while live preview is selected');
    Check(Main.ToVersion.Text = LiveDeckVersionSelector, 'Batch extraction retains live selection');
    Check(Pos('No differences.', Main.DiffView.Text) > 0, 'Live preview follows batch save');
    ChooseDiff('scu$previous_deck_version', 'scu$current_deck_version'); Pump;
    Main.PublishVersion('scu$current_version'); Pump;
    Check(Main.LastError = '', Main.LastError);
    Path := ExtractFileDir(CheckArgument(1));
    Check(FileExists(Path + '/release/Main.pas'), 'Published recorded filename');
    Check(Pos('scu> import_deck deck_name=', Main.LogView.Text) > 0, 'Canonical command log');
    Check(Main.TabBar.Visible and not Main.EditorTabs.ShowTabs, 'Editor-style tab strip replaces native labels');
    ClickTab(Other.PageIndex, False); Pump;
    Check(Main.EditorTabs.ActivePage = Other, 'Click selects tab');
    Check((Main.ToVersion.Text = LiveDeckVersionSelector) and (Pos('No differences.', Main.DiffView.Text) > 0), 'Clicked tab updates live preview');
    Main.TabBar.Cycle(True); Pump;
    Check(Main.EditorTabs.ActivePage = Tab, 'Keyboard cycling selects previous tab');
    Main.FromVersion.OnChange(Main.FromVersion);
    ClickTab(Other.PageIndex, True);
    Pump;
    Check(Main.EditorTabs.PageCount = 1, 'Inactive tab closes safely during comparison');
    Check(Main.EditorTabs.ActivePage = Tab, 'Closing inactive tab preserves active document');
    Main.OpenDeck('other.cpp'); Pump; Other := TScuEditorTab(Main.EditorTabs.ActivePage);
    Other.Editor.CaretXY := Point(1,1); Other.Editor.SelText := '// SAVE THIS' + #10;
    Check(Other.Dirty, 'Close test starts with dirty tab');
    Main.CloseAnswer := mrCancel; ClickTab(Other.PageIndex, True); Pump;
    Check((Main.EditorTabs.PageCount = 2) and Other.Dirty, 'Cancel close retains dirty buffer');
    Main.OpenDeck('main.pas'); Pump;
    Main.CloseAnswer := mrYes; ClickTab(Other.PageIndex, True); Pump;
    Check(Main.EditorTabs.PageCount = 1, 'Save and close inactive dirty tab');
    Check(Pos('// SAVE THIS', ReadGuiDeck(CheckArgument(1), 'other.cpp').Bytes) = 1, 'Close saves the clicked deck through backend');
    Check(Main.EditorTabs.ActivePage = Tab, 'Save and close preserves active tab');
    Main.OpenDeck('other.cpp'); Pump; Other := TScuEditorTab(Main.EditorTabs.ActivePage);
    Other.Editor.CaretXY := Point(1,1); Other.Editor.SelText := '// DISCARD THIS' + #10;
    Main.CloseAnswer := mrNo; ClickTab(Other.PageIndex, True); Pump;
    Check(Main.EditorTabs.PageCount = 1, 'Discard closes dirty tab');
    Check(Pos('// DISCARD THIS', ReadGuiDeck(CheckArgument(1), 'other.cpp').Bytes) = 0, 'Discard leaves stored source unchanged');
    Check(Main.ClosePrompts = 3, 'Dirty tab close asks exactly once per attempt');
    Main.OpenDeck('other.cpp'); Pump; Main.OpenDeck('main.pas'); Pump;
    CheckOverflow;

    for I := 0 to 2 do
    begin
      case I of
        0: begin Main.Width := Main.Constraints.MinWidth; Main.Height := Main.Constraints.MinHeight; end;
        1: begin Main.Width := 1500; Main.Height := 950; end;
        2: begin Main.Font.Size := 14; Main.Width := Main.Constraints.MinWidth; Main.Height := Main.Constraints.MinHeight; end;
      end;
      Application.ProcessMessages; Main.RefreshLayout; Application.ProcessMessages;
      Inspect(Main);
      Check(Main.EditorTabs.Width > 100, 'Editor remains visible');
      Check(Main.DiffView.Height > 100, 'Diff remains visible');
    end;
    Main.AutoAdjustLayout(lapAutoAdjustForDPI, 96, 144, Main.Width, Round(Main.Width * 1.5));
    Application.ProcessMessages; Main.RefreshLayout; Application.ProcessMessages; Inspect(Main);
    Main.AutoAdjustLayout(lapAutoAdjustForDPI, 144, 96, Main.Width, Round(Main.Width / 1.5));
    Main.Font.Size := 10; Main.Width := 1380; Main.Height := 850;
    Application.ProcessMessages; Main.RefreshLayout; Application.ProcessMessages; Inspect(Main);
    if ParamCount > 1 then SnapshotWindow(Main, CheckArgument(2));
    // An external editor must not be overwritten by an older GUI buffer.
    OldDisk := ReadBytes(Path + '/Main.pas', 1024 * 1024);
    AtomicWrite(Path + '/Main.pas', 'external edit');
    Tab.Editor.CaretXY := Point(1,2); Tab.Editor.SelText := '// conflicting GUI edit' + #10; Application.ProcessMessages;
    Main.SaveActive; Pump;
    Check(Pos('changed outside SCU', Main.LastError) > 0, 'External-edit conflict reported');
    Check(ReadBytes(Path + '/Main.pas', 1024 * 1024) = 'external edit', 'External bytes protected');
    Check(Tab.Dirty, 'Failed save retains buffer');
    AtomicWrite(Path + '/Main.pas', OldDisk);
    Tab.Editor.Undo; Pump;
    // The document is back at the stored bytes, so close requires no discard.
    Check(not Tab.Dirty, 'Undo to stored bytes clears dirty title');
    LockItem := Main.Menu.Items[0].Find('&Lock version…');
    UnlockItem := Main.Menu.Items[0].Find('&Unlock version');
    Check(Assigned(LockItem) and Assigned(UnlockItem), 'File menu has both lock actions');
    Check(LockItem.Enabled and not UnlockItem.Enabled, 'Only Lock is available for the open version');
    Application.QueueAsyncCall(@Main.AnswerLockDialog, mrCancel);
    LockItem.Click; Pump;
    Check(not ReadGuiLibraryState(CheckArgument(1)).Locked, 'Cancel leaves the version open');
    Application.QueueAsyncCall(@Main.AnswerLockDialog, mrOK);
    LockItem.Click; Pump;
    Check(UnlockItem.Enabled and not LockItem.Enabled, 'Lock enables Unlock');
    UnlockItem.Click; Pump;
    Check(not ReadGuiLibraryState(CheckArgument(1)).Locked and LockItem.Enabled, 'Unlock reopens current version');
    Application.QueueAsyncCall(@Main.AnswerLockDialog, mrOK);
    LockItem.Click; Pump;
    OriginalBytes := ReadGuiDeck(CheckArgument(1), 'main.pas').Bytes;
    OriginalVersion := ReadGuiDeck(CheckArgument(1), 'main.pas').DeckVersion;
    Tab.Editor.CaretXY := Point(1,2); Tab.Editor.SelText := '// AFTER LOCK' + #10;
    BeforeDialogs := Main.ErrorDialogs; Main.SaveActive; Pump;
    Check(Main.ErrorDialogs = BeforeDialogs+1, 'Locked save shows one error dialog');
    Check(Pos('locked', Main.LastDialogDetails) > 0, 'Error dialog contains actual locked-version error');
    Check(Main.LastDialogCommand = 'import_deck', 'Error dialog identifies failed save command');
    Check(Tab.Dirty, 'Locked save keeps editor buffer modified');
    Check(ReadGuiDeck(CheckArgument(1), 'main.pas').Bytes = OriginalBytes, 'Locked source is unchanged');
    State := ReadGuiLibraryState(CheckArgument(1));
    Check(State.NextVersion = '1.01', 'Next version uses backend increment');
    VersionItem := nil;
    for I := 0 to Main.Menu.Items[0].Count-1 do
      if Pos('Create new version', Main.Menu.Items[0].Items[I].Caption) > 0 then VersionItem := Main.Menu.Items[0].Items[I];
    Check(Assigned(VersionItem), 'File menu has Create new version');
    VersionItem.Click; Pump;
    Check(Main.PrefilledVersion = '1.01', 'Create version dialog prefills next version');
    State := ReadGuiLibraryState(CheckArgument(1));
    Check((State.CurrentVersion = '1.01') and not State.Locked, 'Create version uses backend and leaves new version open');
    Check(Tab.Dirty, 'Creating version preserves unsaved edit');
    Configuration := ReadGuiConfiguration(CheckArgument(1));
    Options := TScuOptionsDialog.CreateOptions(Main, Main.Preferences.EditorFont, Configuration, State.PrefixEditable);
    try
      Options.Show; Application.ProcessMessages;
      Check(Options.Pages.PageCount = 2, 'Preferences has Editor and Library panes');
      Check(Options.LibraryField(0).Enabled, 'Comment string editable before first revision');
      Options.CollectChanges; Check(Options.Changes.Count = 0, 'Opening preferences does not change settings');
      Options.Pages.ActivePageIndex := 1; Application.ProcessMessages; Inspect(Options);
      for I := 0 to 4 do CheckFieldLabel(Options.LibraryField(I));
      CheckFieldLabel(Options.BuildField); CheckFieldLabel(Options.PatternsField);
      if ParamCount > 1 then SnapshotWindow(Options, ChangeFileExt(CheckArgument(2), '-preferences.png'));
      Options.Font.Size := 14; Options.Width := 600; Options.Height := 550;
      Application.ProcessMessages; Inspect(Options);
      for I := 0 to 4 do CheckFieldLabel(Options.LibraryField(I));
      CheckFieldLabel(Options.BuildField); CheckFieldLabel(Options.PatternsField);
      Options.LibraryField(0).Text := '#'; Options.LibraryField(2).Text := '0.05';
      Options.LibraryField(3).Text := '0.002'; Options.LibraryField(4).Text := 'gui-release';
      Options.BuildField.Text := 'printf ''OPTIONS-BUILD\n''';
      Options.PatternsField.Lines.Text := '*.pas' + #10 + '*.cpp';
      Options.CollectChanges; SetLength(Parameters, Options.Changes.Count);
      for I := 0 to High(Parameters) do Parameters[I] := Options.Changes[I];
      Main.ApplyLibraryOptions(Parameters); Pump;
      Check(Main.LastError = '', Main.LastError);
    finally Options.Free; Configuration.Free; end;
    Configuration := ReadGuiConfiguration(CheckArgument(1));
    try
      Check(Configuration.Get('comment_prefix','') = '#', 'Library comment string saved');
      Check(Configuration.Get('version_increment','') = '0.05', 'Version increment saved');
      Check(Configuration.Get('revision_increment','') = '0.002', 'Revision increment saved');
      Check(Configuration.Get('release_directory','') = 'gui-release', 'Release directory saved');
      Check(TJSONArray(Configuration.Find('file_patterns')).Count = 2, 'Monitored patterns saved');
    finally Configuration.Free; end;
    Check(ReadGuiLibraryState(CheckArgument(1)).NextVersion = '1.06', 'Suggested version reflects configured increment');
    Main.SaveActive; Pump;
    Check(Main.LastError = '', Main.LastError);
    Check(not Tab.Dirty, 'Save succeeds in the new version');
    Check(ReadGuiDeck(CheckArgument(1), 'main.pas').DeckVersion = '1.01-0.000', 'Edit belongs to new version');
    Check(ReadGuiDeckVersion(CheckArgument(1), 'main.pas', OriginalVersion).Bytes = OriginalBytes, 'Earlier locked version source preserved');
    Main.CloseLibrary;
    Check(Main.LibraryPath = '', 'Close library');
    Check(Main.EditorTabs.PageCount = 0, 'Close clears tabs');
    Main.Free; Main := nil;
    Main := TTestMainForm.Create(nil); Main.Show;
    Check(Main.Preferences.EditorFont.Size = 13, 'Font preference reloaded in a new session');
    Main.OpenLibrary(CheckArgument(1)); Pump; Main.OpenDeck('main.pas'); Pump;
    Check(TScuEditorTab(Main.EditorTabs.ActivePage).Editor.Font.Size = 13, 'Reloaded font used by editor');
    Main.CloseLibrary;
    WriteLn('GUI checks passed: ', Checks);
  finally Main.Free; Errors.Free; InvocationArguments.Free; end;
end.
