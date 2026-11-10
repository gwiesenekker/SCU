unit ScuCopyMetadata;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON, ScuSQLite;

function ScanCopyMetadata(const Source: RawByteString; const Prefix: string): TJSONObject;
procedure CacheCopyMetadata(Database: TSQLiteLibrary; Sequence: Integer; const Prefix: string; Targets: TStrings);

implementation

uses
  ScuDirectives;

function MakeCopyMetadata(const Prefix: string; Targets: TStrings): TJSONObject;
var
  Values: TJSONArray;
  Target: string;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('prefix', Prefix);
    Values := TJSONArray.Create;
    Result.Add('targets', Values);
    for Target in Targets do
      Values.Add(Target);
  except
    Result.Free;
    raise;
  end;
end;

function ScanCopyMetadata(const Source: RawByteString; const Prefix: string): TJSONObject;
var
  Targets: TStringList;
begin
  Targets := TStringList.Create;
  try
    Targets.CaseSensitive := True;
    Targets.Sorted := True;
    Targets.Duplicates := dupIgnore;
    CollectCopyTargets(Source, Prefix, Targets);
    Result := MakeCopyMetadata(Prefix, Targets);
  finally
    Targets.Free;
  end;
end;

procedure CacheCopyMetadata(Database: TSQLiteLibrary; Sequence: Integer; const Prefix: string; Targets: TStrings);
var
  Metadata: TJSONObject;
begin
  Metadata := MakeCopyMetadata(Prefix, Targets);
  try
    Database.Revisions.CacheCopyMetadata(Sequence, Metadata.AsJSON);
  finally
    Metadata.Free;
  end;
end;

end.
