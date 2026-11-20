unit ScuPlatformClockWindows;

{$mode objfpc}{$H+}

interface

function ReadUtcClock: TDateTime;

function ConvertUtcToLocal(UTC: TDateTime; out Local: TDateTime): Boolean;

implementation

uses Windows, DateUtils, SysUtils;

function ReadUtcClock: TDateTime;
const
  UnixEpochTicks = QWord(116444736000000000);
  TicksPerSecond = QWord(10000000);
var
  Time: TFileTime;
  Ticks: Int64;
begin
  GetSystemTimeAsFileTime(Time);
  // FILETIME is UTC, in 100 ns intervals since 1601. Split seconds and the
  // remainder before conversion to avoid losing precision on the epoch offset.
  Ticks := Int64((QWord(Time.dwHighDateTime) shl 32) or Time.dwLowDateTime) -
    Int64(UnixEpochTicks);
  Result := UnixToDateTime(Ticks div Int64(TicksPerSecond)) +
    (Ticks mod Int64(TicksPerSecond)) / 864000000000.0;
end;

function GetTimeZoneInformationForYear(Year: Word; Zone: Pointer;
  out Rules: TTimeZoneInformation): LongBool; stdcall; external 'kernel32';

function ConvertUtcToLocal(UTC: TDateTime; out Local: TDateTime): Boolean;
var
  UtcParts, LocalParts: TSystemTime;
  Rules: TTimeZoneInformation;
begin
  DateTimeToSystemTime(UTC, UtcParts);
  Result := GetTimeZoneInformationForYear(UtcParts.Year, nil, Rules) and
    SystemTimeToTzSpecificLocalTime(@Rules, UtcParts, LocalParts);
  if Result then Local := SystemTimeToDateTime(LocalParts);
end;

end.
