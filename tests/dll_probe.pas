program DLLProbe;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} Classes, SysUtils, SyncObjs,
  ScuCodec, ScuSQLiteDB, ScuFiles, ScuPlatformPaths, ScuErrors;
type
  TProbeDB = class(TSQLiteConnection)
    constructor Open(const PathName: string);
  end;
  TWorker = class(TThread)
  private FDirectory: string; FNumber: Integer; FStart: TEvent;
  protected procedure Execute; override;
  public
    Failure: string;
    constructor Create(const Directory: string; Number: Integer; StartSignal: TEvent);
  end;
constructor TProbeDB.Open(const PathName: string);
begin
  inherited Create;
  OpenConnection(PathName, False, True);
end;
procedure CheckSQLite(const Path: string);
var DB: TProbeDB; Statement: TSQLiteStatement;
begin
  DB := TProbeDB.Open(Path);
  try
    DB.Execute('CREATE TABLE IF NOT EXISTS test(value TEXT)');
    DB.BeginTransaction;
    Statement := DB.Prepare('INSERT INTO test VALUES(?)');
    try Statement.Bind(1, 'payload'); Statement.Step;
    finally Statement.Free; end;
    DB.Commit;
    if DB.Scalar('SELECT value FROM test LIMIT 1') <> 'payload' then
      raise EScuError.Create('SQLite payload mismatch');
  finally DB.Free; end;
end;
procedure Exercise(const Component, Path: string);
var Data, Encoded: RawByteString;
begin
  if Component = 'sqlite' then CheckSQLite(Path)
  else if Component = 'zstd' then
  begin
    Encoded := EncodeDeck('abc');
    if Encoded = '' then raise EScuError.Create('No zstd frame');
  end
  else if Component = 'crypto' then
  begin
    if DeckSHA1('abc') <> 'a9993e364706816aba3e25717850c26c9cd0d89d' then
      raise EScuError.Create('SHA-1 mismatch');
    if AuditSHA256('abc') <> 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' then
      raise EScuError.Create('SHA-256 mismatch');
  end
  else
  begin
    Data := ReadBytes(Path, MaxDeckSize);
    Encoded := EncodeDeck(Data);
    if DecodeDeck(Encoded, DeckSHA1(Data), Length(Data)) <> Data then
      raise EScuError.Create('Codec round-trip mismatch');
    WriteLn(DeckSHA1(Data)); WriteLn(AuditSHA256(Data));
  end;
end;
constructor TWorker.Create(const Directory: string; Number: Integer; StartSignal: TEvent);
begin
  inherited Create(True);
  FDirectory := Directory; FNumber := Number; FStart := StartSignal;
end;
procedure TWorker.Execute;
var Data, Encoded: RawByteString; I: Integer;
begin
  try
    FStart.WaitFor(INFINITE);
    for I := 1 to 30 do
    begin
      Exercise('crypto', '');
      Data := 'worker ' + IntToStr(FNumber) + #0 + StringOfChar('x', 2048);
      Encoded := EncodeDeck(Data);
      if DecodeDeck(Encoded, DeckSHA1(Data), Length(Data)) <> Data then
        raise EScuError.Create('Concurrent codec mismatch');
      if I = 1 then CheckSQLite(IncludeTrailingPathDelimiter(FDirectory) + IntToStr(FNumber) + '.sqlite');
    end;
  except on E: Exception do Failure := E.Message; end;
end;
var Args: TStringList; Mode, Component, Target: string; Data: RawByteString;
  Start: TEvent; Workers: array[0..7] of TWorker; I: Integer;
begin
  InitializePlatformPaths;
  Args := TStringList.Create;
  try
    try
      ReadInvocationArguments(Args); Mode := Args[0];
      if Mode = 'noop' then WriteLn('ready')
      else if Mode = 'threads' then
      begin
        Start := TEvent.Create(nil, True, False, '');
        try
          for I := 0 to High(Workers) do begin Workers[I] := TWorker.Create(Args[1], I, Start); Workers[I].Start; end;
          Start.SetEvent;
          for I := 0 to High(Workers) do Workers[I].WaitFor;
          for I := 0 to High(Workers) do
            if Workers[I].Failure <> '' then raise EScuError.Create(Workers[I].Failure);
          WriteLn('threads ok');
        finally
          for I := 0 to High(Workers) do Workers[I].Free;
          Start.Free;
        end;
      end
      else if Mode = 'retry' then
      begin
        Component := Args[1];
        try Exercise(Component, Args[4]);
        except on E: EScuError do WriteLn('first failure: ', E.Message); end;
        Target := IncludeTrailingPathDelimiter(ExtractFileDir(RunningExecutablePath)) + Args[2];
        AtomicWrite(Target, ReadBytes(Args[3], 64 * 1024 * 1024));
        Exercise(Component, Args[4]); WriteLn('retry ok');
      end
      else if Mode = 'sha' then
      begin
        Data := ReadBytes(Args[1], MaxDeckSize);
        WriteLn(DeckSHA1(Data)); WriteLn(AuditSHA256(Data));
      end
      else if Mode = 'encode' then WriteLn(EncodeDeck(ReadBytes(Args[1], MaxDeckSize)))
      else if Mode = 'decode' then
        WriteLn(DecodeDeck(Args[1], Args[2], StrToInt64(Args[3])))
      else if Mode = 'sqlite' then begin CheckSQLite(Args[1]); WriteLn('sqlite ok'); end
      else if Mode = 'zstd' then begin Exercise('zstd', ''); WriteLn('zstd ok'); end
      else if Mode = 'crypto' then begin Exercise('crypto', ''); WriteLn('crypto ok'); end
      else Exercise('roundtrip', Args[1]);
    except
      on E: Exception do begin WriteLn(StdErr, E.Message); Halt(1); end;
    end;
  finally Args.Free; end;
end.
