unit ScuBinder;

{$mode objfpc}{$H+}

interface

uses
  ScuCommand, ScuCommands;

type
  TBindingMode = (bmExecution, bmCompletion);

  TCommandBinder = class
  private type
    TBinding = record
      Value: string;
      Supplied, Provided: Boolean;
    end;
  private
    FSpec: TCommandDefinition;
    FArguments, FOptions: TParameterDefinitions;
    FName, FPendingSpelling: string;
    FBindings: array of TBinding;
    FOptionOrder: array of Integer;
    FPendingSlot: Integer;
    FMode: TBindingMode;
    FPositionalOnly: Boolean;
    function GetCount: Integer;
    function GetSupplied(Slot: Integer): Boolean;
    function GetValue(Slot: Integer): string;
    procedure CheckDuplicate(Slot: Integer);
  public
    constructor Create(Spec: TCommandDefinition; Mode: TBindingMode);
    procedure Feed(const Token: string);
    procedure FinishTokens;
    procedure Bind(Slot: Integer; const Value: string; Provided: Boolean);
    function NextPositional: Integer;
    function NamedSlot(const Token: string; out EqualsAt: Integer): Integer;
    function PendingAccepts(const Token: string): Boolean;
    function ParameterAt(Slot: Integer): TParameterDefinition;
    function WithReservedSlot(Slot: Integer): TCommandBinder;
    function CreateCommand: TScuCommand;
    property Count: Integer read GetCount;
    property Name: string read FName;
    property Arguments: TParameterDefinitions read FArguments;
    property Options: TParameterDefinitions read FOptions;
    property PendingSlot: Integer read FPendingSlot;
    property PositionalOnly: Boolean read FPositionalOnly;
    property Supplied[Slot: Integer]: Boolean read GetSupplied;
    property Values[Slot: Integer]: string read GetValue;
  end;

implementation

uses
  Classes, ScuErrors;

constructor TCommandBinder.Create(Spec: TCommandDefinition; Mode: TBindingMode);
begin
  inherited Create;
  FSpec := Spec;
  FMode := Mode;
  FName := Spec.Name;
  FArguments := Spec.Arguments;
  FOptions := Spec.Options;
  FPendingSlot := -1;
  SetLength(FBindings, FArguments.Count + FOptions.Count);
end;

function TCommandBinder.GetCount: Integer;
begin
  Result := Length(FBindings);
end;

function TCommandBinder.GetSupplied(Slot: Integer): Boolean;
begin
  Result := FBindings[Slot].Supplied;
end;

function TCommandBinder.GetValue(Slot: Integer): string;
begin
  Result := FBindings[Slot].Value;
end;

function TCommandBinder.ParameterAt(Slot: Integer): TParameterDefinition;
begin
  if Slot < FArguments.Count then
    Result := FArguments[Slot]
  else
    Result := FOptions[Slot - FArguments.Count];
end;

function TCommandBinder.NextPositional: Integer;
var
  Slot: Integer;
begin
  for Slot := 0 to FArguments.Count - 1 do
    if not Supplied[Slot] then
      Exit(Slot);
  Result := -1;
end;

function TCommandBinder.NamedSlot(const Token: string; out EqualsAt: Integer): Integer;
var
  OptionSlot: Integer;
  Key: string;
begin
  Result := -1;
  EqualsAt := 0;
  if FPositionalOnly then
    Exit;
  EqualsAt := Pos('=', Token);
  if Copy(Token, 1, 2) = '--' then
  begin
    if Token = '--' then
      Exit;
    if EqualsAt > 0 then
      Key := Copy(Token, 3, EqualsAt - 3)
    else
      Key := Copy(Token, 3, MaxInt);
    OptionSlot := FOptions.FindIndex(Key);
  end
  else
  begin
    if EqualsAt <= 1 then
      Exit;
    Key := Copy(Token, 1, EqualsAt - 1);
    Result := FArguments.FindIndex(Key);
    OptionSlot := FOptions.FindIndex(Key);
  end;
  if OptionSlot >= 0 then
    Result := FArguments.Count + OptionSlot;
end;

function TCommandBinder.PendingAccepts(const Token: string): Boolean;
var
  EqualsAt: Integer;
begin
  Result := (FPendingSlot >= 0) and
    (not ParameterAt(FPendingSlot).Required or
      ((Copy(Token, 1, 2) <> '--') and (NamedSlot(Token, EqualsAt) < 0)));
