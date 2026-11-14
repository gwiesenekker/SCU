unit ScuCommandRegistry;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function CommandHandler(const Name: string): TCommandHandler;

implementation

uses
  ScuDeckCommands, ScuErrors, ScuExportCommands, ScuFilePatternCommands, ScuImportCommands, ScuLibraryCommands, ScuVerifyDecks, ScuVersionDiff;

type
  TCommandRegistration = record
    Name: string[32];
    Handler: TCommandHandler;
  end;

const
  Registrations: array[0..26] of TCommandRegistration = (
    (Name: 'configure_library'; Handler: (Mode: cmLibrary; Run: @ConfigureLibrary;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'create_deck'; Handler: (Mode: cmLibrary; Run: @CreateDeck;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'create_version'; Handler: (Mode: cmLibrary; Run: @CreateVersion;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'delete_deck'; Handler: (Mode: cmLibrary; Run: @DeleteDeck;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'display_deck'; Handler: (Mode: cmLibrary; Run: @DisplayDeck;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'display_deck_diff'; Handler: (Mode: cmLibrary; Run: @DiffDeck;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'display_deck_list'; Handler: (Mode: cmLibrary; Run: @DisplayDeckList;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'display_library'; Handler: (Mode: cmLibrary; Run: @DisplayLibrary;
      ResolveOutputDirectory: nil; ReportCommitted: @ReportLibraryHeader; OutputLockPolicy: olExclusive)),
    (Name: 'display_version'; Handler: (Mode: cmLibrary; Run: @DisplayVersion;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'display_version_diff'; Handler: (Mode: cmLibrary; Run: @DisplayVersionDiff;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'display_version_history'; Handler: (Mode: cmLibrary; Run: @DisplayVersionHistory;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'edit_deck'; Handler: (Mode: cmLibrary; Run: @EditDeckCommand;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'edit_file_patterns'; Handler: (Mode: cmLibrary; Run: @EditFilePatterns;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'extract_deck'; Handler: (Mode: cmLibrary; Run: @ExtractDeck;
      ResolveOutputDirectory: @SingleDeckDirectory; ReportCommitted: nil; OutputLockPolicy: olReuseBuild)),
    (Name: 'extract_version'; Handler: (Mode: cmLibrary; Run: @ExtractVersion;
      ResolveOutputDirectory: @VersionOutputDirectory; ReportCommitted: nil; OutputLockPolicy: olReuseBuild)),
    (Name: 'import_deck'; Handler: (Mode: cmLibrary; Run: @ImportDeckCommand;
      ResolveOutputDirectory: @WorkingDirectory; ReportCommitted: @RefreshImportedFiles; OutputLockPolicy: olReuseBuild)),
    (Name: 'initialize_library'; Handler: (Mode: cmInitialize; Run: @InitializeLibrary;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'list_versions'; Handler: (Mode: cmLibrary; Run: @ListVersions;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'lock_version'; Handler: (Mode: cmLibrary; Run: @LockVersion;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'quit_session'; Handler: (Mode: cmLibrary; Run: @SaveLibrary;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'recover_library'; Handler: (Mode: cmRecover; Run: @SaveRecoveredLibrary;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'release_version'; Handler: (Mode: cmLibrary; Run: @ReleaseVersion;
      ResolveOutputDirectory: @VersionOutputDirectory; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'save_library'; Handler: (Mode: cmLibrary; Run: @SaveLibrary;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'show_history'; Handler: (Mode: cmHistory; Run: @ShowHistory;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'show_library'; Handler: (Mode: cmLibrary; Run: @ShowLibrary;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'verify_audit'; Handler: (Mode: cmVerifyAudit; Run: nil;
      ResolveOutputDirectory: nil; ReportCommitted: nil; OutputLockPolicy: olExclusive)),
    (Name: 'verify_decks'; Handler: (Mode: cmLibrary; Run: @VerifyDecks;
      ResolveOutputDirectory: @VerificationDirectory; ReportCommitted: nil; OutputLockPolicy: olReuseBuild))
  );

function CommandHandler(const Name: string): TCommandHandler;
var Index: Integer;
begin
  for Index := Low(Registrations) to High(Registrations) do
    if Registrations[Index].Name = Name then Exit(Registrations[Index].Handler);
  raise EScuError.CreateFmt('No implementation for command "%s".', [Name]);
end;

end.
