unit ScuLibraryPortability;
{$mode objfpc}{$H+}

interface
uses ScuCommandHandler;

procedure ReportPlatformWarnings(const Context: TCommandContext; const Origin: string);

implementation

uses Classes, SysUtils, FPJSON, Character, UnicodeData, ScuErrors, ScuLibrary, ScuLibraryHeader,
  ScuWindowsFileNames, ScuSignals{$IFDEF WINDOWS}, ScuPlatformScanWindows{$ENDIF};

function CompareWindowsSpelling(List: TStringList; Left, Right: Integer): Integer;
begin
  {$IFDEF WINDOWS}
  Result := CompareFileNames(List[Left], List[Right]);
  {$ELSE}
  Result := CompareStr(UTF8Encode(TCharacter.ToUpper(UTF8Decode(List[Left]))),
                       UTF8Encode(TCharacter.ToUpper(UTF8Decode(List[Right]))));
  {$ENDIF}
end;

function MacSpellingKey(const Name: string): string;
begin
  Result := UTF8Encode(NormalizeNFD(TCharacter.ToUpper(NormalizeNFD(UTF8Decode(Name)))));
end;

function CompareMacSpelling(List: TStringList; Left, Right: Integer): Integer;
begin
  Result := CompareStr(MacSpellingKey(List[Left]), MacSpellingKey(List[Right]));
end;

procedure ReportPlatformWarnings(const Context: TCommandContext; const Origin: string);
var
  Entries: TDeckListEntries;
  Files: TStringList;
  Index: Integer;
  Path: string;
  CheckWindows: Boolean;

  procedure Warn(const Deck, FileName, MessageText: string);
  begin
    Context.Output.WriteLine(Format('Warning (%s to %s): deck "%s", file "%s": %s',
      [Origin, HostPlatform, Deck, StringToJSONString(FileName), MessageText]));
  end;

  procedure ReportGroups(Compare: TStringListSortCompare; const Reason: string);
  var First, Last, Member: Integer;
  begin
    Files.CustomSort(Compare);
    First := 0;
    while First < Files.Count do
    begin
      CheckSessionInterrupt;
      Last := First + 1;
      while (Last < Files.Count) and (Compare(Files, First, Last) = 0) do Inc(Last);
      if Last - First > 1 then
        for Member := First to Last - 1 do
          Warn(Entries[PtrInt(Files.Objects[Member])].Name, Files[Member], Reason);
      First := Last;
    end;
  end;

begin
  if (Origin = HostPlatform) or (Origin = 'unknown') then Exit;
  CheckWindows := (Origin = 'Windows') or (HostPlatform = 'Windows');
  Entries := Context.LibraryFile.DeckList(Context.LibraryFile.Revision);
  Files := TStringList.Create;
  try
    for Index := 0 to High(Entries) do
    begin
      CheckSessionInterrupt;
      Path := Context.LibraryFile.StoredSourcePath(Context.Database, Entries[Index].Sequence);
      if CheckWindows then
        try
          ValidateWindowsFileName(Path, 'export');
        except
          on E: EScuError do
          begin
            Warn(Entries[Index].Name, Path, E.Message);
            // Also consider this name when checking a macOS volume.
            if (Origin <> 'macOS') and (HostPlatform <> 'macOS') then Continue;
          end;
        end;
      Files.AddObject(Path, TObject(PtrInt(Index)));
    end;
    if CheckWindows then
      ReportGroups(@CompareWindowsSpelling, 'these spellings resolve to the same Windows output.');
    if (Origin = 'macOS') or (HostPlatform = 'macOS') then
      ReportGroups(@CompareMacSpelling, 'these spellings may resolve to the same output on macOS.');
  finally
    Files.Free;
  end;
end;

end.
