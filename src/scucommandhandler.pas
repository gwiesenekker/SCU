unit ScuCommandHandler;

{$mode objfpc}{$H+}

interface

uses
  ScuBuildTypes, ScuCommandSnapshots, ScuCommand, ScuLibrary, ScuOutput, ScuSQLite;

type
  TBuildRequest = ScuBuildTypes.TBuildRequest;

  TCommandContext = record
    // The executor owns the command's locks, database and library lifetime.
    Command: TScuCommand;
    LibraryPath, OutputDirectory: string;
    LibraryFile: TDeckLibrary;
    Database: TSQLiteLibrary;
    StagedSave: TLibrarySave;
    Output: TScuOutput;
    Snapshots: TAuditSnapshots;
    Build: TBuildRequest;
    FilesPublished: Boolean;
  end;

  TCommandOperation = function(var Context: TCommandContext): string;
  TResolveOutputDirectory = function(const Context: TCommandContext): string;
  TReportCommand = procedure(const Context: TCommandContext);

  TCommandMode = (cmLibrary, cmInitialize, cmHistory, cmVerifyAudit, cmRecover);
  TOutputLockPolicy = (olExclusive, olReuseBuild);

  TCommandHandler = record
    Mode: TCommandMode;
    Run: TCommandOperation;
    ResolveOutputDirectory: TResolveOutputDirectory;
    ReportCommitted: TReportCommand;
    OutputLockPolicy: TOutputLockPolicy;
  end;

function BooleanArgument(Command: TScuCommand; const Name: string; const Default: string = 'yes'): Boolean;
function PrefixArgument(Command: TScuCommand): string;
function ResolveSnapshot(const Context: TCommandContext): TLibrarySnapshot;
function ResolveLastModifiedDeck(LibraryFile: TDeckLibrary): string;
function ResolveDeck(var Context: TCommandContext): string;
procedure ReportSnapshot(const Context: TCommandContext; const DeckVersion: string = ''; const Deck: string = '');

implementation

uses
  SysUtils, ScuCommands, ScuErrors, ScuVersions;

function BooleanArgument(Command: TScuCommand; const Name: string; const Default: string): Boolean;
begin
  if not TryParseYesNo(Command.Argument(Name, Default), Result) then
    raise EScuError.CreateFmt('Expected yes/y or no/n for %s.', [Name]);
end;

function PrefixArgument(Command: TScuCommand): string;
begin
  Result := Command.Argument('comment-prefix');
  if Command.HasArgument('comment-prefix') then
    ValidateCommentPrefix(Result);
end;

function ResolveSnapshot(const Context: TCommandContext): TLibrarySnapshot;
begin
  Result := Context.LibraryFile.ParseLibrarySnapshot(Context.Command.Argument('version', CurrentVersionSelector));
end;

function ResolveLastModifiedDeck(LibraryFile: TDeckLibrary): string;
begin
  Result := LibraryFile.LastModifiedDeck;
  if Result = '' then
    raise EScuError.Create('No deck has been modified in this library.');
end;

function ResolveDeck(var Context: TCommandContext): string;
var Snapshot: TLibrarySnapshot;
begin
  Result := Context.Command['deck_name'];
  if SameText(Result, LastModifiedDeckSelector) then
  begin
    Result := ResolveLastModifiedDeck(Context.LibraryFile);
    Context.Snapshots.ResolvedDeck := Result;
    if ((Context.Command.Name = 'extract_deck') or (Context.Command.Name = 'edit_deck')) and
      not Context.LibraryFile.TryDeckSnapshot(Result, Context.LibraryFile.Revision, Snapshot) then
      raise EScuError.Create('The last modified deck "' + Result + '" is deleted. Specify deck_name explicitly.');
  end;
end;

procedure ReportSnapshot(const Context: TCommandContext; const DeckVersion: string; const Deck: string);
begin
  if DeckVersion <> '' then
    Context.Output.Report(Format('Using library version %s, deck "%s", deck_version %s.',
      [Context.Snapshots.Selected.Version, Deck, DeckVersion]))
  else
    Context.Output.Report(Format('Using library version %s.', [Context.Snapshots.Selected.Version]));
end;

end.
