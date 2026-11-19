unit ScuGuiTab;
{$mode objfpc}{$H+}
interface
uses Classes, ComCtrls, SynEdit, ScuGuiReader;
type
  TScuEditorTab = class(TTabSheet)
  private
    FEditor: TSynEdit;
    FDeck, FSourceName, FPath, FDiskHash, FLineBreak: string;
    FStored, FSubmitted: RawByteString;
    FDiskExists, FDirty, FLoading: Boolean;
    FOnStateChanged: TNotifyEvent;
    procedure Changed(Sender: TObject);
    procedure SetDirty(Value: Boolean);
    procedure LoadText(const Bytes: RawByteString);
  public
    constructor CreateDeck(AOwner: TComponent; const LibraryPath, Deck: string; const Source: TGuiDeck);
    function SourceBytes: RawByteString;
    procedure PrepareSave;
    procedure AcceptSave(const Stored: TGuiDeck);
    property Deck: string read FDeck;
    property SourceName: string read FSourceName;
    property Dirty: Boolean read FDirty;
    property Editor: TSynEdit read FEditor;
    property OnStateChanged: TNotifyEvent read FOnStateChanged write FOnStateChanged;
  end;
implementation
uses ScuGuiPlatform, SysUtils, Controls, LazUTF8, ScuFiles, ScuCodec, ScuLibraryNames,
  SynHighlighterPas, SynHighlighterCpp;
constructor TScuEditorTab.CreateDeck(AOwner: TComponent; const LibraryPath, Deck: string; const Source: TGuiDeck);
var Working: RawByteString; Extension: string;
begin
  inherited Create(AOwner);
  FDeck := Deck; FSourceName := Source.SourceName; FStored := Source.Bytes;
  ValidateSourceFileName(FSourceName);
  FPath := IncludeTrailingPathDelimiter(ExtractFileDir(LibraryPath)) + FSourceName;
  FDiskExists := RegularFileExists(FPath);
  Working := FStored;
  if FDiskExists then
  begin
    Working := ReadBytes(FPath, MaxDeckSize, [rbNoFollow]);
    FDiskHash := AuditSHA256(Working);
  end;
  if (Pos(#0, Working) > 0) or (FindInvalidUTF8Codepoint(PChar(Working), Length(Working)) >= 0) then
    raise Exception.Create('The SynEdit editor supports UTF-8 text decks. This deck contains binary or non-UTF-8 bytes.');
  FEditor := TSynEdit.Create(Self);
  FEditor.Parent := Self; FEditor.Align := alClient;
  FEditor.Font.Name := DefaultGuiFont; FEditor.Font.Size := 11;
  FEditor.OnChange := @Changed;
  Extension := LowerCase(ExtractFileExt(FSourceName));
  if (Extension = '.pas') or (Extension = '.pp') or (Extension = '.lpr') then FEditor.Highlighter := TSynPasSyn.Create(Self)
  else if (Extension = '.c') or (Extension = '.h') or (Extension = '.cpp') or (Extension = '.hpp') then FEditor.Highlighter := TSynCppSyn.Create(Self)
;
  LoadText(Working);
  SetDirty(Working <> FStored);
end;
procedure TScuEditorTab.LoadText(const Bytes: RawByteString);
var SourceText: string; I, Start: Integer;
begin
  FLineBreak := #10;
  I := Pos(#10, Bytes);
  if (I > 1) and (Bytes[I-1] = #13) then FLineBreak := #13#10;
  SourceText := StringReplace(Bytes, #13#10, #10, [rfReplaceAll]);
  SourceText := StringReplace(SourceText, #13, #10, [rfReplaceAll]);
  FLoading := True;
  FEditor.Lines.BeginUpdate;
  try
    FEditor.Lines.Clear; Start := 1;
    for I := 1 to Length(SourceText) do
      if SourceText[I] = #10 then
      begin FEditor.Lines.Add(Copy(SourceText, Start, I - Start)); Start := I + 1; end;
    FEditor.Lines.Add(Copy(SourceText, Start, MaxInt));
    FEditor.Modified := False;
  finally FEditor.Lines.EndUpdate; FLoading := False; end;
end;
function TScuEditorTab.SourceBytes: RawByteString;
var I: Integer;
begin
  Result := '';
  for I := 0 to FEditor.Lines.Count - 1 do
  begin
    if I > 0 then Result := Result + FLineBreak;
    Result := Result + FEditor.Lines[I];
  end;
end;
procedure TScuEditorTab.SetDirty(Value: Boolean);
begin
  FDirty := Value; Caption := FDeck;
  if FDirty then Caption := Caption + '*';
  if Assigned(FOnStateChanged) then FOnStateChanged(Self);
end;
procedure TScuEditorTab.Changed(Sender: TObject);
begin if not FLoading then SetDirty(SourceBytes <> FStored); end;
procedure TScuEditorTab.PrepareSave;
var Exists: Boolean; Bytes: RawByteString;
begin
  Exists := RegularFileExists(FPath);
  if (Exists <> FDiskExists) or (Exists and
    (AuditSHA256(ReadBytes(FPath, MaxDeckSize, [rbNoFollow])) <> FDiskHash)) then
    raise Exception.Create('Working file changed outside SCU: ' + FSourceName + '. Close and reopen the tab before saving.');
  Bytes := SourceBytes;
  if Length(Bytes) > MaxDeckSize then raise Exception.Create('The deck exceeds the 64 MiB source limit.');
  AtomicWrite(FPath, Bytes, [awSourceOutput]);
  FSubmitted := Bytes; FDiskExists := True; FDiskHash := AuditSHA256(Bytes);
end;
procedure TScuEditorTab.AcceptSave(const Stored: TGuiDeck);
begin
  if Stored.Bytes <> FSubmitted then
    raise Exception.Create('The stored deck changed during save. The editor buffer was kept; refresh before building.');
  FStored := FSubmitted;
  SetDirty(SourceBytes <> FStored);
  FEditor.Modified := FDirty;
end;
end.
