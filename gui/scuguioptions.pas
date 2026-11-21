unit ScuGuiOptions;
{$mode objfpc}{$H+}
interface
uses Classes, Forms, Controls, StdCtrls, ComCtrls, Graphics, FPJSON;
type
  TScuOptionsDialog = class(TForm)
  private
    FPages: TPageControl;
    FFont: TFont;
    FFontPreview: TLabel;
    FFields: array[0..5] of TEdit;
    FInitial: array[0..5] of string;
    FBuild, FPatterns, FTracker: TMemo;
    FTrackerEnding, FInitialBuild, FInitialPatterns, FInitialTracker: string;
    FChanges: TStringList;
    procedure PickFont(Sender: TObject);
    procedure UpdateFontPreview;
  public
    constructor CreateOptions(AOwner: TComponent; InitialFont: TFont;
      Configuration: TJSONObject; PrefixEditable: Boolean);
    destructor Destroy; override;
    procedure CollectChanges;
    property EditorFont: TFont read FFont;
    property Changes: TStringList read FChanges;
    property Pages: TPageControl read FPages;
    function LibraryField(Index: Integer): TEdit;
    property BuildField: TMemo read FBuild;
    function TrackerBytes: string;
    function TrackerChanged: Boolean;
    property TrackerField: TMemo read FTracker;
    property PatternsField: TMemo read FPatterns;
  end;
implementation
uses ScuGuiLineEndings, SysUtils, Dialogs, ExtCtrls, ButtonPanel, ScuLibraryNames, ScuLibraryHeader;
const Names: array[0..5] of string = ('comment_prefix','editor','version_increment','revision_increment','release_directory','version_tracker');
  Keys: array[0..5] of string = ('comment_prefix','editor','version_increment','revision_increment','release_directory','version_tracker');
  Titles: array[0..5] of string = ('Default comment string (new decks)','External editor (JSON argument array)',
    'Version increment','Deck revision increment','Release directory','Version tracker (output filename)');
function Row(Owner: TComponent; Parent: TWinControl; const Caption: string): TPanel;
var LabelControl: TLabel;
begin
  Result := TPanel.Create(Owner); Result.Parent := Parent;
  Result.BevelOuter := bvNone; Result.Align := alTop; Result.AutoSize := True;
  Result.BorderSpacing.Around := 6;
  LabelControl := TLabel.Create(Owner); LabelControl.Parent := Result;
  LabelControl.Align := alTop; LabelControl.AutoSize := True; LabelControl.Caption := Caption;
end;
constructor TScuOptionsDialog.CreateOptions(AOwner: TComponent; InitialFont: TFont;
  Configuration: TJSONObject; PrefixEditable: Boolean);
var EditorPage, LibraryPage, PatternsPage, TrackerPage: TTabSheet; Scroll: TScrollBox; Container: TPanel;
  Buttons: TButtonPanel; Pick: TButton; Note: TLabel; I: Integer; Value: TJSONData;
