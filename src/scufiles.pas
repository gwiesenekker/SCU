unit ScuFiles;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TAtomicWriteOptions = set of (awNoReplace, awSourceOutput);
  TReadBytesOptions = set of (rbNoFollow);

function CanonicalFile(const Path: string): string;
function CanonicalDirectory(const Path: string): string;
function RegularFileExists(const Path: string): Boolean;
function IsSQLiteFile(const Path: string): Boolean;
function IsSQLiteCompanion(const Path: string): Boolean;
procedure CleanupStaleAtomicFiles(const Directory: string);
function ReadBytes(const Path: string; Limit: Int64; Options: TReadBytesOptions = []): RawByteString;
procedure AtomicWrite(const Path: string; const Data: RawByteString; Options: TAtomicWriteOptions = []); overload;
procedure AtomicWrite(const Path: string; Data: TStream; Options: TAtomicWriteOptions = []); overload;
function MakeTempDirectory(const Prefix: string): string;
function MakeStagingDirectory(const Directory: string): string;
procedure SyncFile(Handle: THandle; const Path: string);
procedure SyncParent(const Path: string);

implementation

uses
  BaseUnix, Unix, InitC, Linux, ScuErrors;

function realpath(Path, Resolved: PChar): PChar; cdecl; external 'c';
function mkstemp(Template: PChar): LongInt; cdecl; external 'c';
function mkdtemp(Template: PChar): PChar; cdecl; external 'c';
function fchmod(Handle: cint; Mode: mode_t): cint; cdecl; external 'c';
function fchown(Handle: cint; Owner: uid_t; Group: gid_t): cint; cdecl; external 'c';

function MakeTempDirectory(const Prefix: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ExpandFileName(GetTempDir(False))) + Prefix + '-XXXXXX';
  UniqueString(Result);
  if mkdtemp(PChar(Result)) = nil then
    RaiseSystemError('Could not create temporary directory "' + Result + '"', cerrno);
end;

function MakeStagingDirectory(const Directory: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Directory) + '.scu-stage-' + IntToStr(fpGetPid) + '-XXXXXX';
  UniqueString(Result);
  if mkdtemp(PChar(Result)) = nil then
    RaiseSystemError('Could not create export staging directory in "' + Directory + '"', cerrno);
end;

function CanonicalFile(const Path: string): string;
var
  FullPath, Parent: string;
begin
  if (Path = '') or (Path[Length(Path)] = DirectorySeparator) then
    raise EScuError.Create('Expected a file path.');
  FullPath := ExpandFileName(Path);
  Parent := ExtractFileDir(FullPath);
  Result := IncludeTrailingPathDelimiter(CanonicalDirectory(Parent)) + ExtractFileName(FullPath);
end;

function CanonicalDirectory(const Path: string): string;
var
  Resolved: array[0..4095] of Char;
begin
  if realpath(PChar(Path), @Resolved[0]) = nil then
    raise EScuError.CreateFmt('Could not resolve directory %s: %s', [Path, SysErrorMessage(cerrno)]);
  Result := StrPas(@Resolved[0]);
end;

function RegularFileExists(const Path: string): Boolean;
var
  Info: Stat;
  Error: cint;
begin
  if fpLStat(Path, Info) = 0 then
  begin
    if not FPS_ISREG(Info.st_mode) then
      raise EScuError.CreateFmt('Expected a regular file: %s', [Path]);
    Exit(True);
  end;
  Error := fpGetErrNo;
  if Error <> ESysENOENT then
    RaiseSystemError('Could not inspect "' + Path + '"', Error);
  Result := False;
end;

function ReadBytes(const Path: string; Limit: Int64; Options: TReadBytesOptions): RawByteString;
var
  Handle: THandle;
  Stream: THandleStream;
  Info: Stat;
  Flags: Integer;
begin
  Flags := O_RDONLY or O_NONBLOCK;
  if rbNoFollow in Options then
    Flags := Flags or O_NOFOLLOW;
  Handle := fpOpen(Path, Flags);
  if Handle < 0 then
  begin
    if (rbNoFollow in Options) and (fpGetErrNo = ESysELOOP) then
      raise EScuError.Create('Refusing to read a symbolic link: "' + Path + '".');
    raise EScuError.CreateFmt('Could not open %s: %s', [Path, SysErrorMessage(fpGetErrNo)]);
  end;
  try
    if fpFStat(Handle, Info) <> 0 then
      RaiseSystemError('Could not inspect opened file "' + Path + '"', fpGetErrNo);
    if not FPS_ISREG(Info.st_mode) then
      raise EScuError.CreateFmt('Expected a regular file: %s', [Path]);
    if (Info.st_size < 0) or (Info.st_size > Limit) then
      raise EScuError.CreateFmt('File exceeds the %d-byte limit: %s', [Limit, Path]);
    SetLength(Result, Info.st_size);
    if Result <> '' then
    begin
      Stream := THandleStream.Create(Handle);
      try
        try
          Stream.ReadBuffer(Result[1], Length(Result));
        except
          on E: EStreamError do
            raise EScuError.CreateFmt('Could not read "%s": %s', [Path, E.Message]);
        end;
      finally
        Stream.Free;
      end;
    end;
  finally
    fpClose(Handle);
  end;
