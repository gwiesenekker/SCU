unit ScuPlatformAuditActorLinux;
{$mode objfpc}{$H+}
interface
uses FPJSON;
procedure AddAuditActor(Event: TJSONObject);
implementation
uses BaseUnix;
procedure AddAuditActor(Event: TJSONObject);
begin
  // Keep the historical field name, integer type and insertion order intact.
  Event.Add('uid', Int64(fpGetEUID));
end;
end.
