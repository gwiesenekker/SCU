unit ScuPlatformScanWindows;
{$mode objfpc}{$H+}
interface
uses Windows;
type
  TPlatformDirectoryScan = class
  private
    FDirectory: string;
    FHandle: THandle;
    FData: TWin32FindDataW;
    FFirst, FDone, FIncludeHidden: Boolean;
  public
    constructor Create(const Directory: string; IncludeHidden: Boolean = False);
    destructor Destroy; override;
    function Next(out Name: string): Boolean;
    function SelectedRegularFile(const Name: string): Boolean;
  end;
function CompareFileNames(const Left, Right: string): Integer;
function FileNameDigest(const Name: string): string;
function MatchesPattern(const Pattern, Name: string): Boolean;
implementation
uses SysUtils, ScuErrors, ScuPlatformPathsWindows, ScuPlatformFileSecurityWindows, ScuSignals;

function OrdinalCompare(Left: PWideChar; LeftLength: Integer; Right: PWideChar;
  RightLength: Integer; IgnoreCase: BOOL): Integer; stdcall;
  external 'kernel32.dll' name 'CompareStringOrdinal';

function CompareFileNames(const Left, Right: string): Integer;
var L, R: UnicodeString; Status: Integer;
begin
  L := UTF8Decode(Left); R := UTF8Decode(Right);
  Status := OrdinalCompare(PWideChar(L), Length(L), PWideChar(R), Length(R), True);
  if Status = 0 then RaiseSystemError('Could not compare source filenames', GetLastError);
  Result := Status - 2;
end;

function HashBytes(Algorithm: PWideChar; Flags: DWORD; Reserved: Pointer;
  Data: PByte; Size: DWORD; Digest: PByte; var DigestSize: DWORD): BOOL;
  stdcall; external 'crypt32.dll' name 'CryptHashCertificate2';

function FileNameDigest(const Name: string): string;
const Digits = '0123456789abcdef';
var Digest: array[0..31] of Byte; Size: DWORD; Index: Integer;
begin
  Size := SizeOf(Digest);
  if not HashBytes('SHA256', 0, nil, PByte(PChar(Name)), Length(Name), @Digest[0], Size) then
    RaiseSystemError('Could not hash source filename "' + Name + '"', GetLastError);
  if Size <> SizeOf(Digest) then raise EScuError.Create('Unexpected SHA-256 filename digest size.');
  SetLength(Result, Size * 2);
  for Index := 0 to Size - 1 do
  begin
    Result[2 * Index + 1] := Digits[1 + Digest[Index] shr 4];
    Result[2 * Index + 2] := Digits[1 + Digest[Index] and 15];
  end;
end;

function MatchesPattern(const Pattern, Name: string): Boolean;
var P, N: UCS4String; PI, NI, Star, Retry, Last, J, PL, NL: SizeInt;
  Match, Negate, Closed: Boolean; C, Low, High: UCS4Char;
function FoldedScalars(const Text: string): UCS4String;
var Wide: UnicodeString; Index: Integer;
begin
  Wide := UTF8Decode(Text);
  if Wide <> '' then CharUpperBuffW(PWideChar(Wide), Length(Wide));
  Result := UnicodeStringToUCS4String(Wide);
  // The RTL returns zero-based scalars and a terminator. Move the scalars
  // right once so the matcher can use one-based indexes and omit the NUL.
  for Index := Length(Result) - 1 downto 1 do Result[Index] := Result[Index - 1];
