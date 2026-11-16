unit ScuPlatformPaths;

{$mode objfpc}{$H+}

interface

// Paths use native filesystem bytes on Linux, UTF-8 on Windows. Resolution of
// a file canonicalizes its existing parent only, preserving the final name.
procedure InitializePlatformPaths;
function PlatformCanonicalFile(const Path: string): string;
function PlatformCanonicalDirectory(const Path: string): string;
function RunningExecutablePath: string;
function InvocationExecutablePath: string;
function ExecutableName(const BaseName: string): string;
function HistoryStateRoot: string;
function GuiPreferencesPath: string;
function PathEndsInSeparator(const Path: string): Boolean;
// Compare already-resolved storage paths, not arbitrary relative paths.
function SameStoragePath(const Left, Right: string): Boolean;

implementation

uses SysUtils, ScuErrors,
  {$IFDEF WINDOWS}ScuPlatformPathsWindows{$ELSE}
  {$IFDEF LINUX}ScuPlatformPathsLinux{$ELSE}
    {$FATAL No SCU path backend for this platform}
  {$ENDIF}{$ENDIF};

procedure InitializePlatformPaths;
begin
  {$IFDEF WINDOWS}
  AllowDirectorySeparators := ['/', '\'];
  {$ELSE}
  AllowDirectorySeparators := ['/'];
  {$ENDIF}
end;

function PathEndsInSeparator(const Path: string): Boolean;
begin
  Result := False;
  if Path = '' then Exit;
  {$IFDEF WINDOWS}
  Result := Path[Length(Path)] in ['/', '\'];
  {$ELSE}
  Result := Path[Length(Path)] = DirectorySeparator;
  {$ENDIF}
end;

function PlatformCanonicalFile(const Path: string): string;
var FullPath, Parent: string;
begin
  if (Path = '') or PathEndsInSeparator(Path) then
    raise EScuError.Create('Expected a file path.');
  FullPath := AbsolutePath(Path);
  Parent := ExtractFileDir(FullPath);
  Result := IncludeTrailingPathDelimiter(ResolveDirectory(Parent)) + ExtractFileName(FullPath);
end;

function PlatformCanonicalDirectory(const Path: string): string;
begin
  Result := ResolveDirectory(Path);
end;

function RunningExecutablePath: string;
begin
  Result := RunningExecutable;
end;

function InvocationExecutablePath: string;
begin
  Result := InvocationExecutable;
end;

function ExecutableName(const BaseName: string): string;
begin
  Result := BaseName {$IFDEF WINDOWS}+ '.exe'{$ENDIF};
end;

function HistoryStateRoot: string;
begin
  Result := StateRoot;
end;

function GuiPreferencesPath: string;
begin
  Result := IncludeTrailingPathDelimiter(ConfigRoot) + 'scu' + DirectorySeparator + 'gui.json';
end;

function SameStoragePath(const Left, Right: string): Boolean;
begin
  Result := PathsEqual(Left, Right);
end;

end.
