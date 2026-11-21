unit ScuLibraryDisplay;

{$mode objfpc}{$H+}

interface

uses
  FPJSON, ScuExportTypes, ScuLibrary, ScuOutput;

type
  TVersionHistoryDisplayRow = record
    Version, Status, LockedUTC, Description: string;
  end;
  TVersionHistoryDisplayRows = array of TVersionHistoryDisplayRow;

// Configuration is borrowed; rendering never changes the library header.
procedure WriteLibraryConfiguration(Configuration: TJSONObject; Sink: TScuOutput; Columns: SizeInt);
procedure WriteVersionHistoryRows(const Rows: TVersionHistoryDisplayRows; Sink: TScuOutput; Full: Boolean);
procedure WriteExportResults(const Rows: TExportResults; Mode: TExportMode; Sink: TScuOutput);
procedure WriteDeckList(const Rows: TDeckListEntries; Sink: TScuOutput);
procedure WriteVersionDecks(const Rows: TVersionDeckEntries; Sink: TScuOutput);
procedure WriteDeckHistory(const Rows: TDeckHistoryEntries; Sink: TScuOutput);

implementation

uses
  SysUtils, ScuClock, ScuSignals, ScuTable, ScuTerminal;

function DisplayText(const Text: string; KeepLineBreaks: Boolean = False): string;
var
  Character: Char;
begin
  Result := '';
  for Character in Text do
    case Character of
      #9: Result := Result + '\t';
      #10: if KeepLineBreaks then Result := Result + #10 else Result := Result + '\n';
      #13: Result := Result + '\r';
      #0..#8, #11, #12, #14..#31, #127:
        Result := Result + '\x' + IntToHex(Ord(Character), 2);
      else Result := Result + Character;
    end;
end;

function DisplayValue(Value: TJSONData): string;
begin
  if Value.JSONType = jtString then
  begin
    if Value.AsString = '' then
      Exit('(not set)');
    Exit(DisplayText(Value.AsString));
  end;
  if (Value.JSONType = jtArray) and (Value.Count = 0) then
    Exit('(not set)');
  Result := DisplayText(Value.AsJSON);
end;

procedure WriteLibraryConfiguration(Configuration: TJSONObject; Sink: TScuOutput; Columns: SizeInt);
var
  Index, Width, Indent, NameWidth: SizeInt;
  Name, Rendered: string;
  Stacked: Boolean;

  function WidthOf(const Text: string): SizeInt;
  begin
    if Columns = 0 then
      Exit(Length(Text));
    Result := TextWidth(Text, 0, Length(Text));
  end;

  procedure WriteRow(const Name, Value: string);
  begin
    if Stacked then
    begin
      Sink.WriteLine(FormatTerminalLines(Name, Columns));
      Sink.WriteLine(FormatTerminalLines(Value, Columns, Indent));
    end
    else
    begin
      Rendered := FormatTerminalLines(Value, Columns, Indent);
      Sink.WriteLine(Name + StringOfChar(' ', Indent - WidthOf(Name)) +
        Copy(Rendered, Indent + 1, MaxInt));
    end;
  end;

begin
  if Columns > 0 then
    UseTerminalLocale;
  Width := Length('Attribute');
  for Index := 0 to Configuration.Count - 1 do
  begin
    NameWidth := WidthOf(DisplayText(Configuration.Names[Index]));
    if NameWidth > Width then
      Width := NameWidth;
  end;
  Indent := Width + 2;
  Stacked := (Columns > 0) and (Columns - Indent < 12);
  if Stacked then
  begin
    Indent := 2;
    if Columns < 3 then
      Indent := Columns - 1;
  end
  else
    WriteRow('Attribute', 'Value');
  for Index := 0 to Configuration.Count - 1 do
  begin
    CheckSessionInterrupt;
    Name := DisplayText(Configuration.Names[Index]);
    if (Configuration.Names[Index] = 'version_tracker_template') and
      (Configuration.Items[Index].JSONType = jtString) and
      (Configuration.Items[Index].AsString <> '') then
    begin
      Sink.WriteLine(FormatTerminalLines(Name, Columns));
      Sink.WriteLine(FormatTerminalLines(DisplayText(
        AdjustLineBreaks(Configuration.Items[Index].AsString, tlbsLF), True), Columns));
    end
    else
      WriteRow(Name, DisplayValue(Configuration.Items[Index]));
  end;
