unit ScuCommandFiles;

{$mode objfpc}{$H+}

interface

uses
  Classes;

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
  SysUtils, ScuErrors, ScuFiles;

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
  Path: string;
  Lines: TStringList;
begin
  if Length(FFrames) >= 16 then
    raise EScuError.Create('Command files cannot be nested more than 16 levels.');
  if FileName = '' then
    raise EScuError.Create('Expected a command filename after !.');
  Path := FileName;
  if Active and (Path[1] <> DirectorySeparator) then
    Path := ExtractFileDir(FFrames[High(FFrames)].Path) + DirectorySeparator + Path;
  Path := ExpandFileName(Path);
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