begin
  inherited CreateNew(AOwner);
  Caption := 'Preferences'; Position := poOwnerFormCenter; BorderStyle := bsSizeable;
  Width := 740; Height := 680; Constraints.MinWidth := 550; Constraints.MinHeight := 440;
  FFont := TFont.Create; FFont.Assign(InitialFont); FChanges := TStringList.Create;
  Buttons := TButtonPanel.Create(Self); Buttons.Parent := Self;
  Buttons.Align := alBottom; Buttons.ShowButtons := [pbOK, pbCancel];
  FPages := TPageControl.Create(Self); FPages.Parent := Self; FPages.Align := alClient;
  EditorPage := TTabSheet.Create(Self); EditorPage.PageControl := FPages; EditorPage.Caption := 'Editor';
  FFontPreview := TLabel.Create(Self); FFontPreview.Parent := EditorPage;
  FFontPreview.Align := alTop; FFontPreview.AutoSize := True; FFontPreview.WordWrap := True; FFontPreview.BorderSpacing.Around := 12;
  Pick := TButton.Create(Self); Pick.Parent := EditorPage; Pick.Align := alTop;
  Pick.AutoSize := True; Pick.Caption := 'Choose editor font…'; Pick.BorderSpacing.Around := 12; Pick.OnClick := @PickFont;
  UpdateFontPreview;
  LibraryPage := TTabSheet.Create(Self); LibraryPage.PageControl := FPages; LibraryPage.Caption := 'Library';
  Scroll := TScrollBox.Create(Self); Scroll.Parent := LibraryPage; Scroll.Align := alClient;
  Scroll.HorzScrollBar.Visible := False; Scroll.BorderStyle := bsNone;
  Note := TLabel.Create(Self); Note.Parent := Scroll; Note.Align := alTop;
  Note.AutoSize := True; Note.WordWrap := True; Note.BorderSpacing.Around := 8;
  Note.Caption := 'The default comment string applies to new decks. Change it before the first revision of an open version. Other settings apply to the library.';
  if not Assigned(Configuration) then
  begin LibraryPage.Enabled := False; Note.Caption := 'Open a library to edit its configuration.'; Exit; end;
  // Build from bottom to top using LCL alignment; rows grow with their font.
  PatternsPage := TTabSheet.Create(Self); PatternsPage.PageControl := FPages; PatternsPage.Caption := 'File patterns';
  Note := TLabel.Create(Self); Note.Parent := PatternsPage; Note.Align := alTop;
  Note.BorderSpacing.Around := 8; Note.Caption := 'Monitored files and wildcards (one per line)';
  FPatterns := TMemo.Create(Self); FPatterns.Parent := PatternsPage; FPatterns.Align := alClient; FPatterns.BorderSpacing.Around := 8;
  FPatterns.ScrollBars := ssAutoVertical;
  if Configuration.Find('file_patterns') is TJSONArray then
    for I := 0 to TJSONArray(Configuration.Find('file_patterns')).Count-1 do
      FPatterns.Lines.Add(TJSONArray(Configuration.Find('file_patterns')).Strings[I]);
  FInitialPatterns := FPatterns.Text;
  TrackerPage := TTabSheet.Create(Self); TrackerPage.PageControl := FPages; TrackerPage.Caption := 'Version tracker';
  Container := Row(Self, TrackerPage, Titles[5]);
  FFields[5] := TEdit.Create(Self); FFields[5].Parent := Container; FFields[5].Align := alTop; FFields[5].Top := 10000;
  FFields[5].Text := Configuration.Get('version_tracker', ''); FInitial[5] := FFields[5].Text;
  FTracker := TMemo.Create(Self); FTracker.Parent := TrackerPage; FTracker.Align := alClient;
  FTracker.BorderSpacing.Around := 8; FTracker.ScrollBars := ssAutoBoth; FTracker.WordWrap := False;
  FTracker.Font.Assign(InitialFont);
  FInitialTracker := Configuration.Get('version_tracker_template', DefaultTrackerTemplate);
  FTracker.ReadOnly := not UniformLineEnding(FInitialTracker, FTrackerEnding);
  Note := TLabel.Create(Self); Note.Parent := TrackerPage; Note.Align := alBottom;
  Note.AutoSize := True; Note.WordWrap := True;
  Note.BorderSpacing.Around := 8;
  if FTracker.ReadOnly then Note.Caption := 'Mixed line endings. Use edit_version_tracker to edit this template.'
  else Note.Caption := 'Template macros: SCU$VERSION, SCU$DATE, SCU$TIME, SCU$DATE_TIME.';
  FTracker.Text := AdjustLineBreaks(FInitialTracker);
  FInitialTracker := FTracker.Text;
  Container := Row(Self, Scroll, 'Build command (run from the library directory)');
  FBuild := TMemo.Create(Self); FBuild.Parent := Container; FBuild.Align := alTop; FBuild.Height := 70; FBuild.Top := 10000;
  FBuild.Text := Configuration.Get('build_command', ''); FInitialBuild := FBuild.Text;
  for I := High(FFields)-1 downto 0 do
  begin
    Container := Row(Self, Scroll, Titles[I]);
    FFields[I] := TEdit.Create(Self); FFields[I].Parent := Container; FFields[I].Align := alTop; FFields[I].Top := 10000;
    Value := Configuration.Find(Keys[I]);
    if Assigned(Value) then
      if Value.JSONType = jtString then FFields[I].Text := Value.AsString else FFields[I].Text := Value.AsJSON;
    FInitial[I] := FFields[I].Text;
  end;
  FFields[0].Enabled := PrefixEditable;
end;
destructor TScuOptionsDialog.Destroy;
begin FFont.Free; FChanges.Free; inherited Destroy; end;
function TScuOptionsDialog.LibraryField(Index: Integer): TEdit;
begin Result := FFields[Index]; end;
procedure TScuOptionsDialog.UpdateFontPreview;
begin
  FFontPreview.Font.Assign(FFont);
  FFontPreview.Caption := FFont.Name + '  ' + IntToStr(FFont.Size) + ' pt' + LineEnding + 'program Hello; // Editor font preview';
end;
procedure TScuOptionsDialog.PickFont(Sender: TObject);
var Dialog: TFontDialog;
begin
  Dialog := TFontDialog.Create(Self);
  try
    Dialog.Font.Assign(FFont); Dialog.MinFontSize := 5; Dialog.MaxFontSize := 72;
    if Dialog.Execute then begin FFont.Assign(Dialog.Font); UpdateFontPreview; end;
  finally Dialog.Free; end;
end;
function TScuOptionsDialog.TrackerBytes: string;
begin
  Result := StringReplace(AdjustLineBreaks(FTracker.Text, tlbsLF), #10, FTrackerEnding, [rfReplaceAll]);
end;
function TScuOptionsDialog.TrackerChanged: Boolean;
begin Result := Assigned(FTracker) and not FTracker.ReadOnly and (FTracker.Text <> FInitialTracker); end;
procedure TScuOptionsDialog.CollectChanges;
var I: Integer; Patterns: TJSONArray;
begin
  FChanges.Clear;
  if not Assigned(FPatterns) then Exit;
  for I := 0 to High(FFields) do
    if Assigned(FFields[I]) and (FFields[I].Text <> FInitial[I]) then
      FChanges.Add(Names[I] + '=' + FFields[I].Text);
  if FBuild.Text <> FInitialBuild then FChanges.Add('build_command=' + FBuild.Text);
  if FPatterns.Text <> FInitialPatterns then
  begin
    Patterns := TJSONArray.Create;
    try
      for I := 0 to FPatterns.Lines.Count-1 do
        if Trim(FPatterns.Lines[I]) <> '' then
        begin
          ValidateFilePattern(Trim(FPatterns.Lines[I]));
          Patterns.Add(Trim(FPatterns.Lines[I]));
        end;
      FChanges.Add('file_patterns=' + Patterns.AsJSON);
    finally Patterns.Free; end;
  end;
end;
end.