end;
begin
  P := FoldedScalars(Pattern); N := FoldedScalars(Name);
  PL := Length(P) - 1; NL := Length(N) - 1;
  if (NL > 0) and (N[1] = Ord('.')) and ((PL = 0) or (P[1] <> Ord('.'))) then Exit(False);
  PI := 1; NI := 1; Star := 0; Retry := 0;
  while NI <= NL do
  begin
    if (PI <= PL) and (P[PI] = Ord('*')) then
    begin Star := PI; Inc(PI); Retry := NI; Continue; end;
    Match := False; Last := PI;
    if PI <= PL then
    begin
      C := P[PI];
      if C = Ord('[') then
      begin
        J := PI + 1; Negate := False;
        if (J <= PL) and (P[J] in [Ord('!'), Ord('^')]) then begin Negate := True; Inc(J); end;
        Closed := False;
        if (J <= PL) and (P[J] = Ord(']')) then
        begin Match := N[NI] = Ord(']'); Inc(J); end;
        while J <= PL do
        begin
          if P[J] = Ord(']') then begin Closed := True; Break; end;
          Low := P[J]; High := Low; Inc(J);
          if (J + 1 <= PL) and (P[J] = Ord('-')) and (P[J+1] <> Ord(']')) then
          begin High := P[J+1]; Inc(J, 2); end;
          Match := Match or ((N[NI] >= Low) and (N[NI] <= High));
        end;
        if Closed then begin Match := Match xor Negate; Last := J; end
        else Match := N[NI] = Ord('[');
      end
      else Match := (C = Ord('?')) or (C = N[NI]);
    end;
    if Match then begin PI := Last + 1; Inc(NI); Continue; end;
    if Star = 0 then Exit(False);
    Inc(Retry); NI := Retry; PI := Star + 1;
  end;
  while (PI <= PL) and (P[PI] = Ord('*')) do Inc(PI);
  Result := PI > PL;
end;

constructor TPlatformDirectoryScan.Create(const Directory: string; IncludeHidden: Boolean);
var Error: DWORD;
begin
  inherited Create;
  FHandle := INVALID_HANDLE_VALUE;
  FDirectory := IncludeTrailingPathDelimiter(Directory);
  FHandle := FindFirstFileW(PWideChar(NativeFilePath(FDirectory + '*')), @FData);
  if FHandle = INVALID_HANDLE_VALUE then
  begin
    Error := GetLastError;
    if Error = ERROR_FILE_NOT_FOUND then FDone := True
    else RaiseSystemError('Could not scan directory "' + FDirectory + '"', Error);
  end;
  FFirst := True;
  FIncludeHidden := IncludeHidden;
end;
destructor TPlatformDirectoryScan.Destroy;
begin
  if FHandle <> INVALID_HANDLE_VALUE then Windows.FindClose(FHandle);
  inherited Destroy;
end;
function TPlatformDirectoryScan.Next(out Name: string): Boolean;
var Error: DWORD;
begin
  if FDone then Exit(False);
  repeat
    CheckSessionInterrupt;
    if not FFirst and not FindNextFileW(FHandle, @FData) then
    begin
      Error := GetLastError;
      if Error <> ERROR_NO_MORE_FILES then
        RaiseSystemError('Could not read directory "' + FDirectory + '"', Error);
      FDone := True; Exit(False);
    end;
    FFirst := False;
    Name := UTF8Encode(UnicodeString(PWideChar(@FData.cFileName[0])));
    // Attribute-hidden files are not working sources, even under a broad glob.
  until FIncludeHidden or ((FData.dwFileAttributes and FILE_ATTRIBUTE_HIDDEN) = 0);
  Result := True;
end;
function TPlatformDirectoryScan.SelectedRegularFile(const Name: string): Boolean;
var Handle: THandle; Info: TByHandleFileInformation; Path: string;
begin
  Path := FDirectory + Name;
  Handle := CreateFileW(PWideChar(NativeFilePath(Path)), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    OpenReparsePoint or FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then
    RaiseSystemError('Could not inspect selected file "' + Path + '"', GetLastError);
  try
    if not GetFileInformationByHandle(Handle, Info) then
      RaiseSystemError('Could not inspect selected file "' + Path + '"', GetLastError);
    if (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
      raise EScuError.Create('Cannot snapshot a symbolic link or reparse point: "' + Path + '".');
    Result := (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0;
    if Result and (GetFileType(Handle) <> FILE_TYPE_DISK) then
      raise EScuError.Create('Expected a regular file: "' + Path + '".');
  finally
    CloseHandle(Handle);
  end;
end;
end.
