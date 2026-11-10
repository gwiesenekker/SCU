unit ScuClock;

{$mode objfpc}{$H+}

interface

function UtcNow: TDateTime;
function UtcTimestamp(Value: TDateTime): string;

implementation

uses
  SysUtils, BaseUnix, Unix, DateUtils, ScuErrors;

function UtcNow: TDateTime;
var
  Time: TTimeVal;
begin
  if fpGetTimeOfDay(@Time, nil) <> 0 then
    RaiseSystemError('Could not read the system clock', fpGetErrNo);
  Result := UnixToDateTime(Time.tv_sec) + Time.tv_usec / 86400000000.0;
end;

function UtcTimestamp(Value: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz"Z"', Value);
end;

end.
