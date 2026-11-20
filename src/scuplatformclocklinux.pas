unit ScuPlatformClockLinux;

{$mode objfpc}{$H+}

interface

function ReadUtcClock: TDateTime;

function ConvertUtcToLocal(UTC: TDateTime; out Local: TDateTime): Boolean;

implementation

uses CTypes, BaseUnix, Unix, DateUtils, ScuErrors;

function ReadUtcClock: TDateTime;
var
  Time: TTimeVal;
begin
  if fpGetTimeOfDay(@Time, nil) <> 0 then
    RaiseSystemError('Could not read the system clock', fpGetErrNo);
  Result := UnixToDateTime(Time.tv_sec) + Time.tv_usec / 86400000000.0;
end;

{$packrecords c}
type
  TLocalTime = record
    Second, Minute, Hour, Day, Month, Year, WeekDay, YearDay, IsDST: cint;
    Offset: clong;
    Zone: PChar;
  end;

function localtime_r(constref Seconds: time_t; out Parts: TLocalTime): Pointer;
  cdecl; external 'c';

function ConvertUtcToLocal(UTC: TDateTime; out Local: TDateTime): Boolean;
var
  Seconds: time_t;
  Parts: TLocalTime;
begin
  Seconds := DateTimeToUnix(UTC);
  Result := localtime_r(Seconds, Parts) <> nil;
  if Result then Local := IncSecond(UTC, Parts.Offset);
end;

end.
