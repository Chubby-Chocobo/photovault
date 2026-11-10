import Foundation
import PhotoVaultEngine

/// The menu bar shows live information only. A one-time job (backfill, or an import from a folder,
/// Google Drive or Dropbox) is there while any of its work remains, whether it is still reading or
/// only uploading, and leaves for good once it has finished. Both cards use this one rule.
public enum PopoverJobVisibility {
    public static func shows(finished: Bool) -> Bool { !finished }

    /// Some asset with a backfill job is still unfinished.
    public static func shows(backfill snapshot: EngineSnapshot) -> Bool {
        shows(finished: snapshot.backfillTotalAssets <= snapshot.backfillDoneAssets)
    }

    /// An import is open until every file was read and every upload of it ended (`SourceStatus.isOpen`).
    public static func shows(importJob item: ImportSnapshot) -> Bool { shows(finished: item.isFinished) }
}