end;

procedure WriteVersionHistoryRows(const Rows: TVersionHistoryDisplayRows; Sink: TScuOutput; Full: Boolean);
var
  Table: TScuTable;
  Row: TVersionHistoryDisplayRow;
begin
  if Full then Table := TScuTable.Create(['Version', 'Status', 'Locked (local TZ)'])
  else Table := TScuTable.Create(['Version', 'Status', 'Locked (local TZ)', 'Description'], 3);
  try
    for Row in Rows do
    begin
      CheckSessionInterrupt;
      if Full then
        Table.AddRow([Row.Version, Row.Status, LocalTimestamp(Row.LockedUTC)],
          DisplayText(AdjustLineBreaks(Row.Description, tlbsLF), True))
      else Table.AddRow([Row.Version, Row.Status, LocalTimestamp(Row.LockedUTC), Row.Description]);
    end;
    Table.WriteTo(Sink, Sink.Columns);
  finally
    Table.Free;
  end;
end;

procedure WriteExportResults(const Rows: TExportResults; Mode: TExportMode; Sink: TScuOutput);
const
  StatusText: array[TExportStatus] of string = ('Created', 'Replaced', 'Unchanged');
var
  Table: TScuTable;
  Row: TExportResult;
  Status: string;
begin
  Table := TScuTable.Create(['Deck name', 'Deck version', 'Status']);
  try
    for Row in Rows do
    begin
      CheckSessionInterrupt;
      if Row.TrackerFile <> '' then Continue;
      Status := StatusText[Row.Status];
      if (Mode = emExtract) and (Row.Status = esUnchanged) then Status := 'Matches';
      Table.AddRow([DisplayText(Row.Deck), Row.DeckVersion, Status]);
    end;
    Table.WriteTo(Sink, Sink.Columns);
  finally
    Table.Free;
  end;
end;

procedure WriteDeckList(const Rows: TDeckListEntries; Sink: TScuOutput);
var
  Table: TScuTable;
  Row: TDeckListEntry;
begin
  Table := TScuTable.Create(['Deck name', 'Deck version']);
  try
    for Row in Rows do
    begin
      CheckSessionInterrupt;
      Table.AddRow([DisplayText(Row.Name), Row.DeckVersion]);
    end;
    Table.WriteTo(Sink, Sink.Columns);
  finally
    Table.Free;
  end;
end;

procedure WriteVersionDecks(const Rows: TVersionDeckEntries; Sink: TScuOutput);
var
  Table: TScuTable;
  Row: TVersionDeckEntry;
  Status: string;
begin
  Table := TScuTable.Create(['Deck name', 'Deck version', 'Modified (local TZ)', 'Status']);
  try
    for Row in Rows do
    begin
      CheckSessionInterrupt;
      Status := 'stored';
      if Row.Deleted then
        Status := 'deleted';
      Table.AddRow([DisplayText(Row.Name), Row.DeckVersion, LocalTimestamp(Row.ModifiedUTC), Status]);
    end;
    Table.WriteTo(Sink, Sink.Columns);
  finally
    Table.Free;
  end;
end;

procedure WriteDeckHistory(const Rows: TDeckHistoryEntries; Sink: TScuOutput);
var
  Table: TScuTable;
  Row: TDeckHistoryEntry;
  Status: string;
begin
  Table := TScuTable.Create(['Deck version', 'Modified (local TZ)', 'Status']);
  try
    for Row in Rows do
    begin
      CheckSessionInterrupt;
      Status := 'stored';
      if Row.Deleted then
        Status := 'deleted';
      Table.AddRow([Row.DeckVersion, LocalTimestamp(Row.ModifiedUTC), Status]);
    end;
    Table.WriteTo(Sink, Sink.Columns);
  finally
    Table.Free;
  end;
end;

end.
