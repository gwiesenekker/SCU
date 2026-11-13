unit ScuExportManifest;

{$mode objfpc}{$H+}

interface

uses
  FPJSON;

const
  ExportManifestName = '.scu-exports.json';

type
  TExportManifest = class
  private
    FPath: string;
    FDocument: TJSONObject;
    FFiles: TJSONArray;
    procedure Validate;
    procedure ValidateEntry(Entry: TJSONObject; const Context: string);
    procedure RecoverPending;
    procedure CompletePending;
    procedure Save;
    procedure InstallEntry(Entry: TJSONObject);
    function GetPending: TJSONObject;
    function GetCount: Integer;
    function GetEntry(Index: Integer): TJSONObject;
    property Pending: TJSONObject read GetPending;
  public
    constructor Create(const Directory: string);
    destructor Destroy; override;
    procedure WriteExport(const LibraryPath, OutputPath, Deck, Version, DeckVersion,
      Mode, ExpansionUTC, Prefix: string; const Bytes: RawByteString);
    property Count: Integer read GetCount;
    property Entries[Index: Integer]: TJSONObject read GetEntry; default;
  end;

implementation

uses
  Classes, SysUtils, DateUtils, ScuClock, ScuCodec, ScuErrors, ScuFiles, ScuJSON,
  ScuSignals, ScuLibraryModel, ScuVersions;

constructor TExportManifest.Create(const Directory: string);
begin
  inherited Create;
  FPath := IncludeTrailingPathDelimiter(CanonicalDirectory(Directory)) + ExportManifestName;
  if RegularFileExists(FPath) then
    FDocument := ParseObject(ReadBytes(FPath, MaxDeckSize), 'Export manifest "' + FPath + '"')
  else
  begin
    FDocument := TJSONObject.Create;
    FDocument.Add('format', 1);
    FDocument.Add('files', TJSONArray.Create);
  end;
  Validate;
  RecoverPending;
end;

destructor TExportManifest.Destroy;
begin
  FDocument.Free;
  inherited Destroy;
end;

procedure TExportManifest.ValidateEntry(Entry: TJSONObject; const Context: string);
var
  Name, Mode, Stamp: string;
  Time: TDateTime;
begin
  Name := Field(Entry, 'file', jtString, Context).AsString;
  if (Name = '') or (Name = '.') or (Name = '..') or (ExtractFileName(Name) <> Name) or
    (Name = ExportManifestName) then
    raise EScuError.Create(Context + ': invalid or duplicate file name.');
  DeckName(Field(Entry, 'deck_name', jtString, Context).AsString);
  if Field(Entry, 'library', jtString, Context).AsString = '' then
    raise EScuError.Create(Context + ': missing library path.');
  if (Field(Entry, 'library_version', jtString, Context).AsString = '') or
    (Field(Entry, 'deck_version', jtString, Context).AsString = '') then
    raise EScuError.Create(Context + ': missing version.');
  if not IsHexDigest(Field(Entry, 'sha256', jtString, Context).AsString, 64) then
    raise EScuError.Create(Context + ': invalid output checksum.');
  Mode := Field(Entry, 'mode', jtString, Context).AsString;
  if (Mode <> 'extract') and (Mode <> 'expand') then
    raise EScuError.Create(Context + ': invalid export mode.');
  Stamp := Field(Entry, 'expansion_utc', jtString, Context).AsString;
  if (Mode = 'expand') and
    (not TryISO8601ToDate(Stamp, Time) or (UtcTimestamp(Time) <> Stamp)) then
    raise EScuError.Create(Context + ': invalid expansion timestamp.');
  Stamp := Field(Entry, 'comment_prefix', jtString, Context).AsString;
  if Stamp <> '' then
    ValidateCommentPrefix(Stamp);
  if Assigned(Entry.Find('interrupted_export')) then
    Field(Entry, 'interrupted_export', jtBoolean, Context);
end;

procedure TExportManifest.Validate;
var
  Index: Integer;
  Entry, Journal: TJSONObject;
  Name, Context, Previous: string;
  Names: TStringList;
