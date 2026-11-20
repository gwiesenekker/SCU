unit ScuClock;

{$mode objfpc}{$H+}

interface

function UtcNow: TDateTime;
function UtcTimestamp(Value: TDateTime): string;

function LocalTimestamp(const StoredUTC: string): string;

implementation

uses
  SysUtils, DateUtils, ScuPlatformClock;

function UtcNow: TDateTime;
begin
  Result := PlatformUtcNow;
end;

function UtcTimestamp(Value: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz"Z"', Value);
end;

function LocalTimestamp(const StoredUTC: string): string;
var
  UTC, Local: TDateTime;
  Offset: Integer;
  Sign: Char;
begin
  Result := StoredUTC;
  if not TryISO8601ToDate(StoredUTC, UTC) then Exit;
  if not PlatformLocalTime(UTC, Local) then Exit;
  Offset := Round((Local - UTC) * MinsPerDay);
  if Offset < 0 then Sign := '-' else Sign := '+';
  Offset := Abs(Offset);
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz', Local) +
    Format('%s%.2d:%.2d', [Sign, Offset div 60, Offset mod 60]);
end;

end.
