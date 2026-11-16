unit ScuGuiTabs;
{$mode objfpc}{$H+}
interface
uses Classes, Controls, ComCtrls, Graphics, Types;
type
  TScuTabCloseEvent = procedure(Sender: TObject; Page: TTabSheet) of object;
  TScuTabBar = class(TCustomControl)
  private
    FPages: TPageControl; // Borrowed; the form owns the pages and this bar.
    FFirst: Integer;
    FOnClose: TScuTabCloseEvent;
    function TabWidth(Index: Integer): Integer;
    function ArrowWidth: Integer;
    function VisibleRight: Integer;
    function CanScrollRight: Boolean;
    procedure Activate(Index: Integer);
  protected
    procedure Paint; override;
    procedure FontChanged(Sender: TObject); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure RefreshTabs;
    procedure ShowActiveTab;
    procedure Cycle(Backwards: Boolean);
    function TabBounds(Index: Integer): TRect;
    function CloseBounds(Index: Integer): TRect;
    property Pages: TPageControl read FPages write FPages;
    property OnClose: TScuTabCloseEvent read FOnClose write FOnClose;
  end;
implementation
uses Math, SysUtils, LCLType;
constructor TScuTabBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner); TabStop := True; DoubleBuffered := True;
  ControlStyle := ControlStyle + [csOpaque]; ShowHint := True;
  Color := clBtnFace; Height := 36;
end;
procedure TScuTabBar.FontChanged(Sender: TObject);
begin
  inherited FontChanged(Sender);
  Canvas.Font.Assign(Font); Height := Max(30, Canvas.TextHeight('Ag') + 18);
  Invalidate;
end;
function TScuTabBar.ArrowWidth: Integer;
begin Canvas.Font.Assign(Font); Result := Max(24, Canvas.TextHeight('Ag') + 10); end;
function TScuTabBar.TabWidth(Index: Integer): Integer;
begin
  Canvas.Font.Assign(Font); Canvas.Font.Style := Canvas.Font.Style + [fsBold];
  Result := EnsureRange(Canvas.TextWidth(FPages.Pages[Index].Caption) + ArrowWidth + 30,
    110, Max(110, Min(280, ClientWidth - 2 * ArrowWidth)));
end;
function TScuTabBar.VisibleRight: Integer;
begin Result := Max(0, ClientWidth - 2 * ArrowWidth); end;
function TScuTabBar.CanScrollRight: Boolean;
var Last: TRect;
begin
  Result := False;
  if not Assigned(FPages) or (FPages.PageCount = 0) then Exit;
  Last := TabBounds(FPages.PageCount-1);
  Result := (Last.Right <= Last.Left) or (Last.Right-Last.Left < TabWidth(FPages.PageCount-1));
end;
function TScuTabBar.TabBounds(Index: Integer): TRect;
var I, X: Integer;
begin
  Result := Rect(0,0,0,0);
  if not Assigned(FPages) or (Index < FFirst) or (Index >= FPages.PageCount) then Exit;
  X := 0;
  for I := FFirst to Index - 1 do Inc(X, TabWidth(I) + 3);
  if X >= VisibleRight then Exit;
  Result := Rect(X, 3, Min(X + TabWidth(Index), VisibleRight), ClientHeight - 1);
end;
function TScuTabBar.CloseBounds(Index: Integer): TRect;
begin
  Result := TabBounds(Index);
  if Result.Right - Result.Left < ArrowWidth + 20 then Exit(Rect(0,0,0,0));
  Result.Left := Max(Result.Left, Result.Right - ArrowWidth);
end;
procedure TScuTabBar.RefreshTabs;
begin
  if Assigned(FPages) then FFirst := EnsureRange(FFirst, 0, Max(0, FPages.PageCount-1));
  Invalidate;
end;
procedure TScuTabBar.ShowActiveTab;
var Bounds: TRect; Active: Integer;
begin
  if not Assigned(FPages) or (FPages.PageCount = 0) then begin RefreshTabs; Exit; end;
  Active := FPages.ActivePageIndex;
  if Active < FFirst then FFirst := Active;
  while FFirst < Active do
  begin
    Bounds := TabBounds(Active);
    if (Bounds.Right > Bounds.Left) and (Bounds.Right - Bounds.Left >= TabWidth(Active)) then Break;
    Inc(FFirst);
  end;
  RefreshTabs;
end;
procedure TScuTabBar.Activate(Index: Integer);
begin
  if not Assigned(FPages) or (Index < 0) or (Index >= FPages.PageCount) then Exit;
  FPages.ActivePageIndex := Index; ShowActiveTab;
end;
procedure TScuTabBar.Cycle(Backwards: Boolean);
var Index: Integer;
begin
  if not Assigned(FPages) or (FPages.PageCount = 0) then Exit;
  Index := FPages.ActivePageIndex;
  if Backwards then Dec(Index) else Inc(Index);
  Activate((Index + FPages.PageCount) mod FPages.PageCount);
end;
procedure TScuTabBar.Paint;
var I, Mid, Cross, Limit: Integer; Bounds, CloseRect, TextRect: TRect;
  LabelText: string; Active: Boolean;
