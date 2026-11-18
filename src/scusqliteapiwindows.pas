unit ScuSQLiteAPIWindows;
{$mode objfpc}{$H+}
interface
uses CTypes;
type
  psqlite3 = Pointer;
  ppsqlite3 = ^psqlite3;
  psqlite3_stmt = Pointer;
  ppsqlite3_stmt = ^psqlite3_stmt;
  sqlite3_destructor_type = procedure(Context: Pointer); cdecl;
const
  SQLITE_OK = 0; SQLITE_ROW = 100; SQLITE_DONE = 101; SQLITE_NULL = 5;
  SQLITE_OPEN_READONLY = 1; SQLITE_OPEN_READWRITE = 2; SQLITE_OPEN_CREATE = 4;
  SQLITE_TRANSIENT = Pointer(-1);
procedure EnsureSQLiteLoaded;
var
  sqlite3_open_v2: function(Filename: PAnsiChar; Database: ppsqlite3; Flags: cint; VFS: PAnsiChar): cint; cdecl;
  sqlite3_close: function(Database: psqlite3): cint; cdecl;
  sqlite3_busy_timeout: function(Database: psqlite3; Milliseconds: cint): cint; cdecl;
  sqlite3_exec: function(Database: psqlite3; SQL: PAnsiChar; Callback: Pointer; Context: Pointer; Error: PPAnsiChar): cint; cdecl;
  sqlite3_changes: function(Database: psqlite3): cint; cdecl;
  sqlite3_errmsg: function(Database: psqlite3): PAnsiChar; cdecl;
  sqlite3_prepare_v2: function(Database: psqlite3; SQL: PAnsiChar; Size: cint; Statement: ppsqlite3_stmt; Tail: PPAnsiChar): cint; cdecl;
  sqlite3_finalize: function(Statement: psqlite3_stmt): cint; cdecl;
  sqlite3_bind_text: function(Statement: psqlite3_stmt; Index: cint; Value: PAnsiChar; Size: cint; DestroyValue: sqlite3_destructor_type): cint; cdecl;
  sqlite3_bind_int64: function(Statement: psqlite3_stmt; Index: cint; Value: Int64): cint; cdecl;
  sqlite3_bind_null: function(Statement: psqlite3_stmt; Index: cint): cint; cdecl;
  sqlite3_step: function(Statement: psqlite3_stmt): cint; cdecl;
  sqlite3_column_text: function(Statement: psqlite3_stmt; Index: cint): PAnsiChar; cdecl;
  sqlite3_column_bytes: function(Statement: psqlite3_stmt; Index: cint): cint; cdecl;
  sqlite3_column_int: function(Statement: psqlite3_stmt; Index: cint): cint; cdecl;
  sqlite3_column_int64: function(Statement: psqlite3_stmt; Index: cint): Int64; cdecl;
  sqlite3_column_type: function(Statement: psqlite3_stmt; Index: cint): cint; cdecl;
implementation
uses SysUtils, ScuWindowsDLL, ScuErrors;
type TIntegerFunction = function: cint; cdecl;
var Guard: TRTLCriticalSection; Ready: LongInt; Module: TWindowsDLL;
procedure EnsureSQLiteLoaded;
var Candidate: TWindowsDLL; Version, ThreadSafe: TIntegerFunction;
  Addresses: array[0..16] of Pointer;
begin
  if System.InterlockedCompareExchange(Ready, 0, 0) = 1 then Exit;
  EnterCriticalSection(Guard);
  try
    if Ready = 1 then Exit;
    Candidate := TWindowsDLL.Create('SQLite', ['sqlite3.dll']);
    try
      Pointer(Version) := Candidate.Require('sqlite3_libversion_number');
      Pointer(ThreadSafe) := Candidate.Require('sqlite3_threadsafe');
      if Version() < 3038000 then
        raise EScuError.Create('SQLite DLL "' + Candidate.Path + '" requires SQLite 3.38 or newer with JSON support.');
      if ThreadSafe() = 0 then
        raise EScuError.Create('SQLite DLL "' + Candidate.Path + '" was built without thread safety.');
      Addresses[0] := Candidate.Require('sqlite3_open_v2');
      Addresses[1] := Candidate.Require('sqlite3_close');
      Addresses[2] := Candidate.Require('sqlite3_busy_timeout');
      Addresses[3] := Candidate.Require('sqlite3_exec');
      Addresses[4] := Candidate.Require('sqlite3_changes');
      Addresses[5] := Candidate.Require('sqlite3_errmsg');
      Addresses[6] := Candidate.Require('sqlite3_prepare_v2');
      Addresses[7] := Candidate.Require('sqlite3_finalize');
      Addresses[8] := Candidate.Require('sqlite3_bind_text');
      Addresses[9] := Candidate.Require('sqlite3_bind_int64');
      Addresses[10] := Candidate.Require('sqlite3_bind_null');
      Addresses[11] := Candidate.Require('sqlite3_step');
      Addresses[12] := Candidate.Require('sqlite3_column_text');
      Addresses[13] := Candidate.Require('sqlite3_column_bytes');
      Addresses[14] := Candidate.Require('sqlite3_column_int');
      Addresses[15] := Candidate.Require('sqlite3_column_int64');
      Addresses[16] := Candidate.Require('sqlite3_column_type');
      Pointer(sqlite3_open_v2) := Addresses[0];
      Pointer(sqlite3_close) := Addresses[1];
      Pointer(sqlite3_busy_timeout) := Addresses[2];
      Pointer(sqlite3_exec) := Addresses[3];
      Pointer(sqlite3_changes) := Addresses[4];
      Pointer(sqlite3_errmsg) := Addresses[5];
      Pointer(sqlite3_prepare_v2) := Addresses[6];
      Pointer(sqlite3_finalize) := Addresses[7];
      Pointer(sqlite3_bind_text) := Addresses[8];
      Pointer(sqlite3_bind_int64) := Addresses[9];
      Pointer(sqlite3_bind_null) := Addresses[10];
      Pointer(sqlite3_step) := Addresses[11];
      Pointer(sqlite3_column_text) := Addresses[12];
      Pointer(sqlite3_column_bytes) := Addresses[13];
      Pointer(sqlite3_column_int) := Addresses[14];
      Pointer(sqlite3_column_int64) := Addresses[15];
      Pointer(sqlite3_column_type) := Addresses[16];
      Module := Candidate;
      Candidate := nil;
      System.InterlockedExchange(Ready, 1);
    finally Candidate.Free; end;
  finally LeaveCriticalSection(Guard); end;
end;
initialization
  InitCriticalSection(Guard);
// Successful DLLs remain loaded for the process lifetime: SQLite resources or
// other threads may still own callbacks during Pascal unit finalization.
finalization
  DoneCriticalSection(Guard);
end.