end;

function IsSQLiteFile(const Path: string): Boolean;
var
  Handle: cint;
  Magic: array[0..15] of AnsiChar;
const Header: array[0..15] of AnsiChar = 'SQLite format 3'#0;
begin
  Result := False;
  Handle := fpOpen(Path, O_RDONLY or O_NONBLOCK or O_NOFOLLOW);
  if Handle < 0 then Exit;
  try
    if fpRead(Handle, Magic, SizeOf(Magic)) = SizeOf(Magic) then
      Result := CompareByte(Magic, Header, 16) = 0;
  finally
    fpClose(Handle);
  end;
end;

function IsSQLiteCompanion(const Path: string): Boolean;
const Suffixes: array[0..3] of string = ('.lock', '-journal', '-wal', '-shm');
var Suffix: string;
begin
  for Suffix in Suffixes do
    if (Copy(Path, Length(Path) - Length(Suffix) + 1, MaxInt) = Suffix) and
      IsSQLiteFile(Copy(Path, 1, Length(Path) - Length(Suffix))) then Exit(True);
  Result := False;
end;

procedure RemoveStaleStages(const Directory: string);
var
  Search, Child: TSearchRec;
  Tail, Path, Item: string;
  Dash, Pid, Number, OwnerHandle: Integer;
  Info: Stat;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Directory) + '.scu-stage-*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      Tail := Copy(Search.Name, 12, MaxInt);
      Dash := Pos('-', Tail);
      if (Dash < 2) or (Length(Tail) - Dash <> 6) or
        not TryStrToInt(Copy(Tail, 1, Dash - 1), Pid) or (Pid <= 0) then Continue;
      Path := IncludeTrailingPathDelimiter(Directory) + Search.Name;
      if (fpLStat(Path, Info) <> 0) or not FPS_ISDIR(Info.st_mode) or (Info.st_uid <> fpGetEUid) then Continue;
      // File locks identify a live owner across PID namespaces and shared hosts.
      // Old stages without this marker are left for explicit manual cleanup.
      OwnerHandle := fpOpen(Path + '/.owner', O_RDONLY or O_NOFOLLOW or O_CLOEXEC or O_NONBLOCK);
      if OwnerHandle < 0 then Continue;
      try
        if (fpFStat(OwnerHandle, Info) <> 0) or not FPS_ISREG(Info.st_mode) or
          (Info.st_uid <> fpGetEUid) or (fpFlock(OwnerHandle, LOCK_EX or LOCK_NB) <> 0) then Continue;
        if FindFirst(Path + '/*', faAnyFile, Child) = 0 then
        try
          repeat
            if not TryStrToInt(Child.Name, Number) or (Number <= 0) then Continue;
            Item := Path + '/' + Child.Name;
            if (fpLStat(Item, Info) = 0) and FPS_ISREG(Info.st_mode) and (Info.st_uid = fpGetEUid) then
              fpUnlink(Item);
          until FindNext(Child) <> 0;
        finally
          FindClose(Child);
        end;
        // Refuse to recurse into directories or follow links, even inside a stale stage.
        fpUnlink(Path + '/.owner');
        if RemoveDir(Path) then SyncParent(Path);
      finally
        fpClose(OwnerHandle);
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure CleanupStaleAtomicFiles(const Directory: string);
var
  Search: TSearchRec;
  Tail, Path: string;
  Dash, Pid, Handle: Integer;
  Info: Stat;
  Changed: Boolean;