begin
  Canvas.Brush.Color := clBtnFace; Canvas.FillRect(ClientRect);
  Canvas.Pen.Color := clBtnShadow;
  Canvas.Line(0, ClientHeight-1, ClientWidth, ClientHeight-1);
  if not Assigned(FPages) then Exit;
  for I := FFirst to FPages.PageCount - 1 do
  begin
    Bounds := TabBounds(I); if Bounds.Right <= Bounds.Left then Break;
    Active := I = FPages.ActivePageIndex;
    if Active then Canvas.Brush.Color := clWindow else Canvas.Brush.Color := clBtnFace;
    Canvas.Pen.Color := clBtnShadow; Canvas.Rectangle(Bounds);
    if Active then
    begin
      Canvas.Brush.Color := clHighlight;
      Canvas.FillRect(Rect(Bounds.Left+1, Bounds.Top+1, Bounds.Right-1, Bounds.Top+4));
    end;
    if Bounds.Right - Bounds.Left < ArrowWidth + 20 then Continue;
    Canvas.Font.Assign(Font);
    if Active then Canvas.Font.Style := Canvas.Font.Style + [fsBold];
    if Enabled then Canvas.Font.Color := clWindowText else Canvas.Font.Color := clGrayText;
    CloseRect := CloseBounds(I); TextRect := Bounds;
    Inc(TextRect.Left, 12); TextRect.Right := CloseRect.Left - 4;
    LabelText := FPages.Pages[I].Caption;
    Limit := Max(0, TextRect.Right - TextRect.Left);
    if Canvas.TextWidth(LabelText) > Limit then
    begin
      while (Length(LabelText) > 0) and (Canvas.TextWidth(LabelText + '…') > Limit) do
        Delete(LabelText, Length(LabelText), 1);
      LabelText := LabelText + '…';
    end;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(TextRect.Left, Bounds.Top + (Bounds.Bottom-Bounds.Top-Canvas.TextHeight('Ag')) div 2, LabelText);
    Canvas.Brush.Style := bsSolid;
    Canvas.Pen.Color := Canvas.Font.Color;
    Mid := (CloseRect.Top + CloseRect.Bottom) div 2;
    Cross := Max(4, ArrowWidth div 7);
    Canvas.Line((CloseRect.Left+CloseRect.Right) div 2-Cross, Mid-Cross,
      (CloseRect.Left+CloseRect.Right) div 2+Cross, Mid+Cross);
    Canvas.Line((CloseRect.Left+CloseRect.Right) div 2-Cross, Mid+Cross,
      (CloseRect.Left+CloseRect.Right) div 2+Cross, Mid-Cross);
    if Focused and Active then begin InflateRect(TextRect,-1,-4); Canvas.DrawFocusRect(TextRect); end;
  end;
  Canvas.Font.Assign(Font); Canvas.Brush.Color := clBtnFace;
  if Enabled and (FFirst > 0) then Canvas.Font.Color := clWindowText else Canvas.Font.Color := clGrayText;
  Canvas.TextOut(VisibleRight + ArrowWidth div 3, (ClientHeight-Canvas.TextHeight('‹')) div 2, '‹');
  if Enabled and CanScrollRight then Canvas.Font.Color := clWindowText else Canvas.Font.Color := clGrayText;
  Canvas.TextOut(VisibleRight + ArrowWidth + ArrowWidth div 3, (ClientHeight-Canvas.TextHeight('›')) div 2, '›');
end;
procedure TScuTabBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var I: Integer; P: TPoint;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled or not Assigned(FPages) then Exit;
  SetFocus;
  if X >= VisibleRight then
  begin
    if X < VisibleRight + ArrowWidth then FFirst := Max(0, FFirst-1)
    else if CanScrollRight then Inc(FFirst);
    Invalidate; Exit;
  end;
  P := Point(X,Y);
  for I := FFirst to FPages.PageCount-1 do
    if PtInRect(TabBounds(I), P) then
    begin
      if PtInRect(CloseBounds(I), P) then
      begin if Assigned(FOnClose) then FOnClose(Self, FPages.Pages[I]); end
      else Activate(I);
      Exit;
    end;
end;
procedure TScuTabBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var I: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  Hint := '';
  if not Assigned(FPages) then Exit;
  if X >= VisibleRight then
  begin
    if X < VisibleRight + ArrowWidth then Hint := 'Scroll tabs left' else Hint := 'Scroll tabs right';
    Exit;
  end;
  for I := FFirst to FPages.PageCount-1 do
    if PtInRect(TabBounds(I), Point(X,Y)) then
    begin
      Hint := FPages.Pages[I].Caption;
      if PtInRect(CloseBounds(I), Point(X,Y)) then Hint := 'Close ' + Hint;
      Exit;
    end;
end;
procedure TScuTabBar.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_LEFT: begin Cycle(True); Key := 0; end;
    VK_RIGHT: begin Cycle(False); Key := 0; end;
    VK_HOME: begin Activate(0); Key := 0; end;
    VK_END: if Assigned(FPages) then begin Activate(FPages.PageCount-1); Key := 0; end;
  end;
end;
function TScuTabBar.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if not Assigned(FPages) or not Enabled then Exit;
  if WheelDelta > 0 then FFirst := Max(0, FFirst-1)
  else if CanScrollRight then Inc(FFirst);
  Invalidate;
end;
end.
