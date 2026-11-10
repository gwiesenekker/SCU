unit ScuCommand;

{$mode objfpc}{$H+}

interface

uses
  Classes;

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
    FOptions: TStringList;
    function FindArgument(const Key: string): Integer;
    function GetArgument(Index: Integer): TScuArgument;
    function GetNamedArgument(const Key: string): TScuArgument;
    function GetArgumentValue(const Key: string): string;
    function GetArgumentProvided(const Key: string): Boolean;
    function GetArgumentCount: Integer;
    function GetOptionCount: Integer;
    function GetOptionName(Index: Integer): string;
    function GetOptionValue(Index: Integer): string;
    function GetSessionExit: Boolean;
  public
    constructor Create(const AName: string; const Arguments: TScuArguments; Options: TStrings);
    constructor CreateSessionExit;
    destructor Destroy; override;
    function HasArgument(const Key: string): Boolean;
    function HasOption(const Key: string): Boolean;
    function Option(const Key: string; const Default: string = ''): string;
    property Name: string read FName;
    property ArgumentCount: Integer read GetArgumentCount;
    property Arguments[Index: Integer]: TScuArgument read GetArgument;
    property Values[const Key: string]: string read GetArgumentValue; default;
    property Provided[const Key: string]: Boolean read GetArgumentProvided;
    property OptionCount: Integer read GetOptionCount;
    property OptionNames[Index: Integer]: string read GetOptionName;
    property OptionValues[Index: Integer]: string read GetOptionValue;
    property SessionExit: Boolean read GetSessionExit;
  end;

function IsSessionExit(const Name: string): Boolean;

implementation

uses
  SysUtils, ScuErrors;

function IsSessionExit(const Name: string): Boolean;
begin
  Result := (Name = 'quit_session') or (Name = 'quit');
end;

constructor TScuCommand.Create(const AName: string; const Arguments: TScuArguments; Options: TStrings);
begin
  inherited Create;
  FName := AName;
  FArguments := Copy(Arguments);
  FOptions := TStringList.Create;
  FOptions.CaseSensitive := True;
  if Assigned(Options) then
    FOptions.AddStrings(Options);
end;

constructor TScuCommand.CreateSessionExit;
var
  ExitArguments: TScuArguments;
begin
  SetLength(ExitArguments, 1);
  ExitArguments[0].Name := 'save_library';
  ExitArguments[0].Value := 'yes';
  Create('quit_session', ExitArguments, nil);
end;

destructor TScuCommand.Destroy;
begin
  FOptions.Free;
  inherited Destroy;
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
begin
  Result := GetNamedArgument(Key).Provided;
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

function TScuCommand.GetOptionCount: Integer;
begin
  Result := FOptions.Count;
end;

function TScuCommand.GetOptionName(Index: Integer): string;
begin
  Result := FOptions.Names[Index];
end;

function TScuCommand.GetOptionValue(Index: Integer): string;
begin
  Result := FOptions.ValueFromIndex[Index];
end;

function TScuCommand.HasOption(const Key: string): Boolean;
begin
  Result := FOptions.IndexOfName(Key) >= 0;
end;

function TScuCommand.Option(const Key: string; const Default: string): string;
var
  Index: Integer;
begin
  Index := FOptions.IndexOfName(Key);
  if Index < 0 then
    Result := Default
  else
    Result := FOptions.ValueFromIndex[Index];
end;

function TScuCommand.GetSessionExit: Boolean;
begin
  Result := IsSessionExit(FName);
end;

end.
