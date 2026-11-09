unit ScuJSON;

{$mode objfpc}{$H+}

interface

uses
  FPJSON;

function ParseJSON(const Data: RawByteString): TJSONData;
function ParseObject(const Data: RawByteString): TJSONObject;
function Field(Obj: TJSONObject; const Name: string; Kind: TJSONType): TJSONData;
function IntegerField(Obj: TJSONObject; const Name: string): Int64;

implementation

uses
  SysUtils, JSONParser, JSONScanner, ScuIO;

function ParseJSON(const Data: RawByteString): TJSONData;
var
  Parser: TJSONParser;
begin
  Parser := TJSONParser.Create(Data, [joUTF8, joStrict]);
  try
    Result := Parser.Parse;
  finally
    Parser.Free;
  end;
end;

function ParseObject(const Data: RawByteString): TJSONObject;
var
  Value: TJSONData;
begin
  Value := ParseJSON(Data);
  if not (Value is TJSONObject) then
  begin
    Value.Free;
    raise EScuError.Create('Expected a JSON object.');
  end;
  Result := TJSONObject(Value);
end;

function Field(Obj: TJSONObject; const Name: string; Kind: TJSONType): TJSONData;
begin
  Result := Obj.Find(Name);
  if (Result = nil) or (Result.JSONType <> Kind) then
    raise EScuError.CreateFmt('Missing or invalid JSON field "%s".', [Name]);
end;

function IntegerField(Obj: TJSONObject; const Name: string): Int64;
begin
  if not TryStrToInt64(Field(Obj, Name, jtNumber).AsJSON, Result) then
    raise EScuError.CreateFmt('Expected an integer in JSON field "%s".', [Name]);
end;

end.
