unit ScuRevisionJSON;

{$mode objfpc}{$H+}

interface

uses
  FPJSON;

// The caller owns the parsed revision, including the encoded source.
function ParseRevisionPayload(const Payload, Context: RawByteString): TJSONObject;
function RevisionPayloadDeleted(Payload: TJSONObject): Boolean;

implementation

uses
  ScuErrors, ScuJSON;

function EncodedSourceRange(const Payload: RawByteString; out First, Last: SizeInt): Boolean;
const
  FieldName = '"zstd_base64"';
var
  Index, Depth, StringStart: SizeInt;
begin
  Result := False;
  Index := 1;
  Depth := 0;
  while Index <= Length(Payload) do
  begin
    case Payload[Index] of
      '{', '[': Inc(Depth);
      '}', ']': Dec(Depth);
      '"':
        begin
          StringStart := Index;
          Inc(Index);
          // Ignore nested fields and text that merely mentions the field name.
          while (Index <= Length(Payload)) and (Payload[Index] <> '"') do
          begin
            if Payload[Index] = '\' then
              Inc(Index);
            Inc(Index);
          end;
          if Index > Length(Payload) then
            Exit;
          if (Depth = 1) and (Index - StringStart + 1 = Length(FieldName)) and
            (CompareByte(Payload[StringStart], FieldName[1], Length(FieldName)) = 0) then
          begin
            Inc(Index);
            while (Index <= Length(Payload)) and (Payload[Index] in [#9, #10, #13, ' ']) do
              Inc(Index);
            if (Index > Length(Payload)) or (Payload[Index] <> ':') then
              Exit;
            Inc(Index);
            while (Index <= Length(Payload)) and (Payload[Index] in [#9, #10, #13, ' ']) do
              Inc(Index);
            if (Index > Length(Payload)) or (Payload[Index] <> '"') then
              Exit;
            First := Index + 1;
            Index := First;
            // Stored base64 is unescaped ASCII. Other string spellings go
            // through the JSON parser so escapes and invalid JSON keep its rules.
            while (Index <= Length(Payload)) and (Payload[Index] <> '"') do
            begin
              if (Payload[Index] < ' ') or (Payload[Index] > '~') or (Payload[Index] = '\') then
                Exit;
              Inc(Index);
            end;
            Last := Index - 1;
            Exit(Index <= Length(Payload));
          end;
        end;
    end;
    Inc(Index);
  end;
end;

function ParseRevisionPayload(const Payload, Context: RawByteString): TJSONObject;
var
  First, Last: SizeInt;
  Metadata, Encoded: RawByteString;
begin
  if not EncodedSourceRange(Payload, First, Last) then
    Exit(ParseObject(Payload, Context));
  Encoded := Copy(Payload, First, Last - First + 1);
  // Retain the empty string in its original field position during parsing.
  Metadata := Copy(Payload, 1, First - 1) + Copy(Payload, Last + 1, MaxInt);
  try
    Result := ParseObject(Metadata, Context);
  except
    // Use the full parser on malformed metadata so its error locations still
    // refer to the original payload.
    on E: EScuError do Exit(ParseObject(Payload, Context));
  end;
  try
    Result.Strings['zstd_base64'] := Encoded;
  except
    Result.Free;
    raise;
  end;
end;

function RevisionPayloadDeleted(Payload: TJSONObject): Boolean;
begin
  Result := Assigned(Payload.Find('deleted'));
  if Result then
    Result := Field(Payload, 'deleted', jtBoolean).AsBoolean;
end;

end.
