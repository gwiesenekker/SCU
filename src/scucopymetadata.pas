unit ScuCopyMetadata;

{$mode objfpc}{$H+}

interface

uses
  Classes, FPJSON;

// Compatibility only: validate metadata covered by historical audit digests.
// New revision payloads and release publication never scan COPY directives.
function ScanCopyMetadata(const Source: RawByteString; const Prefix: string): TJSONObject;

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

end.
