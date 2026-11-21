unit ScuGuiLayout;
{$mode objfpc}{$H+}
interface
uses Classes, Forms, Controls, ExtCtrls, StdCtrls, ComCtrls, Menus, SynEdit, ScuGuiTabs;
type
  TScuWorkspaceForm = class(TForm)
  private
    FAdjusting: Boolean;
    FLayoutWidth, FLayoutHeight: Integer;
    FDeckFraction, FDiffFraction, FLogFraction: Double;
    FLeftSplit, FRightSplit, FBottomSplit: TSplitter;
    procedure SplitMoved(Sender: TObject);
  protected
    FWorkspace, FLeftPane, FRightPane, FBottomPane: TPanel;
    FToolbar: TFlowPanel;
    FDeckList: TListBox;
    FEditorPane: TPanel;
    FTabBar: TScuTabBar;
    FTabs: TPageControl;
    FDiff, FLog: TSynEdit;
    FFromVersion, FToVersion: TComboBox;
    FSaveButton, FExtractButton, FExtractAllButton, FCloseTabButton: TButton;
    FFileMenu: TMenuItem;
    FStatus: TStatusBar;
    procedure Resize; override;
    procedure FontChanged(Sender: TObject); override;
    procedure DoAutoAdjustLayout(const AMode: TLayoutAdjustmentPolicy;
      const AXProportion, AYProportion: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure RefreshLayout;
    property DeckList: TListBox read FDeckList;
    property EditorTabs: TPageControl read FTabs;
    property TabBar: TScuTabBar read FTabBar;
    property DiffView: TSynEdit read FDiff;
    property LogView: TSynEdit read FLog;
    property FromVersion: TComboBox read FFromVersion;
    property ToVersion: TComboBox read FToVersion;
  end;
implementation
uses ScuGuiPlatform, Math, Graphics, SynHighlighterDiff, SynEditMouseCmds;
function Panel(Owner: TComponent; Parent: TWinControl; Alignment: TAlign): TPanel;
begin
  Result := TPanel.Create(Owner); Result.Parent := Parent;
  Result.BevelOuter := bvNone; Result.Align := Alignment;
end;
function Heading(Owner: TComponent; Parent: TWinControl; const Caption: string): TLabel;
begin
  Result := TLabel.Create(Owner); Result.Parent := Parent;
  Result.Caption := Caption; Result.AutoSize := True; Result.Align := alTop;
  Result.BorderSpacing.Around := 6;
end;
function Button(Owner: TComponent; Parent: TWinControl; const Caption: string): TButton;
begin
  Result := TButton.Create(Owner); Result.Parent := Parent;
  Result.Caption := Caption; Result.AutoSize := True; Result.BorderSpacing.Around := 5;
end;
function VersionChoice(Owner: TComponent; Parent: TWinControl; const Caption: string): TComboBox;
var Row: TPanel;
begin
  Row := Panel(Owner, Parent, alTop); Row.AutoSize := True;
  Result := TComboBox.Create(Owner); Result.Parent := Row;
  Result.Style := csDropDownList; Result.Align := alTop; Result.BorderSpacing.Around := 6;
  Heading(Owner, Row, Caption);
  Row.Top := 1000;
end;
constructor TScuWorkspaceForm.Create(AOwner: TComponent);
var MainMenu: TMainMenu; Content: TPanel;
begin
  inherited CreateNew(AOwner);
  Caption := 'Source Code Utility'; Position := poScreenCenter;
  Width := 1380; Height := 850; Font.Size := 10; Scaled := True;
  FDeckFraction := 0.18; FDiffFraction := 0.34; FLogFraction := 0.24;
  MainMenu := TMainMenu.Create(Self); Self.Menu := MainMenu;
  FFileMenu := TMenuItem.Create(Self); FFileMenu.Caption := '&File'; MainMenu.Items.Add(FFileMenu);
  FStatus := TStatusBar.Create(Self); FStatus.Parent := Self;
  FStatus.SimplePanel := True; FStatus.SimpleText := 'Open a library to begin.';
  FToolbar := TFlowPanel.Create(Self); FToolbar.Parent := Self;
  FToolbar.BevelOuter := bvNone; FToolbar.Align := alTop; FToolbar.AutoSize := True;
  FToolbar.AutoWrap := True;
  FSaveButton := Button(Self, FToolbar, 'Save deck');
  FExtractButton := Button(Self, FToolbar, 'Extract deck');
  FExtractAllButton := Button(Self, FToolbar, 'Extract version');
  FCloseTabButton := Button(Self, FToolbar, 'Close tab');
  Content := Panel(Self, Self, alClient);
  FBottomPane := Panel(Self, Content, alBottom); FBottomPane.Height := 190;
  Heading(Self, FBottomPane, 'Command and build log');
  FLog := TSynEdit.Create(Self); FLog.Parent := FBottomPane; FLog.Align := alClient;
  FLog.MouseOptions := FLog.MouseOptions - [emRightMouseMovesCursor];
  FLog.ReadOnly := True; FLog.Gutter.Visible := False; FLog.RightEdge := 0;
  FLog.Font.Name := DefaultGuiFont; FLog.Font.Size := 10;
  FBottomSplit := TSplitter.Create(Self); FBottomSplit.Parent := Content;
  FBottomSplit.Align := alBottom; FBottomSplit.Height := 6; FBottomSplit.OnMoved := @SplitMoved;
  FBottomSplit.ResizeControl := FBottomPane;
  FWorkspace := Panel(Self, Content, alClient);
  FLeftPane := Panel(Self, FWorkspace, alLeft); FLeftPane.Width := 220;
  Heading(Self, FLeftPane, 'Decks');
  FDeckList := TListBox.Create(Self); FDeckList.Parent := FLeftPane; FDeckList.Align := alClient;
  FLeftSplit := TSplitter.Create(Self); FLeftSplit.Parent := FWorkspace;
  FLeftSplit.Align := alLeft; FLeftSplit.Left := 220; FLeftSplit.Width := 6; FLeftSplit.OnMoved := @SplitMoved;
  FRightPane := Panel(Self, FWorkspace, alRight); FRightPane.Width := 450;
  Heading(Self, FRightPane, 'Deck revision diff');
  FToVersion := VersionChoice(Self, FRightPane, 'To');
  FFromVersion := VersionChoice(Self, FRightPane, 'From');
  FDiff := TSynEdit.Create(Self); FDiff.Parent := FRightPane; FDiff.Align := alClient;
  FDiff.ReadOnly := True; FDiff.Gutter.Visible := False; FDiff.RightEdge := 0; FDiff.Font.Name := DefaultGuiFont; FDiff.Font.Size := 10;
  FDiff.Highlighter := TSynDiffSyn.Create(Self);
  FRightSplit := TSplitter.Create(Self); FRightSplit.Parent := FWorkspace;
  FRightSplit.Align := alRight; FRightSplit.Left := FWorkspace.Width - 456;
  FRightSplit.Width := 6; FRightSplit.OnMoved := @SplitMoved;
  FEditorPane := Panel(Self, FWorkspace, alClient);
  FTabBar := TScuTabBar.Create(Self); FTabBar.Parent := FEditorPane; FTabBar.Align := alTop;
  FTabs := TPageControl.Create(Self); FTabs.Parent := FEditorPane; FTabs.Align := alClient;
  FTabs.ShowTabs := False; FTabs.Options := [nboDoChangeOnSetIndex];
  FTabBar.Pages := FTabs;
  RefreshLayout;
end;
procedure TScuWorkspaceForm.RefreshLayout;
var Em, Line, LeftMin, RightMin, MiddleMin, W, H: Integer;
begin
  if FAdjusting or not Assigned(FTabBar) then Exit;
  FAdjusting := True;
  try
    FLayoutWidth := ClientWidth;
    FLayoutHeight := ClientHeight;
    FTabBar.RefreshTabs;
    Canvas.Font.Assign(Font); Em := Max(6, Canvas.TextWidth('M')); Line := Max(14, Canvas.TextHeight('Ag'));
    LeftMin := 14 * Em; RightMin := 30 * Em; MiddleMin := 32 * Em;
    Constraints.MinWidth := LeftMin + RightMin + MiddleMin + 48;
    Constraints.MinHeight := Line * 29 + FToolbar.Height + FStatus.Height + 30;
    FLeftPane.Constraints.MinWidth := LeftMin; FRightPane.Constraints.MinWidth := RightMin;
    FEditorPane.Constraints.MinWidth := MiddleMin;
    W := FWorkspace.ClientWidth - FLeftSplit.Width - FRightSplit.Width;
    FLeftPane.Width := Max(LeftMin, Min(Round(W * FDeckFraction), W - RightMin - MiddleMin));
    FRightPane.Width := Max(RightMin, Min(Round(W * FDiffFraction), W - FLeftPane.Width - MiddleMin));
    H := ClientHeight - FToolbar.Height - FStatus.Height - FBottomSplit.Height;
    FBottomPane.Height := Max(Line * 6, Min(Round(H * FLogFraction), H - Line * 19));
    FBottomPane.Constraints.MinHeight := Line * 6;
    FWorkspace.Constraints.MinHeight := Line * 19;
  finally FAdjusting := False; end;
end;
procedure TScuWorkspaceForm.SplitMoved(Sender: TObject);
begin
  if FAdjusting or (FWorkspace.Width <= 0) or (ClientHeight <= 0) then Exit;
  if Sender = FBottomSplit then
    FLogFraction := FBottomPane.Height / Max(1, ClientHeight - FToolbar.Height - FStatus.Height - FBottomSplit.Height)
  else if Sender = FLeftSplit then
    FDeckFraction := FLeftPane.Width / Max(1, FWorkspace.ClientWidth - FLeftSplit.Width - FRightSplit.Width)
  else if Sender = FRightSplit then
    FDiffFraction := FRightPane.Width / Max(1, FWorkspace.ClientWidth - FLeftSplit.Width - FRightSplit.Width);
end;
procedure TScuWorkspaceForm.Resize;
begin
  inherited Resize;
  if (ClientWidth <> FLayoutWidth) or (ClientHeight <> FLayoutHeight) then RefreshLayout;
end;
procedure TScuWorkspaceForm.FontChanged(Sender: TObject);
begin inherited FontChanged(Sender); RefreshLayout; end;
procedure TScuWorkspaceForm.DoAutoAdjustLayout(const AMode: TLayoutAdjustmentPolicy;
  const AXProportion, AYProportion: Double);
begin inherited DoAutoAdjustLayout(AMode, AXProportion, AYProportion); RefreshLayout; end;
end.
