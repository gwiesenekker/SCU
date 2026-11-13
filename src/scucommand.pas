unit ScuCommand;

{$mode objfpc}{$H+}

interface

type
  TScuArgument = record
    Name, Value: string;
    Provided: Boolean;
  end;
  TScuArguments = array of TScuArgument;

  TScuCommand = class
  private
    FName: string;
    FArguments: TScuArguments;
    function FindArgument(const Key: string): Integer;
    function GetArgument(Index: Integer): TScuArgument;
    function GetNamedArgument(const Key: string): TScuArgument;
    function GetArgumentValue(const Key: string): string;
    function GetArgumentProvided(const Key: string): Boolean;
    function GetArgumentCount: Integer;
    function GetSessionExit: Boolean;
  public
    constructor Create(const AName: string; const Arguments: TScuArguments);
    constructor CreateSessionExit;
    function HasArgument(const Key: string): Boolean;
    function Argument(const Key: string; const Default: string = ''): string;
    property Name: string read FName;
    property ArgumentCount: Integer read GetArgumentCount;
    property Arguments[Index: Integer]: TScuArgument read GetArgument;
    property Values[const Key: string]: string read GetArgumentValue; default;
    property Provided[const Key: string]: Boolean read GetArgumentProvided;
    property SessionExit: Boolean read GetSessionExit;
  end;

function IsSessionExit(const Name: string): Boolean;

implementation

uses
  SysUtils, ScuErrors;

function IsSessionExit(const Name: string): Boolean;
begin
  Result := Name = 'quit_session';
end;

constructor TScuCommand.Create(const AName: string; const Arguments: TScuArguments);
begin
  inherited Create;
  FName := AName;
  FArguments := Copy(Arguments);
end;

constructor TScuCommand.CreateSessionExit;
begin
  Create('quit_session', nil);
end;

function TScuCommand.FindArgument(const Key: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FArguments) do
    if FArguments[Index].Name = Key then
      Exit(Index);
  Result := -1;
end;

function TScuCommand.HasArgument(const Key: string): Boolean;
begin
  Result := FindArgument(Key) >= 0;
end;

function TScuCommand.GetNamedArgument(const Key: string): TScuArgument;
var
  Index: Integer;
begin
  Index := FindArgument(Key);
  if Index < 0 then
    raise EScuError.CreateFmt('Missing argument %s for %s.', [Key, FName]);
  Result := FArguments[Index];
end;

function TScuCommand.GetArgumentValue(const Key: string): string;
begin
  Result := GetNamedArgument(Key).Value;
end;

function TScuCommand.GetArgumentProvided(const Key: string): Boolean;
var
  Index: Integer;
begin
  Index := FindArgument(Key);
  Result := (Index >= 0) and FArguments[Index].Provided;
end;

function TScuCommand.GetArgument(Index: Integer): TScuArgument;
begin
  if (Index < 0) or (Index >= Length(FArguments)) then
    raise EScuError.CreateFmt('Missing argument %d for %s.', [Index + 1, FName]);
  Result := FArguments[Index];
end;

function TScuCommand.GetArgumentCount: Integer;
begin
  Result := Length(FArguments);
end;

function TScuCommand.Argument(const Key: string; const Default: string): string;
var
  Index: Integer;
begin
  Index := FindArgument(Key);
  if Index < 0 then
    Exit(Default);
  Result := FArguments[Index].Value;
end;

function TScuCommand.GetSessionExit: Boolean;
begin
  Result := IsSessionExit(FName);
end;

end.
