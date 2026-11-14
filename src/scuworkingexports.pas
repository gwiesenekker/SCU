unit ScuWorkingExports;

{$mode objfpc}{$H+}

interface


uses
  ScuSQLite, ScuExportTypes;

// Queue in the same transaction as the deck revision and audit outcome.
procedure QueueWorkingExport(Database: TSQLiteLibrary; const Entry: TExportRecord; Removed: Boolean = False);
// The caller must hold the library-directory output lock and an open transaction.
procedure RefreshWorkingExports(Database: TSQLiteLibrary; const LibraryPath: string);

implementation


uses
  SysUtils, ScuCodec, ScuFiles, ScuSQLiteDB, ScuExportManifest;

procedure QueueWorkingExport(Database: TSQLiteLibrary; const Entry: TExportRecord; Removed: Boolean);
var
  Statement: TSQLiteStatement;
begin
  Statement := Database.Prepare('INSERT OR REPLACE INTO pending_working_exports ' +
    '(file_key, file_name, deck_name, library_version, deck_version, sha256, removed) VALUES (?, ?, ?, ?, ?, ?, ?)');
  try
    Statement.Bind(1, AuditSHA256(Entry.FileName));
    Statement.Bind(2, Entry.FileName);
    Statement.Bind(3, Entry.Deck);
    Statement.Bind(4, Entry.LibraryVersion);
    Statement.Bind(5, Entry.DeckVersion);
    Statement.Bind(6, Entry.SHA256);
    Statement.Bind(7, Ord(Removed));
    Statement.Step;
  finally
    Statement.Free;
  end;
end;

procedure RefreshWorkingExports(Database: TSQLiteLibrary; const LibraryPath: string);
var
  Manifest: TExportManifest;
  Statement: TSQLiteStatement;
  Entry: TExportRecord;
  Name: RawByteString;
  Started: Boolean;
begin
  Statement := Database.Prepare('SELECT file_name, deck_name, library_version, deck_version, sha256, removed ' +
    'FROM pending_working_exports ORDER BY file_key');
  Manifest := nil;
  Started := False;
  try
    while Statement.Step do
    begin
      if not Started then
      begin
        Manifest := TExportManifest.Create(ExtractFileDir(CanonicalFile(LibraryPath)));
        Manifest.Recover;
        Started := True;
      end;
      Entry := Default(TExportRecord);
      Name := Statement.Text[0];
      SetCodePage(Name, CP_UTF8, False);
      Entry.FileName := Name;
      Entry.LibraryPath := CanonicalFile(LibraryPath);
      Entry.Deck := Statement.Text[1];
      Entry.LibraryVersion := Statement.Text[2];
      Entry.DeckVersion := Statement.Text[3];
      Entry.SHA256 := Statement.Text[4];
      Entry.Mode := emExtract;
      Manifest.Observe(Entry, Statement.Integers[5] <> 0);
    end;
    if Started then Manifest.SaveObservations;
  finally
    Manifest.Free;
    Statement.Free;
  end;
  // If the process dies before this commit, replaying is safe and idempotent.
  if Started then Database.Execute('DELETE FROM pending_working_exports');
end;

end.
