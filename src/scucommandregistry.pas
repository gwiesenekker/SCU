unit ScuCommandRegistry;

{$mode objfpc}{$H+}

interface

uses
  ScuCommandHandler;

function CommandHandler(const Name: string): TCommandHandler;

implementation

uses
  ScuDeckCommands, ScuErrors, ScuExpandCommands, ScuLibraryCommands, ScuVersionDiff;

function CommandHandler(const Name: string): TCommandHandler;
begin
  Result := Default(TCommandHandler);
  case Name of
    'configure_library': Result.Run := @ConfigureLibrary;
    'create_deck': Result.Run := @CreateDeck;
    'display_deck_diff': Result.Run := @DiffDeck;
    'display_version_diff': Result.Run := @DisplayVersionDiff;
    'display_deck': Result.Run := @DisplayDeck;
    'display_deck_list': Result.Run := @DisplayDeckList;
    'display_version_history': Result.Run := @DisplayVersionHistory;
    'display_expansion_checkpoints': Result.Run := @DisplayExpansionCheckpoints;
    'display_library':
      begin
        Result.Run := @DisplayLibrary;
        Result.ReportCommitted := @ReportLibraryHeader;
      end;
    'edit_deck': Result.Run := @EditDeckCommand;
    'expand_deck':
      begin
        Result.Run := @ExpandDeck;
        Result.ResolveOutputDirectory := @SingleDeckDirectory;
        Result.ReuseBuildLock := True;
      end;
    'expand_modified_decks':
      begin
        Result.Run := @ExpandModifiedDecks;
        Result.ResolveOutputDirectory := @BulkExpansionDirectory;
        Result.Prepare := @PrepareBulkExpansion;
      end;
    'extract_deck': Result.Run := @ExtractDeck;
    'extract_modified_decks': Result.Run := @ExtractModifiedDecks;
    'initialize_library':
      begin
        Result.Mode := cmInitialize;
        Result.Run := @InitializeLibrary;
      end;
    'list_versions': Result.Run := @ListVersions;
    'lock_version': Result.Run := @LockVersion;
    'recover_library':
      begin
        Result.Mode := cmRecover;
        Result.Run := @SaveRecoveredLibrary;
      end;
    'reset_expansion_checkpoint':
      begin
        Result.Run := @ResetExpansionCheckpoint;
        Result.ResolveOutputDirectory := @CheckpointDirectory;
      end;
    'save_library', 'quit_session':
      begin
        Result.Run := @SaveLibrary;
        Result.SavesLibrary := True;
      end;
    'show_history':
      begin
        Result.Mode := cmHistory;
        Result.Run := @ShowHistory;
      end;
    'show_library': Result.Run := @ShowLibrary;
    'start_version': Result.Run := @StartVersion;
    'store_deck': Result.Run := @StoreDeck;
    'verify_audit': Result.Mode := cmVerifyAudit;
    else
      raise EScuError.CreateFmt('No implementation for command "%s".', [Name]);
  end;
end;

end.
