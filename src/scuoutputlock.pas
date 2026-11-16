unit ScuOutputLock;

{$mode objfpc}{$H+}

interface

uses ScuLockTypes,
  {$IFDEF WINDOWS}ScuPlatformOutputLockWindows{$ELSE}
  {$IFDEF LINUX}ScuPlatformOutputLockLinux{$ELSE}
    {$FATAL No SCU output lock backend for this platform}
  {$ENDIF}{$ENDIF};

const
  BuildOutputLockVariable = ScuLockTypes.BuildOutputLockVariable;

type
  TOutputDirectoryLock = TPlatformOutputDirectoryLock;

implementation

end.
