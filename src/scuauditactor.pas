unit ScuAuditActor;
{$mode objfpc}{$H+}
interface
uses FPJSON;
procedure AddAuditActor(Event: TJSONObject);
implementation
uses {$IFDEF WINDOWS}ScuPlatformAuditActorWindows{$ELSE}
  {$IFDEF LINUX}ScuPlatformAuditActorLinux{$ELSE}{$FATAL No SCU audit actor backend}{$ENDIF}{$ENDIF};
procedure AddAuditActor(Event: TJSONObject);
begin
  {$IFDEF WINDOWS}ScuPlatformAuditActorWindows{$ELSE}ScuPlatformAuditActorLinux{$ENDIF}.AddAuditActor(Event);
end;
end.
