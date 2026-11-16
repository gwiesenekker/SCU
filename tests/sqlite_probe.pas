program SQLiteProbe;
{$mode objfpc}{$H+}
uses SysUtils, ScuSQLiteDB, ScuSQLite, ScuPlatformPaths, ScuErrors
  {$IFDEF WINDOWS}, Windows{$ENDIF};
{$IFDEF WINDOWS}
type
  TWideArguments = array[0..65535] of PWideChar;
  PWideArguments = ^TWideArguments;
function WideArguments(CommandLine: PWideChar; out Count: Integer): PWideArguments;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
{$ENDIF}

function Argument(Index: Integer): string;
{$IFDEF WINDOWS}
var Arguments: PWideArguments; Count: Integer;
begin
  Arguments := WideArguments(GetCommandLineW, Count);
  if Arguments = nil then RaiseSystemError('Could not parse probe arguments', GetLastError);
  try
    if Index < Count then Result := UTF8Encode(UnicodeString(Arguments^[Index])) else Result := '';
  finally
    LocalFree(HLOCAL(Arguments));
  end;
end;
{$ELSE}
begin
  Result := ParamStr(Index);
end;
{$ENDIF}

type
  TProbe = class(TSQLiteConnection)
    constructor Open(const LibraryPath, Mode: string);
  end;
constructor TProbe.Open(const LibraryPath, Mode: string);
begin
  inherited Create;
  OpenConnection(LibraryPath, (Mode = 'read') or (Mode = 'forbidden'), Mode = 'create', True);
  if ReadOnly then Execute('PRAGMA query_only = ON');
end;
var DB: TProbe; LibraryDB: TSQLiteLibrary; Mode, Path: string;
begin
  InitializePlatformPaths;
  try
    Mode := Argument(1);
    Path := Argument(2);
    if Copy(Mode, 1, 7) = 'library' then
    begin
      if Mode = 'library-create' then LibraryDB := TSQLiteLibrary.OpenForInitialization(Path)
      else if Mode = 'library-read' then LibraryDB := TSQLiteLibrary.OpenRead(Path)
      else LibraryDB := TSQLiteLibrary.OpenWrite(Path);
      try
        if Mode = 'library-create' then
        begin
          LibraryDB.Revisions.SaveMetadata('{"header":{"current_version":"1.0"}}');
          LibraryDB.Audit.AppendAudit(1, 'saved-audit');
          LibraryDB.Commit;
        end
        else if Mode = 'library-read' then
        begin
          WriteLn(LibraryDB.Revisions.ReadCurrentVersion);
          WriteLn(LibraryDB.Scalar('SELECT line FROM audit_records'));
        end
        else
        begin
          LibraryDB.Execute('PRAGMA cache_size=2');
          LibraryDB.Revisions.SaveMetadata('{"header":{"current_version":"2.0"}}');
          LibraryDB.Audit.AppendAudit(2, 'uncommitted-audit');
          LibraryDB.Execute('CREATE TABLE spill(data BLOB)');
          LibraryDB.Execute('INSERT INTO spill VALUES(zeroblob(2000000))');
          Halt(23);
        end;
      finally
        LibraryDB.Free;
      end;
      Exit;
    end;
    DB := TProbe.Open(Path, Mode);
    try
      if Mode = 'create' then
      begin
        DB.Execute('CREATE TABLE state(value TEXT)');
        DB.Execute('INSERT INTO state VALUES(''saved'')');
      end
      else if Mode = 'crash' then
      begin
        DB.Execute('PRAGMA cache_size=2');
        DB.BeginTransaction;
        DB.Execute('UPDATE state SET value=''uncommitted''');
        DB.Execute('CREATE TABLE spill(data BLOB)');
        DB.Execute('INSERT INTO spill VALUES(zeroblob(2000000))');
        // Halt bypasses connection destruction, simulating process death with
        // dirty pages already spilled and an unsaved rollback journal.
        Halt(23);
      end
      else if Mode = 'write' then
      begin
        DB.BeginTransaction;
        DB.Execute('UPDATE state SET value=''changed''');
        if Argument(3) = 'commit' then DB.Commit;
      end
      else if Mode = 'forbidden' then DB.Execute('UPDATE state SET value=''bad''')
      else if Mode = 'read' then
      begin
        DB.BeginTransaction;
        WriteLn(DB.Scalar('SELECT value FROM state'));
        WriteLn(DB.Scalar('PRAGMA integrity_check'));
      end
      else raise Exception.Create('Unknown probe mode');
    finally
      DB.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(1);
    end;
  end;
end.
