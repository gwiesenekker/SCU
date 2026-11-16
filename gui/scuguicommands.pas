unit ScuGuiCommands;
{$mode objfpc}{$H+}
interface
uses Classes, ScuCommands, ScuCommand;
function GuiCommand(Catalog: TCommandCatalog; const Name: string;
  const Parameters: array of string): TScuCommand;
function CommandText(Command: TScuCommand): string;
procedure CommandArguments(Command: TScuCommand; Destination: TStrings);
implementation
uses SysUtils, FPJSON, ScuBinder, ScuErrors;
function GuiCommand(Catalog: TCommandCatalog; const Name: string;
  const Parameters: array of string): TScuCommand;
var Binder: TCommandBinder; Index, Slot: Integer; Parameter: string; Definition: TParameterDefinition;
begin
  Index := Catalog.Commands.FindIndex(Name);
  if Index < 0 then raise EScuError.Create('Unknown GUI command: ' + Name);
  Binder := TCommandBinder.Create(Catalog.Commands[Index], bmExecution);
  try
    for Parameter in Parameters do Binder.Feed(Parameter);
    Binder.FinishTokens;
    for Slot := 0 to Binder.Count - 1 do
      if not Binder.Supplied[Slot] then
      begin
        Definition := Binder.ParameterAt(Slot);
        if Definition.HasDefault then Binder.Bind(Slot, Definition.DefaultValue, False)
        else if Definition.Required then
          raise EScuError.Create('Missing required argument: ' + Definition.Name);
      end;
    Result := Binder.CreateCommand;
  finally Binder.Free; end;
end;
function CommandText(Command: TScuCommand): string;
var I: Integer;
begin
  Result := Command.Name;
  for I := 0 to Command.ArgumentCount - 1 do
    Result := Result + ' ' + Command.Arguments[I].Name + '="' +
      StringToJSONString(Command.Arguments[I].Value) + '"';
end;
procedure CommandArguments(Command: TScuCommand; Destination: TStrings);
var I: Integer;
begin
  Destination.Add(Command.Name);
  // Omitted defaults must stay omitted: Provided affects output-directory rules.
  // Both processes bind the same catalog, reconstructing the same command object.
  for I := 0 to Command.ArgumentCount - 1 do
    if Command.Arguments[I].Provided then
      Destination.Add(Command.Arguments[I].Name + '=' + Command.Arguments[I].Value);
end;
end.