begin
  RemoveStaleStages(Directory);
  Changed := False;
  if FindFirst(IncludeTrailingPathDelimiter(Directory) + '.scu-tmp-*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      Tail := Copy(Search.Name, 10, MaxInt);
      Dash := Pos('-', Tail);
      if (Dash < 2) or (Length(Tail) - Dash <> 6) or
        not TryStrToInt(Copy(Tail, 1, Dash - 1), Pid) or (Pid <= 0) then Continue;
      Path := IncludeTrailingPathDelimiter(Directory) + Search.Name;
      Handle := fpOpen(Path, O_RDONLY or O_NOFOLLOW or O_CLOEXEC or O_NONBLOCK);
      if Handle < 0 then Continue;
      try
        if (fpFStat(Handle, Info) = 0) and FPS_ISREG(Info.st_mode) and (Info.st_uid = fpGetEUid) and
          (fpFlock(Handle, LOCK_EX or LOCK_NB) = 0) then
          if fpUnlink(Path) = 0 then Changed := True;
      finally
        fpClose(Handle);
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  if Changed then SyncParent(IncludeTrailingPathDelimiter(Directory) + 'placeholder');
end;

procedure SyncFile(Handle: THandle; const Path: string);
begin
  if fpFsync(Handle) <> 0 then
    RaiseSystemError('Could not sync "' + Path + '"', fpGetErrNo);
end;

procedure SyncParent(const Path: string);
var
  Handle: THandle;
  Parent: string;
begin
  Parent := ExtractFileDir(Path);
  Handle := fpOpen(Parent, O_RDONLY or O_DIRECTORY);
  if Handle < 0 then
    RaiseSystemError('Could not open parent directory "' + Parent + '" for "' + Path + '"', fpGetErrNo);
  try
    SyncFile(Handle, Parent);
  finally
    fpClose(Handle);
  end;
end;

procedure AtomicWrite(const Path: string; Data: TStream; Options: TAtomicWriteOptions);
var
  TempPath: string;
  Handle: THandle;
  Stream: THandleStream;
  Mode, Mask: mode_t;
  Info, TempInfo: Stat;
begin
  TempPath := IncludeTrailingPathDelimiter(ExtractFileDir(Path)) + '.scu-tmp-' + IntToStr(fpGetPid) + '-XXXXXX';
  UniqueString(TempPath);
  Handle := mkstemp(PChar(TempPath));
  if Handle < 0 then
    raise EScuError.CreateFmt('Could not create temporary file in %s: %s',
      [ExtractFileDir(Path), SysErrorMessage(cerrno)]);
  try
    if fpFlock(Handle, LOCK_EX or LOCK_NB) <> 0 then
      RaiseSystemError('Could not lock temporary output "' + TempPath + '"', fpGetErrNo);
    Stream := THandleStream.Create(Handle);
    try
      try
        if Data.Size > Data.Position then
          Stream.CopyFrom(Data, Data.Size - Data.Position);
      except
        on E: EStreamError do
          raise EScuError.CreateFmt('Could not write "%s": %s', [Path, E.Message]);
      end;
      if awSourceOutput in Options then
      begin
        if (fpLStat(Path, Info) = 0) and FPS_ISREG(Info.st_mode) then
        begin
          Mode := Info.st_mode and &777;
          if not (awNoReplace in Options) then
          begin
            if fpFStat(Handle, TempInfo) <> 0 then
              RaiseSystemError('Could not inspect temporary output for "' + Path + '"', fpGetErrNo);
            if (Info.st_gid <> TempInfo.st_gid) and (fchown(Handle, uid_t(-1), Info.st_gid) <> 0) then
              RaiseSystemError('Could not preserve the group of "' + Path + '"', cerrno);
          end;
        end
        else
        begin
          Mask := fpUmask(0);
          fpUmask(Mask);
          Mode := &666 and not Mask;
        end;
        if fchmod(Handle, Mode) <> 0 then
          RaiseSystemError('Could not set permissions for "' + Path + '"', cerrno);
      end;
      SyncFile(Handle, TempPath);
    finally
      Stream.Free;
    end;
    if not (awNoReplace in Options) then
    begin
      if fpRename(TempPath, Path) <> 0 then
        raise EScuError.CreateFmt('Could not replace %s: %s', [Path, SysErrorMessage(fpGetErrNo)]);
      TempPath := '';
    end
    else if fpLink(TempPath, Path) <> 0 then
      raise EScuError.CreateFmt('Could not create %s: %s', [Path, SysErrorMessage(fpGetErrNo)]);
    try
      SyncParent(Path);
    except
      on E: EScuSystemError do
        raise EScuError.CreateFmt('%s was replaced but its directory could not be synced: %s',
          [Path, E.Message]);
    end;
  finally
    if TempPath <> '' then
      fpUnlink(TempPath);
    fpClose(Handle);
  end;
end;

procedure AtomicWrite(const Path: string; const Data: RawByteString; Options: TAtomicWriteOptions);
var
  Stream: TRawByteStringStream;
begin
  Stream := TRawByteStringStream.Create(Data);
  try
    AtomicWrite(Path, Stream, Options);
  finally
    Stream.Free;
  end;
end;

end.