begin
  Context := 'Export manifest "' + FPath + '"';
  if IntegerField(FDocument, 'format', Context) <> 1 then
    raise EScuError.Create(Context + ': unsupported format.');
  FFiles := TJSONArray(Field(FDocument, 'files', jtArray, Context));
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    Names.CaseSensitive := True;
    for Index := 0 to FFiles.Count - 1 do
    begin
      CheckSessionInterrupt;
      if not (FFiles[Index] is TJSONObject) then
        raise EScuError.Create(Context + ': expected a file record.');
      Entry := TJSONObject(FFiles[Index]);
      ValidateEntry(Entry, Context);
      Name := Entry.Strings['file'];
      if Names.IndexOf(Name) >= 0 then
        raise EScuError.Create(Context + ': invalid or duplicate file name.');
      Names.Add(Name);
    end;
    if Assigned(FDocument.Find('pending')) then
    begin
      Journal := TJSONObject(Field(FDocument, 'pending', jtObject, Context));
      ValidateEntry(TJSONObject(Field(Journal, 'entry', jtObject, Context)), Context);
      Previous := Field(Journal, 'previous_sha256', jtString, Context).AsString;
      if (Previous <> '') and not IsHexDigest(Previous, 64) then
        raise EScuError.Create(Context + ': invalid previous output checksum.');
    end;
  finally
    Names.Free;
  end;
end;

function TExportManifest.GetPending: TJSONObject;
var
  Journal: TJSONData;
begin
  Result := nil;
  Journal := FDocument.Find('pending');
  if Assigned(Journal) then
    Result := TJSONObject(TJSONObject(Journal).Find('entry'));
end;

procedure TExportManifest.InstallEntry(Entry: TJSONObject);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if Entries[Index].Strings['file'] = Entry.Strings['file'] then
    begin
      FFiles.Delete(Index);
      Break;
    end;
  FFiles.Add(Entry.Clone);
end;

procedure TExportManifest.CompletePending;
begin
  InstallEntry(Pending);
  FDocument.Delete('pending');
  Save;
end;

procedure TExportManifest.RecoverPending;
var
  Entry, Journal: TJSONObject;
  Path, Actual, Previous: string;
begin
  Entry := Pending;
  if Entry = nil then
    Exit;
  CheckSessionInterrupt;
  Journal := TJSONObject(FDocument.Find('pending'));
  Path := IncludeTrailingPathDelimiter(ExtractFileDir(FPath)) + Entry.Strings['file'];
  Actual := '';
  if RegularFileExists(Path) then
    Actual := AuditSHA256(ReadBytes(Path, MaxDeckSize));
  Previous := Journal.Strings['previous_sha256'];
  CheckSessionInterrupt;
  if Actual = Entry.Strings['sha256'] then
    CompletePending
  else if Actual = Previous then
  begin
    // Empty checksums represent a missing file. No output was published.
    FDocument.Delete('pending');
    Save;
  end
  else
  begin
    // Preserve provenance without claiming that this output was completed.
    Entry.Booleans['interrupted_export'] := True;
    CompletePending;
  end;
end;

function TExportManifest.GetCount: Integer;
begin
  Result := FFiles.Count;
end;

function TExportManifest.GetEntry(Index: Integer): TJSONObject;
begin
  Result := TJSONObject(FFiles[Index]);
end;

procedure TExportManifest.WriteExport(const LibraryPath, OutputPath, Deck, Version, DeckVersion,
  Mode, ExpansionUTC, Prefix: string; const Bytes: RawByteString);
var
  Entry, Journal: TJSONObject;
  Name, Previous: string;
begin
  Name := ExtractFileName(OutputPath);
  RecoverPending;
  Previous := '';
  if RegularFileExists(OutputPath) then
    Previous := AuditSHA256(ReadBytes(OutputPath, MaxDeckSize));
  Journal := TJSONObject.Create;
  Entry := TJSONObject.Create;
  Journal.Add('entry', Entry);
  FDocument.Add('pending', Journal);
  Journal.Add('previous_sha256', Previous);
  Entry.Add('file', Name);
  Entry.Add('library', CanonicalFile(LibraryPath));
  Entry.Add('deck_name', Deck);
  Entry.Add('library_version', Version);
  Entry.Add('deck_version', DeckVersion);
  Entry.Add('mode', Mode);
  Entry.Add('expansion_utc', ExpansionUTC);
  Entry.Add('comment_prefix', Prefix);
  Entry.Add('sha256', AuditSHA256(Bytes));
  Save;
  CheckSessionInterrupt;
  AtomicWrite(OutputPath, Bytes, [awSourceOutput]);
  CheckSessionInterrupt;
  CompletePending;
end;

procedure TExportManifest.Save;
begin
  AtomicWrite(FPath, FDocument.FormatJSON + LineEnding);
end;

end.
