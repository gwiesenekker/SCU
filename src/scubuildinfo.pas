unit ScuBuildInfo;

{$mode objfpc}{$H+}

interface

function ScuBuildVersion: string;

implementation

resourcestring
  ScuReleaseVersion = '1.0';
  ScuCommitID = {$I scucommit.inc};

function ScuBuildVersion: string;
begin
  Result := ScuReleaseVersion + '-' + ScuCommitID;
end;

end.
