import Foundation
import Testing
@testable import LocalSendKit

/// Direct unit coverage for ``UploadStagingArea`` in isolation from the full server runtime.
///
/// `NetworkRuntimeCoverageTests.stagingDirectoryIsAHiddenSaveFolderSubdirectorySweptOnStartupAndShutdown`
/// already exercises the startup/shutdown sweep end-to-end through `LocalSendServerRuntime`. What
/// is missing there is a test of the type's own safety invariant in isolation: `isStagingDirectory`
/// is the only thing standing between a mis-wired caller handing `sweep`/`prepare` the SAVE
/// directory itself, and every user file in it being deleted. That guard deserves a test that does
/// not depend on spinning up TLS/HTTP infrastructure to exercise.
struct UploadStagingAreaTests {
    private func makeTempDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UploadStagingAreaTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func urlInsideAppendsTheHiddenStagingDirectoryName() {
        let storageDirectory = makeTempDirectory()
        let staging = UploadStagingArea.url(inside: storageDirectory)
        #expect(staging.lastPathComponent == ".localdrop-staging")
        #expect(staging.deletingLastPathComponent().standardizedFileURL.path == storageDirectory.standardizedFileURL.path)
    }

    @Test func isStagingDirectoryIsTrueOnlyForThatExactComponentName() {
        let storageDirectory = makeTempDirectory()
        #expect(UploadStagingArea.isStagingDirectory(UploadStagingArea.url(inside: storageDirectory)))
        // The save directory itself — the exact shape a mis-wired caller would pass — must NOT
        // read as a staging directory.
        #expect(UploadStagingArea.isStagingDirectory(storageDirectory) == false)
        #expect(UploadStagingArea.isStagingDirectory(storageDirectory.appendingPathComponent("Documents")) == false)
        #expect(UploadStagingArea.isStagingDirectory(storageDirectory.appendingPathComponent(".localdrop-staging-decoy")) == false)
        // A staging directory nested somewhere unexpected still reads as one by name alone —
        // `isStagingDirectory` only judges the last path component, matching `sweep`'s contract.
        #expect(UploadStagingArea.isStagingDirectory(storageDirectory.appendingPathComponent("nested/.localdrop-staging")))
    }

    /// The core anti-data-loss guarantee: sweeping a path that is not really a staging directory —
    /// even if it happens to be the caller's save directory, full of real user files — must be a
    /// silent no-op, never a deletion.
    @Test func sweepIsANoOpForAnythingThatIsNotAStagingDirectory() throws {
        let storageDirectory = makeTempDirectory()
        let userFile = storageDirectory.appendingPathComponent("family-photo.jpg")
        try Data("precious".utf8).write(to: userFile)
        let userSubdirectory = storageDirectory.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: userSubdirectory, withIntermediateDirectories: true)
        try Data("report".utf8).write(to: userSubdirectory.appendingPathComponent("report.pdf"))

        // A mis-wired caller hands the save directory itself to sweep(at:).
        UploadStagingArea.sweep(at: storageDirectory)

        #expect(FileManager.default.fileExists(atPath: userFile.path), "sweep must never delete a non-staging directory's contents")
        #expect(FileManager.default.fileExists(atPath: userSubdirectory.appendingPathComponent("report.pdf").path))
        #expect(FileManager.default.fileExists(atPath: storageDirectory.path), "sweep must never delete a non-staging directory itself")
    }

    @Test func sweepRemovesAGenuineStagingDirectoryAndEverythingInIt() throws {
        let storageDirectory = makeTempDirectory()
        let staging = UploadStagingArea.url(inside: storageDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128).write(to: staging.appendingPathComponent(UUID().uuidString))
        try Data(repeating: 2, count: 128).write(to: staging.appendingPathComponent(UUID().uuidString))

        UploadStagingArea.sweep(at: staging)

        #expect(FileManager.default.fileExists(atPath: staging.path) == false)
        // The save directory itself, one level up, is untouched.
        #expect(FileManager.default.fileExists(atPath: storageDirectory.path))
    }

    /// `try?` inside `sweep` — a staging directory that was already swept, or never created, must
    /// not throw or crash a second sweep.
    @Test func sweepOfANonexistentStagingDirectoryIsSafe() {
        let storageDirectory = makeTempDirectory()
        let staging = UploadStagingArea.url(inside: storageDirectory)
        #expect(FileManager.default.fileExists(atPath: staging.path) == false)
        UploadStagingArea.sweep(at: staging)
        UploadStagingArea.sweep(at: staging)
        #expect(FileManager.default.fileExists(atPath: staging.path) == false)
    }

    /// `prepare(at:)` is sweep-then-create: an orphan left by a crashed previous run must be gone,
    /// and the directory must exist and be empty afterwards, ready for the next upload to stage into.
    @Test func prepareSweepsOrphansThenRecreatesAnEmptyDirectory() throws {
        let storageDirectory = makeTempDirectory()
        let staging = UploadStagingArea.url(inside: storageDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let orphan = staging.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 9, count: 4096).write(to: orphan)

        UploadStagingArea.prepare(at: staging)

        #expect(FileManager.default.fileExists(atPath: orphan.path) == false, "prepare must clear crash orphans before recreating")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: staging.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    /// Calling `prepare(at:)` twice in a row (e.g. two rapid settings changes building fresh
    /// runtime nodes) must not throw or leave the directory in a bad state.
    @Test func prepareIsIdempotent() throws {
        let storageDirectory = makeTempDirectory()
        let staging = UploadStagingArea.url(inside: storageDirectory)

        UploadStagingArea.prepare(at: staging)
        try Data("mid-session".utf8).write(to: staging.appendingPathComponent(UUID().uuidString))
        UploadStagingArea.prepare(at: staging)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: staging.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    /// `prepare(at:)` on a path that is NOT a staging directory must still create the directory
    /// (the `createDirectory` half is unconditional), but the sweep half must not have wiped
    /// anything, since `sweep` guards on `isStagingDirectory` first.
    @Test func prepareOnANonStagingPathCreatesItWithoutSweepingExistingContent() throws {
        let storageDirectory = makeTempDirectory()
        let plainSubdirectory = storageDirectory.appendingPathComponent("not-staging")
        try FileManager.default.createDirectory(at: plainSubdirectory, withIntermediateDirectories: true)
        let preexisting = plainSubdirectory.appendingPathComponent("keep-me.txt")
        try Data("keep".utf8).write(to: preexisting)

        UploadStagingArea.prepare(at: plainSubdirectory)

        #expect(FileManager.default.fileExists(atPath: preexisting.path), "prepare must not sweep a directory that is not named .localdrop-staging")
    }
}