end;

procedure TCommandBinder.CheckDuplicate(Slot: Integer);
var
  Key: string;
begin
  if (FMode <> bmExecution) or not Supplied[Slot] then
    Exit;
  Key := ParameterAt(Slot).Name;
  if Slot < FArguments.Count then
    raise EScuError.CreateFmt('Duplicate argument %s.', [Key]);
  raise EScuError.CreateFmt('Duplicate option --%s.', [Key]);
end;

procedure TCommandBinder.Bind(Slot: Integer; const Value: string; Provided: Boolean);
begin
  CheckDuplicate(Slot);
  // The catalog validates defaults, and the CLI validates answers at the prompt.
  if (FMode = bmExecution) and Provided then
    ParameterAt(Slot).Validate(Value);
  if (Slot >= FArguments.Count) and not Supplied[Slot] then
  begin
    SetLength(FOptionOrder, Length(FOptionOrder) + 1);
    FOptionOrder[High(FOptionOrder)] := Slot;
  end;
  FBindings[Slot].Value := Value;
  FBindings[Slot].Supplied := True;
  FBindings[Slot].Provided := Provided;
end;

procedure TCommandBinder.Feed(const Token: string);
var
  Slot, EqualsAt: Integer;
begin
  if FPendingSlot >= 0 then
  begin
    Slot := FPendingSlot;
    if PendingAccepts(Token) then
    begin
      FPendingSlot := -1;
      Bind(Slot, Token, True);
      Exit;
    end;
    FinishTokens;
  end;
  if not FPositionalOnly and (Token = '--') then
  begin
    FPositionalOnly := True;
    Exit;
  end;
  Slot := NamedSlot(Token, EqualsAt);
  if Slot >= 0 then
  begin
    if EqualsAt > 0 then
      Bind(Slot, Copy(Token, EqualsAt + 1, MaxInt), True)
    else
    begin
      FPendingSlot := Slot;
      FPendingSpelling := Token;
    end;
  end
  else if not FPositionalOnly and (Copy(Token, 1, 2) = '--') then
  begin
    if FMode = bmExecution then
      raise EScuError.CreateFmt('Unknown option %s for %s.', [Token, FName]);
  end
  else
  begin
    Slot := NextPositional;
    if Slot >= 0 then
      Bind(Slot, Token, True)
    else if FMode = bmExecution then
      raise EScuError.CreateFmt('Too many arguments for %s. Run scu help.', [FName]);
  end;
end;

procedure TCommandBinder.FinishTokens;
begin
  if FPendingSlot < 0 then
    Exit;
  if FMode = bmExecution then
  begin
    if not ParameterAt(FPendingSlot).Required then
      raise EScuError.CreateFmt('Expected a value for %s.', [FPendingSpelling]);
    CheckDuplicate(FPendingSlot);
  end;
  FPendingSlot := -1;
end;

function TCommandBinder.WithReservedSlot(Slot: Integer): TCommandBinder;
begin
  // The token being completed separates the earlier bindings from the tail.
  Result := TCommandBinder.Create(FSpec, FMode);
  try
    Result.FBindings := Copy(FBindings);
    Result.FOptionOrder := Copy(FOptionOrder);
    Result.FPositionalOnly := FPositionalOnly;
    if Slot >= 0 then
      Result.FBindings[Slot].Supplied := True;
  except
    Result.Free;
    raise;
  end;
end;

function TCommandBinder.CreateCommand: TScuCommand;
var
  BoundArguments: TScuArguments;
  BoundOptions: TStringList;
  Slot: Integer;
begin
  SetLength(BoundArguments, FArguments.Count);
  for Slot := 0 to High(BoundArguments) do
  begin
    BoundArguments[Slot].Name := ParameterAt(Slot).Name;
    BoundArguments[Slot].Value := Values[Slot];
    BoundArguments[Slot].Provided := FBindings[Slot].Provided;
  end;
  BoundOptions := TStringList.Create;
  try
    BoundOptions.CaseSensitive := True;
    for Slot in FOptionOrder do
      BoundOptions.Add(ParameterAt(Slot).Name + '=' + Values[Slot]);
    Result := TScuCommand.Create(FName, BoundArguments, BoundOptions);
  finally
    BoundOptions.Free;
  end;
end;

end.
