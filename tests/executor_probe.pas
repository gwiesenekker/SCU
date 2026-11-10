program ExecutorProbe;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, ScuCommand, ScuExecutor, ScuLibraryModel, ScuLibraryStore, ScuOutput, ScuSQLite;

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

procedure CheckLazyRevision(const Path: string);
var
  Database: TSQLiteLibrary;
  Store: TLibraryStore;
  Entry: TLibraryRevision;
begin
  Database := TSQLiteLibrary.OpenRead(Path);
  try
    Store := TLibraryStore.Create(Path, '', Database);
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
  finally
    Options.Free;
    Executor.Free;
    Capture.Free;
  end;
end.
