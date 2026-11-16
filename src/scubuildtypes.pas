unit ScuBuildTypes;
{$mode objfpc}{$H+}
interface
type
  TBuildRequest = record
    Command, OutputPath, WorkingDirectory, LibraryPath: string;
  end;
implementation
end.
