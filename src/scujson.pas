unit ScuJSON;

{$mode objfpc}{$H+}

interface

uses
  FPJSON;

function ParseJSON(const Data: RawByteString; const Source: string = ''): TJSONData;
function ParseObject(const Data: RawByteString; const Source: string = ''): TJSONObject;
function Field(Obj: TJSONObject; const Name: string; Kind: TJSONType; const Source: string = ''): TJSONData;
function IntegerField(Obj: TJSONObject; const Name: string; const Source: string = ''): Int64;

implementation

uses
  Classes, SysUtils, JSONParser, JSONScanner, ScuErrors;

function InSource(const Message, Source: string): string;
begin
  if Source = '' then
    Exit(Message);
  Result := Source + ': ' + Message;
end;

function ParseJSON(const Data: RawByteString; const Source: string): TJSONData;
var
  Parser: TJSONParser;
begin
  try
    Parser := TJSONParser.Create(Data, [joUTF8, joStrict]);
    try
      Result := Parser.Parse;
    finally
      Parser.Free;
    end;
  except
    on E: EParserError do
      raise EScuError.Create(InSource(E.Message, Source));
    on E: EJSON do
      raise EScuError.Create(InSource(E.Message, Source));
    on E: EConvertError do
      raise EScuError.Create(InSource(E.Message, Source));
  end;
end;

function ParseObject(const Data: RawByteString; const Source: string): TJSONObject;
var
  Value: TJSONData;
begin
  Value := ParseJSON(Data, Source);
  if not (Value is TJSONObject) then
  begin
    Value.Free;
    raise EScuError.Create(InSource('Expected a JSON object.', Source));
  end;
  Result := TJSONObject(Value);
end;

function Field(Obj: TJSONObject; const Name: string; Kind: TJSONType; const Source: string): TJSONData;
begin
  Result := Obj.Find(Name);
  if (Result = nil) or (Result.JSONType <> Kind) then
    raise EScuError.Create(InSource(Format('Missing or invalid JSON field "%s".', [Name]), Source));
end;

function IntegerField(Obj: TJSONObject; const Name: string; const Source: string): Int64;
begin
  if not TryStrToInt64(Field(Obj, Name, jtNumber, Source).AsJSON, Result) then
    raise EScuError.Create(InSource(Format('Expected an integer in JSON field "%s".', [Name]), Source));
end;

end.
