program ExportNamesProbe;
{$mode objfpc}{$H+}
uses Classes, SysUtils, FPJSON, ScuExportNames, ScuExportManifest, ScuExportTypes,
  ScuPlatformPaths, ScuFiles, ScuCodec, ScuErrors
  {$IFDEF WINDOWS}, Windows, ScuPlatformPathsWindows{$ENDIF};
{$IFDEF WINDOWS}
function ShortPath(Path, Buffer: PWideChar; Size: DWORD): DWORD; stdcall;
  external 'kernel32.dll' name 'GetShortPathNameW';
{$ENDIF}
var Args: TStringList; Keys: TExportFileKeys; Results: TJSONArray;
  Manifest: TExportManifest; I: Integer; Name, Mode: string;
  {$IFDEF WINDOWS}Buffer: UnicodeString; Count: DWORD;{$ENDIF}
begin
  InitializePlatformPaths;
  Args := TStringList.Create;
  try
    try
      ReadInvocationArguments(Args); Mode := Args[0];
      if (Mode = 'validate') or (Mode = 'paths') or (Mode = 'targets') then
      begin
        Results := TJSONArray.Create;
        try
          for I := 1 to Args.Count - 1 do
          begin
            Name := DecodeBytesHex(Args[I], 'Probe value');
            try
              if Mode = 'paths' then ValidateExportPath(Name)
              else if Mode = 'targets' then CheckExportTarget(Name)
              else ValidateExportFileName(Name);
              Results.Add('ok');
            except on E: EScuError do Results.Add(E.Message); end;
          end;
          WriteLn(Results.AsJSON);
        finally Results.Free; end;
      end
      else if Mode = 'keys' then
      begin
        Results := TJSONArray.Create; Keys := TExportFileKeys.Create;
        try
          for I := 1 to Args.Count - 1 do
            Results.Add(Keys.Key(DecodeBytesHex(Args[I], 'Probe filename')));
          WriteLn(Results.AsJSON);
        finally Keys.Free; Results.Free; end;
      end
      else if Mode = 'manifest' then
      begin
        Manifest := TExportManifest.Create(Args[1]);
        try
          if Args[2] = 'recover' then Manifest.Recover;
          WriteLn(Manifest.Count);
        finally Manifest.Free; end;
      end
      else if Mode = 'plan' then
      begin
        Manifest := TExportManifest.Create(Args[1]);
        try
          for I := 3 to Args.Count - 1 do
            Manifest.PlanExport(Args[2], IncludeTrailingPathDelimiter(Args[1]) + Args[I],
              'main', '1.0', '1.0-0.000', emExtract, '', '', 'payload', True);
        finally Manifest.Free; end;
      end
      {$IFDEF WINDOWS}
      else if Mode = 'short' then
      begin
        SetLength(Buffer, 32768);
        Count := ShortPath(PWideChar(NativeFilePath(Args[1])), PWideChar(Buffer), Length(Buffer));
        if (Count = 0) or (Count >= DWORD(Length(Buffer))) then
          raise EScuError.Create('No short path available.');
        SetLength(Buffer, Count);
        WriteLn(UTF8Encode(Buffer));
      end
      {$ENDIF}
      else raise EScuError.Create('Unknown export-name probe mode');
    except on E: Exception do begin WriteLn(StdErr, E.Message); Halt(1); end; end;
  finally Args.Free; end;
end.
