unit ScuTable;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ScuOutput;

type
  // Human-readable tables use two spaces between padded columns.
  TColumnWidths = array of SizeInt;

  TScuTable = class
  private
    FRows: array of TStringArray;
    FWidths: TColumnWidths;
    FFlexibleColumn: SizeInt;
    function FitWidths(Columns: SizeInt): TColumnWidths;
    procedure WriteRow(Sink: TScuOutput; const Cells: TStringArray; const Widths: TColumnWidths);
    procedure WriteStacked(Sink: TScuOutput; Columns: SizeInt);
  public
    constructor Create(const Headers: array of string; FlexibleColumn: SizeInt = -1);
    procedure AddRow(const Cells: array of string);
    procedure AddDelimitedRow(const Row: string);
    procedure WriteTo(Sink: TScuOutput; Columns: SizeInt = 0);
  end;

implementation

uses
  ScuSignals, ScuTerminal;

constructor TScuTable.Create(const Headers: array of string; FlexibleColumn: SizeInt);
begin
  inherited Create;
  if (FlexibleColumn < -1) or (FlexibleColumn >= Length(Headers)) then
    raise EArgumentException.Create('Invalid flexible table column.');
  FFlexibleColumn := FlexibleColumn;
  UseTerminalLocale;
  SetLength(FWidths, Length(Headers));
  AddRow(Headers);
end;

procedure TScuTable.AddRow(const Cells: array of string);
var
  RowIndex, Column, Width: SizeInt;
begin
  if Length(Cells) <> Length(FWidths) then
    raise EArgumentException.Create('Table row does not match its headers.');
  RowIndex := Length(FRows);
  SetLength(FRows, RowIndex + 1);
  SetLength(FRows[RowIndex], Length(Cells));
  for Column := 0 to High(Cells) do
  begin
    FRows[RowIndex][Column] := Cells[Column];
    Width := TextWidth(Cells[Column], 0, Length(Cells[Column]));
    if Width > FWidths[Column] then
      FWidths[Column] := Width;
  end;
end;

procedure TScuTable.AddDelimitedRow(const Row: string);
begin
  AddRow(Row.Split([#9]));
end;

function TScuTable.FitWidths(Columns: SizeInt): TColumnWidths;
var
  Column, Excess, Minimum, Reduction: SizeInt;
begin
  Result := Copy(FWidths, 0, Length(FWidths));
  if Columns <= 0 then
    Exit;
  Excess := 2 * (Length(Result) - 1) - Columns;
  for Column := 0 to High(Result) do
    Inc(Excess, Result[Column]);
  if FFlexibleColumn >= 0 then
  begin
    Reduction := Result[FFlexibleColumn] - 1;
    if Reduction > Excess then
      Reduction := Excess;
    if Reduction > 0 then
      Dec(Result[FFlexibleColumn], Reduction);
    Exit;
  end;
  // Prefer wrapping the leading name/command column; preserve other cells
  // and headings while space allows, then wrap headings on narrow terminals.
  for Column := 0 to High(Result) do
  begin
    Minimum := TextWidth(FRows[0][Column], 0, Length(FRows[0][Column]));
    if Minimum < 1 then
      Minimum := 1;
    Reduction := Result[Column] - Minimum;
    if Reduction > Excess then
      Reduction := Excess;
    if Reduction > 0 then
    begin
      Dec(Result[Column], Reduction);
      Dec(Excess, Reduction);
    end;
  end;
  for Column := 0 to High(Result) do
  begin
    Reduction := Result[Column] - 1;
    if Reduction > Excess then
      Reduction := Excess;
    if Reduction > 0 then
    begin
      Dec(Result[Column], Reduction);
      Dec(Excess, Reduction);
    end;
  end;
end;

// Hard-wrap without dropping spaces or splitting a UTF-8 character.
function SplitCell(const Text: string; Width: SizeInt): TStringArray;
var
  Start, Ending, Next, Used, Cells: SizeInt;
begin
  Result := nil;
  Start := 0;
  repeat
    CheckSessionInterrupt;
    Ending := Start;
    Used := 0;
    while Ending < Length(Text) do
    begin
      Next := NextCharacter(Text, Ending);
      Cells := CellWidth(Text, Ending, Next);
      if (Width > 0) and (Used + Cells > Width) and (Ending > Start) then
        Break;
      Inc(Used, Cells);
      Ending := Next;
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Text, Start + 1, Ending - Start);
    Start := Ending;
  until Start >= Length(Text);
end;

procedure TScuTable.WriteRow(Sink: TScuOutput; const Cells: TStringArray; const Widths: TColumnWidths);
var
  Parts: array of TStringArray;
  Column, Height, Row: SizeInt;
  Line, Cell: string;
begin
  SetLength(Parts, Length(Cells));
  Height := 1;
  for Column := 0 to High(Cells) do
  begin
    Parts[Column] := SplitCell(Cells[Column], Widths[Column]);
    if Length(Parts[Column]) > Height then
      Height := Length(Parts[Column]);
  end;
  for Row := 0 to Height - 1 do
  begin
    CheckSessionInterrupt;
    Line := '';
    for Column := 0 to High(Cells) do
    begin
      Cell := '';
      if Row < Length(Parts[Column]) then
        Cell := Parts[Column][Row];
      Line := Line + Cell;
      if Column < High(Cells) then
        Line := Line + StringOfChar(' ', Widths[Column] - TextWidth(Cell, 0, Length(Cell)) + 2);
    end;
    Sink.WriteLine(Line);
  end;
end;

procedure TScuTable.WriteStacked(Sink: TScuOutput; Columns: SizeInt);
var
  Row, First, Column: SizeInt;
  Line, Part: string;
begin
  First := 1;
  if Length(FRows) = 1 then
    First := 0;
  for Row := First to High(FRows) do
  begin
    if Row > First then
      Sink.WriteLine('');
    for Column := 0 to High(FWidths) do
    begin
      Line := FRows[0][Column];
      if Row > 0 then
        Line := Line + ': ' + FRows[Row][Column];
      if (Row > 0) and (TextWidth(FRows[Row][Column], 0, Length(FRows[Row][Column])) <= Columns) and
        (TextWidth(Line, 0, Length(Line)) > Columns) then
      begin
        for Part in SplitCell(FRows[0][Column] + ':', Columns) do
          Sink.WriteLine(Part);
        Line := FRows[Row][Column];
      end;
      for Part in SplitCell(Line, Columns) do
      begin
        CheckSessionInterrupt;
        Sink.WriteLine(Part);
      end;
    end;
  end;
end;

procedure TScuTable.WriteTo(Sink: TScuOutput; Columns: SizeInt);
var
  Cells: TStringArray;
  Widths: TColumnWidths;
  MinimumWidth, Column: SizeInt;
begin
  if (Columns > 0) and (FFlexibleColumn >= 0) then
  begin
    MinimumWidth := 1 + 2 * (Length(FWidths) - 1);
    for Column := 0 to High(FWidths) do
      if Column <> FFlexibleColumn then
        Inc(MinimumWidth, FWidths[Column]);
    if Columns < MinimumWidth then
    begin
      WriteStacked(Sink, Columns);
      Exit;
    end;
  end;
  if (Columns > 0) and (Columns < Length(FWidths) + 2 * (Length(FWidths) - 1)) then
  begin
    WriteStacked(Sink, Columns);
    Exit;
  end;
  Widths := FitWidths(Columns);
  for Cells in FRows do
    WriteRow(Sink, Cells, Widths);
end;

end.
