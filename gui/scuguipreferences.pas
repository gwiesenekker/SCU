unit ScuGuiPreferences;
{$mode objfpc}{$H+}
interface
uses Graphics;
type
  TScuGuiPreferences = class
  private
    FEditorFont: TFont;
    FPath: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Load;
    procedure Save;
    property EditorFont: TFont read FEditorFont;
    property Path: string read FPath;
  end;
implementation
uses SysUtils, FPJSON, ScuJSON, ScuFiles, ScuPlatformPaths, ScuGuiPlatform;
constructor TScuGuiPreferences.Create;
begin
  inherited Create;
  FEditorFont := TFont.Create; FEditorFont.Name := DefaultGuiFont; FEditorFont.Size := 11;
  FPath := GuiPreferencesPath;
end;
destructor TScuGuiPreferences.Destroy;
begin FEditorFont.Free; inherited Destroy; end;
procedure TScuGuiPreferences.Load;
var Document: TJSONObject; Size: Integer; Family: string;
begin
  if not {$IFDEF WINDOWS}RegularFileExists{$ELSE}FileExists{$ENDIF}(FPath) then Exit;
  Document := ParseObject(ReadBytes(FPath, 65536), FPath);
  try
    Family := Field(Document, 'editor_font', jtString, FPath).AsString;
    Size := Field(Document, 'editor_font_size', jtNumber, FPath).AsInteger;
    if (Family = '') or (Length(Family) > 256) or (Size < 5) or (Size > 72) then
      raise Exception.Create('Invalid editor font preferences in ' + FPath);
    FEditorFont.Name := Family; FEditorFont.Size := Size;
    FEditorFont.Style := [];
    if Document.Get('bold', False) then FEditorFont.Style := FEditorFont.Style + [fsBold];
    if Document.Get('italic', False) then FEditorFont.Style := FEditorFont.Style + [fsItalic];
    if Document.Get('underline', False) then FEditorFont.Style := FEditorFont.Style + [fsUnderline];
    if Document.Get('strike_out', False) then FEditorFont.Style := FEditorFont.Style + [fsStrikeOut];
  finally Document.Free; end;
end;
procedure TScuGuiPreferences.Save;
var Document: TJSONObject;
begin
  EnsureGuiPreferencesDirectory(ExtractFileDir(FPath));
  Document := TJSONObject.Create;
  try
    Document.Add('editor_font', FEditorFont.Name); Document.Add('editor_font_size', FEditorFont.Size);
    Document.Add('bold', fsBold in FEditorFont.Style); Document.Add('italic', fsItalic in FEditorFont.Style);
    Document.Add('underline', fsUnderline in FEditorFont.Style); Document.Add('strike_out', fsStrikeOut in FEditorFont.Style);
    AtomicWrite(FPath, Document.FormatJSON + LineEnding);
  finally Document.Free; end;
end;
end.
