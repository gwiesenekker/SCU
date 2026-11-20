program ExecutorProbe;

{$mode objfpc}{$H+}

uses
  Classes, FPJSON, SysUtils, ScuCommand, ScuErrors, ScuExecutor, ScuLibraryModel, ScuLibraryStore, ScuOutput, ScuSQLite, ScuTable;

type
  TCapturedOutput = class(TScuOutput)
  public
    Text, Diagnostics: RawByteString;
    procedure Write(const Data: RawByteString); override;
    procedure Report(const Message: string); override;
    procedure Flush; override;
  end;

procedure TCapturedOutput.Write(const Data: RawByteString);
begin
  Text := Text + Data;
end;

procedure TCapturedOutput.Report(const Message: string);
begin
  Diagnostics := Diagnostics + Message + LineEnding;
end;

procedure TCapturedOutput.Flush;
begin
end;

procedure CheckTableDisplayWidths;
var
  Capture: TCapturedOutput;
  Table: TScuTable;
begin
  Capture := TCapturedOutput.Create;
  Table := nil;
  try
    Table := TScuTable.Create(['Name', 'Value']);
    Table.AddRow([#$E7#$95#$8C, 'wide']);
    Table.AddRow(['caf'#$C3#$A9, 'accent']);
    Table.WriteTo(Capture);
    if Capture.Text <> 'Name  Value' + LineEnding +
      #$E7#$95#$8C'    wide' + LineEnding + 'caf'#$C3#$A9'  accent' + LineEnding then
      raise Exception.Create('Table columns use byte counts instead of display widths.');
    Capture.Text := '';
    Table.WriteTo(Capture, 10);
    if Capture.Text <> 'Nam  Value' + LineEnding + 'e    ' + LineEnding +
      #$E7#$95#$8C'   wide' + LineEnding + 'caf  accen' + LineEnding +
      #$C3#$A9'    t' + LineEnding then
      raise Exception.Create('Wrapped table cells lost characters or column alignment.');
  finally
    Table.Free;
    Capture.Free;
  end;
end;

procedure CheckUnloadedPayloadGuards;
var
  Entry: TLibraryRevision;
  Operation, Rejected: Integer;
begin
  Entry := TLibraryRevision.CreateIndex('unloaded', '0.000', 1);
  try
    Rejected := 0;
    for Operation := 0 to 3 do
      try
        case Operation of
          0: Entry.Serialized;
          1: Entry.CloneJSON.Free;
          2: Entry.CopyMetadataJSON;
          3: Entry.Decode;
        end;
      except
        on E: EScuError do
        begin
          if E.Message <> 'Revision payload for deck "unloaded" has not been loaded.' then
            raise;
          Inc(Rejected);
        end;
      end;
    if Rejected <> 4 then
      raise Exception.Create('An unloaded payload accessor accepted an unloaded revision.');
  finally
    Entry.Free;
  end;
end;

procedure CheckLazyRevision(const Path: string);
var
  Database: TSQLiteLibrary;
  Store: TLibraryStore;
  Entry: TLibraryRevision;
begin
  Database := TSQLiteLibrary.OpenRead(Path);
  try
    Store := TLibraryStore.Load(Path, Database);
    try
      Entry := Store[0];
      if Entry.Loaded or (Entry.Name <> 'example.pas') or (Entry.Number <> 0) then
        raise Exception.Create('Expected a revision index without a payload.');
      if (Store.PayloadAt(0, Database) <> Entry) or (Store[0] <> Entry) or
        not Entry.Loaded or (Entry.CommentPrefix <> '#') then
        raise Exception.Create('Loading the payload changed the revision entry.');
      if Store.PayloadAt(0, nil) <> Entry then
        raise Exception.Create('Expected the loaded payload to be cached by the entry.');
    finally
      Store.Free;
    end;
  finally
    Database.Free;
  end;
end;

procedure CheckBackendLibraryNames(const Path: string);
var
  Capture: TCapturedOutput;
  Executor: TScuExecutor;
  Command: TScuCommand;
  Base: string;
  Rejected: Boolean;
begin
  Base := ChangeFileExt(Path, '') + '-auto';
  Capture := TCapturedOutput.Create;
  try
    Executor := TScuExecutor.Create(Base, False, Capture);
    try
      Command := TScuCommand.Create('initialize_library', nil);
      try
        Executor.Execute(Command);
      finally
        Command.Free;
      end;
    finally
      Executor.Free;
    end;
    if not FileExists(Base + '.sqlite') or FileExists(Base) then
      raise Exception.Create('Backend did not append .sqlite to an extensionless library.');
    Rejected := False;
    try
      Executor := TScuExecutor.Create(Base + '.json', False, Capture);
      Executor.Free;
    except
      on E: EScuError do
      begin
        if Pos('.sqlite extension', E.Message) = 0 then
          raise;
        Rejected := True;
      end;
    end;
    if not Rejected or FileExists(Base + '.json') or FileExists(Base + '.json.lock') then
      raise Exception.Create('Backend accepted an invalid library extension.');
  finally
    Capture.Free;
  end;
end;



procedure CheckLegacyNumberGuards;
var
  Entry: TLibraryRevision;
  Payload: TJSONObject;
  Rejected: Boolean;
begin
  Entry := TLibraryRevision.CreateIndex('modern', '0.000', 1);
  try
    Rejected := False;
    try
      Entry.SetLegacyNumber(1);
    except
      on E: EScuError do Rejected := True;
    end;
    if not Rejected then raise Exception.Create('Modern revision number was mutable.');
  finally
    Entry.Free;
  end;
  Payload := TJSONObject.Create;
  Payload.Add('deck', 'legacy');
  Entry := TLibraryRevision.CreatePayload(Payload, 1);
  try
    Entry.SetLegacyNumber(0);
    if (Entry.Number <> 0) or (Pos('deck_revision', Entry.Serialized) > 0) then
      raise Exception.Create('Legacy numbering changed its audited payload.');
  finally
    Entry.Free;
    Payload.Free;
  end;
end;

var
  Capture: TCapturedOutput;
  Executor: TScuExecutor;
  Command: TScuCommand;
  Arguments: TScuArguments;

begin
  Capture := TCapturedOutput.Create;
  Executor := TScuExecutor.Create(ParamStr(1), False, Capture);
  try
    Command := TScuCommand.Create('unregistered_command', nil);
    try
      try
        Executor.Execute(Command);
        raise Exception.Create('Expected an unknown command to be rejected.');
      except
        on E: EScuError do
          if E.Message <> 'No implementation for command "unregistered_command".' then
            raise;
      end;
      if FileExists(ParamStr(1)) or FileExists(ParamStr(1) + '.lock') then
        raise Exception.Create('Unknown command touched the library.');
    finally
      Command.Free;
    end;

    Command := TScuCommand.Create('initialize_library', nil);
    try
      Executor.Execute(Command);
    finally
      Command.Free;
    end;

    SetLength(Arguments, 3);
    Arguments[0].Name := 'deck_name';
    Arguments[0].Value := 'example.pas';
    Arguments[0].Provided := True;
    Arguments[1].Name := 'from_file';
    Arguments[2].Name := 'comment_prefix';
    Arguments[2].Value := '#';
    Arguments[2].Provided := True;
    Command := TScuCommand.Create('create_deck', Arguments);
    try
      Arguments[0].Value := 'other.pas';
      Arguments[2].Value := '//';
      Executor.Execute(Command);
    finally
      Command.Free;
    end;

    Capture.Text := '';
    Command := TScuCommand.Create('display_deck_list', nil);
    try
      Executor.Execute(Command);
    finally
      Command.Free;
    end;
    if (Capture.Text <> 'Deck name    Deck version' + LineEnding + 'example.pas  1.0-0.000' + LineEnding) or
      (Capture.Diagnostics <> 'Using library version 1.0.' + LineEnding) then
      raise Exception.Create('Unexpected executor output.');
    CheckLazyRevision(ParamStr(1));
    CheckUnloadedPayloadGuards;
    CheckLegacyNumberGuards;
    CheckTableDisplayWidths;
    CheckBackendLibraryNames(ParamStr(1));
  finally
    Executor.Free;
    Capture.Free;
  end;
end.
