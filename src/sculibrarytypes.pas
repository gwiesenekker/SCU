unit ScuLibraryTypes;

{$mode objfpc}{$H+}

interface


const
  CurrentDeckVersionSelector = 'scu$current_deck_version';
  PreviousDeckVersionSelector = 'scu$previous_deck_version';
  LastModifiedDeckSelector = 'scu$last_modified_deck';
  CurrentVersionSelector = 'scu$current_version';
  LatestVersionSelector = 'scu$latest_version';
  PreviousVersionSelector = 'scu$previous_version';

type
  TDeckStoreOptions = set of (dsoCreateOnly);
  TDeckExtractOptions = set of (deoAllowDeleted);

  TDeckRevisionFormats = set of (drLibraryRevision, drDeckVersion);

  TLibrarySnapshot = record
    Version: string;
    LibraryRevision: Integer;
  end;

  TDeckSelection = record
    Snapshot: TLibrarySnapshot;
    RootRevision: Integer;
  end;

  TDeckSource = record
    Bytes: RawByteString;
    LibraryRevision: Integer;
    ModifiedUTC: string;
    DeckVersion: string;
    CommentPrefix: string;
    SourcePath: string;
    Deleted: Boolean;
  end;

  TDeckListEntry = record
    Name, DeckVersion: string;
  end;
  TDeckListEntries = array of TDeckListEntry;

  TVersionDeckEntry = record
    Name, DeckVersion, ModifiedUTC: string;
    Deleted: Boolean;
  end;
  TVersionDeckEntries = array of TVersionDeckEntry;

  TDeckHistoryEntry = record
    DeckVersion, ModifiedUTC: string;
    Deleted: Boolean;
  end;
  TDeckHistoryEntries = array of TDeckHistoryEntry;


implementation


end.
