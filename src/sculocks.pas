unit ScuLocks;

{$mode objfpc}{$H+}

interface

uses ScuLockTypes,
  {$IFDEF WINDOWS}ScuPlatformLocksWindows{$ELSE}
  {$IFDEF LINUX}ScuPlatformLocksLinux{$ELSE}
    {$FATAL No SCU lock backend for this platform}
  {$ENDIF}{$ENDIF};

type
  TStopLockWait = ScuLockTypes.TStopLockWait;
  TCheckLockInterrupt = ScuLockTypes.TCheckLockInterrupt;
  TFileLock = TPlatformFileLock;

implementation

end.
