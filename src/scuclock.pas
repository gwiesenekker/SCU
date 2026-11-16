unit ScuClock;

{$mode objfpc}{$H+}

interface

function UtcNow: TDateTime;
function UtcTimestamp(Value: TDateTime): string;

implementation

uses
  SysUtils, ScuPlatformClock;

function UtcNow: TDateTime;
begin
  Result := PlatformUtcNow;
end;

function UtcTimestamp(Value: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz"Z"', Value);
end;

end.
