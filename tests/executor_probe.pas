program ExecutorProbe;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, ScuCommand, ScuErrors, ScuExecutor, ScuLibraryModel, ScuLibraryStore, ScuOutput, ScuSQLite;

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

var
  Capture: TCapturedOutput;
  Executor: TScuExecutor;
  Command: TScuCommand;
  Arguments: TScuArguments;
  Options: TStringList;

begin
  Capture := TCapturedOutput.Create;
  Executor := TScuExecutor.Create(ParamStr(1), False, Capture);
  Options := TStringList.Create;
  try
    Command := TScuCommand.Create('unregistered_command', nil, nil);
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

    Command := TScuCommand.Create('initialize_library', nil, nil);
    try
      Executor.Execute(Command);
    finally
      Command.Free;
    end;

    SetLength(Arguments, 2);
    Arguments[0].Name := 'deck_name';
    Arguments[0].Value := 'example.pas';
    Arguments[0].Provided := True;
    Arguments[1].Name := 'from_file';
    Options.Add('comment-prefix=#');
    Command := TScuCommand.Create('create_deck', Arguments, Options);
    try
      Arguments[0].Value := 'other.pas';
      Options.Values['comment-prefix'] := '//';
      Executor.Execute(Command);
    finally
      Command.Free;
    end;

    Capture.Text := '';
    Command := TScuCommand.Create('display_deck_list', nil, nil);
    try
      Executor.Execute(Command);
    finally
      Command.Free;
    end;
    if (Capture.Text <> 'example.pas'#9'1.0-0.000' + LineEnding) or
      (Capture.Diagnostics <> 'Using version 1.0, library revision 1.' + LineEnding) then
      raise Exception.Create('Unexpected executor output.');
    CheckLazyRevision(ParamStr(1));
    CheckUnloadedPayloadGuards;
  finally
    Options.Free;
    Executor.Free;
    Capture.Free;
  end;
end.
