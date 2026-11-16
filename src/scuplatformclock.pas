unit ScuPlatformClock;

{$mode objfpc}{$H+}

interface

// UTC wall clock; elapsed-time measurements must use a monotonic clock instead.
function PlatformUtcNow: TDateTime;

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

end.
