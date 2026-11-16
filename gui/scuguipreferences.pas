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
uses SysUtils, FPJSON, ScuJSON, ScuFiles;
constructor TScuGuiPreferences.Create;
var Directory: string;
begin
  inherited Create;
  FEditorFont := TFont.Create; FEditorFont.Name := 'monospace'; FEditorFont.Size := 11;
  Directory := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Directory = '' then Directory := IncludeTrailingPathDelimiter(GetUserDir) + '.config';
  FPath := IncludeTrailingPathDelimiter(Directory) + 'scu/gui.json';
end;
destructor TScuGuiPreferences.Destroy;
begin FEditorFont.Free; inherited Destroy; end;
procedure TScuGuiPreferences.Load;
var Document: TJSONObject; Size: Integer; Family: string;
begin
  if not FileExists(FPath) then Exit;
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
  if not ForceDirectories(ExtractFileDir(FPath)) then
    raise Exception.Create('Could not create preferences directory: ' + ExtractFileDir(FPath));
  Document := TJSONObject.Create;
  try
    Document.Add('editor_font', FEditorFont.Name); Document.Add('editor_font_size', FEditorFont.Size);
    Document.Add('bold', fsBold in FEditorFont.Style); Document.Add('italic', fsItalic in FEditorFont.Style);
    Document.Add('underline', fsUnderline in FEditorFont.Style); Document.Add('strike_out', fsStrikeOut in FEditorFont.Style);
    AtomicWrite(FPath, Document.FormatJSON + LineEnding);
  finally Document.Free; end;
end;
end.
