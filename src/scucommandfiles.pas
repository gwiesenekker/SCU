unit ScuCommandFiles;

{$mode objfpc}{$H+}

interface

uses
  Classes;

function ParseCommandFileName(const Specification: string): string;

type
  TCommandFiles = class
  private
    FFrames: array of record
      Path: string;
      Lines: TStringList;
      NextLine: Integer;
    end;
    procedure Pop;
  public
    destructor Destroy; override;
    procedure Clear;
    procedure Push(const FileName: string);
    function ReadLine(out Line, Location: string): Boolean;
    function Active: Boolean;
  end;

implementation

uses
  SysUtils, ScuErrors, ScuFiles, ScuPlatformPaths, ScuTokenizer;

function ParseCommandFileName(const Specification: string): string;
{$IFDEF WINDOWS}
var Value: string; Index, Last: SizeInt; Quote: Char;
begin
  // A Windows path uses literal backslashes, including UNC prefixes and a
  // trailing slash before a closing quote. Command-argument escapes do not
  // apply to the single filename following !.
  if Pos(#0, Specification) > 0 then
    raise EScuError.Create('A command filename cannot contain NUL bytes.');
  Value := Trim(Specification);
  Last := Length(Value);
  if Last = 0 then
    raise EScuError.Create('Expected one command filename after !. Quote filenames containing spaces.');
  Index := 1;
  if Value[1] in ['"', #39] then
  begin
    Quote := Value[1]; Inc(Index);
    while (Index <= Last) and (Value[Index] <> Quote) do Inc(Index);
    if Index > Last then raise EScuError.Create('Unclosed quote.');
    Result := Copy(Value, 2, Index - 2);
    Inc(Index);
  end
  else
  begin
    while (Index <= Last) and not (Value[Index] in [' ', #9]) do Inc(Index);
    Result := Copy(Value, 1, Index - 1);
  end;
  if Trim(Copy(Value, Index, MaxInt)) <> '' then
    raise EScuError.Create('Expected one command filename after !. Quote filenames containing spaces.');
end;
{$ELSE}
var Tokens: TStringList;
begin
  Tokens := TStringList.Create;
  try
    TokenizeCommand(Specification, Tokens);
    if Tokens.Count <> 1 then
      raise EScuError.Create('Expected one command filename after !. Quote filenames containing spaces.');
    Result := Tokens[0];
  finally
    Tokens.Free;
  end;
end;
{$ENDIF}

procedure TCommandFiles.Pop;
begin
  FFrames[High(FFrames)].Lines.Free;
  SetLength(FFrames, Length(FFrames) - 1);
end;

procedure TCommandFiles.Clear;
begin
  while Active do
    Pop;
end;

destructor TCommandFiles.Destroy;
begin
  Clear;
  inherited Destroy;
end;

function TCommandFiles.Active: Boolean;
begin
  Result := Length(FFrames) > 0;
end;

procedure TCommandFiles.Push(const FileName: string);
var
  Path, Parent: string;
  Lines: TStringList;
begin
  if Length(FFrames) >= 16 then
    raise EScuError.Create('Command files cannot be nested more than 16 levels.');
  if FileName = '' then
    raise EScuError.Create('Expected a command filename after !.');
  if Pos(#0, FileName) > 0 then
    raise EScuError.Create('A command filename cannot contain NUL bytes.');
  Parent := '';
  if Active then Parent := FFrames[High(FFrames)].Path;
  Path := ResolveCommandFilePath(FileName, Parent);
  Lines := TStringList.Create;
  try
    Lines.Text := ReadBytes(Path, 16 * 1024 * 1024);
    SetLength(FFrames, Length(FFrames) + 1);
    FFrames[High(FFrames)].Path := Path;
    FFrames[High(FFrames)].Lines := Lines;
    FFrames[High(FFrames)].NextLine := 0;
  except
    Lines.Free;
    raise;
  end;
end;

function TCommandFiles.ReadLine(out Line, Location: string): Boolean;
var
  Index: Integer;
begin
  while Active do
  begin
    Index := High(FFrames);
    if FFrames[Index].NextLine >= FFrames[Index].Lines.Count then
    begin
      Pop;
      Continue;
    end;
    Line := FFrames[Index].Lines[FFrames[Index].NextLine];
    Inc(FFrames[Index].NextLine);
    Location := FFrames[Index].Path + ':' + IntToStr(FFrames[Index].NextLine);
    Exit(True);
  end;
  Location := '';
  Result := False;
end;

end.
