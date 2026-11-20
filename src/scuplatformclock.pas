unit ScuPlatformClock;

{$mode objfpc}{$H+}

interface

// UTC wall clock; elapsed-time measurements must use a monotonic clock instead.
function PlatformUtcNow: TDateTime;

function PlatformLocalTime(UTC: TDateTime; out Local: TDateTime): Boolean;

implementation

uses
  {$IFDEF WINDOWS}ScuPlatformClockWindows{$ELSE}
  {$IFDEF LINUX}ScuPlatformClockLinux{$ELSE}
    {$FATAL No SCU clock backend for this platform}
  {$ENDIF}{$ENDIF};

function PlatformUtcNow: TDateTime;
begin
  Result := ReadUtcClock;
end;

function PlatformLocalTime(UTC: TDateTime; out Local: TDateTime): Boolean;
begin
  Result := ConvertUtcToLocal(UTC, Local);
end;

end.
