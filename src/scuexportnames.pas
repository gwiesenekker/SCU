unit ScuExportNames;
{$mode objfpc}{$H+}
interface
uses {$IFDEF WINDOWS}AVL_Tree,{$ENDIF} Classes;
type
  TExportFileKeys = class
  private
    {$IFDEF WINDOWS}FTree: TAVLTree;{$ENDIF}
  public
    constructor Create;
    destructor Destroy; override;
    function Key(const Name: RawByteString): string;
  end;
procedure ValidateExportFileName(const Name: RawByteString);
procedure ValidateExportDirectory(const Path: string);
procedure ValidateExportPath(const Path: string);
procedure CheckExportTarget(const Path: string);
function SameExportLibrary(const Left, Right: RawByteString): Boolean;
implementation
uses SysUtils, ScuErrors, ScuCodec{$IFDEF WINDOWS}, ScuWindowsFileNames, ScuPlatformPaths,
  ScuPlatformScanWindows{$ENDIF};
{$IFDEF WINDOWS}
type
  TNameKey = class
    Name: RawByteString;
    Value: string;
  end;
function CompareEntries(Left, Right: Pointer): Integer;
begin Result := CompareFileNames(TNameKey(Left).Name, TNameKey(Right).Name); end;
function CompareKey(Left, Right: Pointer): Integer;
begin Result := CompareFileNames(PRawByteString(Left)^, TNameKey(Right).Name); end;
{$ENDIF}
constructor TExportFileKeys.Create;
begin
  inherited Create;
  {$IFDEF WINDOWS}FTree := TAVLTree.Create(@CompareEntries);{$ENDIF}
end;
destructor TExportFileKeys.Destroy;
begin
  {$IFDEF WINDOWS}if Assigned(FTree) then FTree.FreeAndClear; FTree.Free;{$ENDIF}
  inherited Destroy;
end;
function TExportFileKeys.Key(const Name: RawByteString): string;
{$IFDEF WINDOWS}var Node: TAVLTreeNode; Entry: TNameKey;{$ENDIF}
begin
  {$IFDEF WINDOWS}
  ValidateWindowsUTF8(Name, 'filename');
  Node := FTree.FindKey(@Name, @CompareKey);
  if Assigned(Node) then Exit(TNameKey(Node.Data).Value);
  Entry := TNameKey.Create;
  try
    // Keep the first spelling's raw digest as the in-memory key. The tree
    // groups ordinal case aliases without normalizing serialized filename bytes.
    Entry.Name := Name;
    Entry.Value := AuditSHA256(Name);
    FTree.Add(Entry);
    Result := Entry.Value;
    Entry := nil;
  finally Entry.Free; end;
  {$ELSE}Result := AuditSHA256(Name);{$ENDIF}
end;
procedure ValidateExportFileName(const Name: RawByteString);
begin {$IFDEF WINDOWS}ValidateWindowsFileName(Name, 'export');{$ENDIF} end;
procedure ValidateExportDirectory(const Path: string);
begin
  {$IFDEF WINDOWS}
  if Path = '' then raise EScuError.Create('Expected a Windows output directory.');
  ValidateWindowsOutputPath(IncludeTrailingPathDelimiter(Path) + 'scu-validation-placeholder');
  {$ENDIF}
end;
procedure ValidateExportPath(const Path: string);
begin {$IFDEF WINDOWS}ValidateWindowsOutputPath(Path);{$ENDIF} end;
procedure CheckExportTarget(const Path: string);
begin {$IFDEF WINDOWS}CheckWindowsOutputTarget(Path);{$ENDIF} end;
function SameExportLibrary(const Left, Right: RawByteString): Boolean;
begin
  {$IFDEF WINDOWS}
  ValidateWindowsUTF8(Left, 'library path'); ValidateWindowsUTF8(Right, 'library path');
  Result := SameStoragePath(Left, Right);
  {$ELSE}Result := Left = Right;{$ENDIF}
end;
end.
