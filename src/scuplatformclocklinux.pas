unit ScuPlatformClockLinux;

{$mode objfpc}{$H+}

interface

function ReadUtcClock: TDateTime;

implementation

uses BaseUnix, Unix, DateUtils, ScuErrors;

function ReadUtcClock: TDateTime;
var
  Time: TTimeVal;
begin
  if fpGetTimeOfDay(@Time, nil) <> 0 then
    RaiseSystemError('Could not read the system clock', fpGetErrNo);
  Result := UnixToDateTime(Time.tv_sec) + Time.tv_usec / 86400000000.0;
end;

end.
