import Foundation

/// The staging area incoming upload bodies are streamed into before they are renamed onto their
/// final destination.
///
/// It is deliberately a hidden subdirectory *of the user's save directory* rather than the system
/// temporary directory. `FileManager.moveItem` does not fail across volumes — it silently degrades
/// to copy-then-unlink — so staging on the boot volume while the save location sits on an external
/// or network volume would produce a destination file that grows in place. A destination that grows
/// in place is exactly what `ReceiveSession`'s "does the destination exist yet?" completion checks
/// mistake for a finished file, which prematurely flips a session with parallel `/upload`s (allowed
/// by protocol §4.2) to `.finished` and 409s the uploads still streaming.
///
/// A sibling of the save directory would remove the "sender-supplied name can name the staging
/// area" hazard outright, but it cannot keep the same-volume property that the rename depends on:
/// when the save directory is itself a volume root or mount point (`/Volumes/USB`) its sibling
/// (`/Volumes/.localdrop-staging`) is on the boot volume, and when it is the user's home directory
/// the sibling (`/Users/.localdrop-staging`) is not writable at all. So staging stays a child, and
/// `ReceiveSession.resolveDestination` refuses any incoming name that resolves into it.
///
/// What is actually guaranteed: a path that is *lexically* under the save directory is on the same
/// volume as the destination **as long as no component of it is a symlink or mount point**. A
/// symlink crossing to another volume defeats it, which is why destination resolution compares
/// `resolvingSymlinksInPath()` on both sides and rejects anything that escapes. Within that
/// guarantee the final `moveItem` is a true atomic rename and a partial file is never observable;
/// outside it `moveItem` silently degrades to copy-then-unlink, which is the bug above.
public enum UploadStagingArea {
    /// Hidden so it does not clutter the user's save folder while a transfer is in flight.
    public static let directoryName = ".localdrop-staging"

    public static func url(inside storageDirectory: URL) -> URL {
        storageDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Guards every destructive operation here. A staging area is only ever swept if it really is
    /// one — a mis-wired runtime handed the save directory itself must not have it emptied.
    public static func isStagingDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL.lastPathComponent == directoryName
    }

    /// Sweeps orphans left by a previous run, then (re)creates the directory.
    ///
    /// The startup sweep is not redundant with the shutdown sweep: a crash or `SIGKILL` never runs
    /// shutdown, and `LocalSendRuntimeAdapter.updateSettings` builds a brand-new node on every
    /// settings change, so without it each toggle could strand a full-size body.
    public static func prepare(at url: URL) {
        sweep(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Removes the staging directory and everything in it. A no-op for anything that is not a
    /// staging directory.
    public static func sweep(at url: URL) {
        guard isStagingDirectory(url) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}
