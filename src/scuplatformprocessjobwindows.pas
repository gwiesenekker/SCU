unit ScuPlatformProcessJobWindows;
{$mode objfpc}{$H+}{$packrecords c}
interface
uses Windows;
type
  TProcessJob = class
  private
    FHandle: THandle;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Assign(Process: THandle);
    procedure TerminateAndWait;
    property Handle: THandle read FHandle;
  end;
function ProcessBelongsToJob(ProcessID: DWORD; Job: THandle): Boolean;
implementation
uses SysUtils, ScuErrors;
type
  TBasicLimit = record
    ProcessTime, JobTime: Int64;
    Flags: DWORD;
    MinimumWorkingSet, MaximumWorkingSet: PtrUInt;
    ActiveProcessLimit: DWORD;
    Affinity: PtrUInt;
    PriorityClass, SchedulingClass: DWORD;
  end;
  TExtendedLimit = record
    Basic: TBasicLimit;
    IO: array[0..5] of QWord;
    ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory: PtrUInt;
  end;
  TAccounting = record
    UserTime, KernelTime, PeriodUserTime, PeriodKernelTime: Int64;
    PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses: DWORD;
  end;
function NewJob(Attributes: PSecurityAttributes; Name: PWideChar): THandle; stdcall; external 'kernel32.dll' name 'CreateJobObjectW';
function AssignJob(Job, Process: THandle): BOOL; stdcall; external 'kernel32.dll' name 'AssignProcessToJobObject';
function SetJob(Job: THandle; Kind: Integer; Info: Pointer; Size: DWORD): BOOL; stdcall; external 'kernel32.dll' name 'SetInformationJobObject';
function QueryJob(Job: THandle; Kind: Integer; Info: Pointer; Size: DWORD; Returned: Pointer): BOOL; stdcall; external 'kernel32.dll' name 'QueryInformationJobObject';
function KillJob(Job: THandle; Code: UINT): BOOL; stdcall; external 'kernel32.dll' name 'TerminateJobObject';
function InJob(Process, Job: THandle; out Value: BOOL): BOOL; stdcall; external 'kernel32.dll' name 'IsProcessInJob';
constructor TProcessJob.Create;
var Limits: TExtendedLimit;
begin
  inherited Create;
  FHandle := NewJob(nil, nil);
  if FHandle = 0 then RaiseSystemError('Could not create child process job', GetLastError);
  FillChar(Limits, SizeOf(Limits), 0);
  Limits.Basic.Flags := $2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; no breakaway.
  if not SetJob(FHandle, 9, @Limits, SizeOf(Limits)) then
    RaiseSystemError('Could not configure child process job', GetLastError);
end;
procedure TProcessJob.Assign(Process: THandle);
begin
  if not AssignJob(FHandle, Process) then RaiseSystemError('Could not contain child process', GetLastError);
end;
procedure TProcessJob.TerminateAndWait;
var Accounting: TAccounting;
begin
  if not KillJob(FHandle, 1) then RaiseSystemError('Could not terminate child process tree', GetLastError);
  repeat
    if not QueryJob(FHandle, 1, @Accounting, SizeOf(Accounting), nil) then
      RaiseSystemError('Could not verify child process termination', GetLastError);
    if Accounting.ActiveProcesses = 0 then Exit;
    Sleep(10);
  until False;
end;
destructor TProcessJob.Destroy;
begin
  if FHandle <> 0 then CloseHandle(FHandle);
  inherited Destroy;
end;
function ProcessBelongsToJob(ProcessID: DWORD; Job: THandle): Boolean;
var Process: THandle; Member: BOOL;
begin
  Result := False;
  Process := OpenProcess(PROCESS_QUERY_INFORMATION, False, ProcessID);
  if Process = 0 then Exit;
  try
    Result := InJob(Process, Job, Member) and Member;
  finally CloseHandle(Process); end;
end;
end.
