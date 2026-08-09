import Foundation

public enum ReceiveSessionStatus: String, Codable, Sendable {
    case waiting
    case transferring
    case finished
    case canceled
    case failed
    /// Every file reached a terminal state and at least one failed, but at least one also
    /// succeeded. Unlike `.failed` this is NOT a teardown: the session and its per-file tokens are
    /// RETAINED so the sender can retry just the files that failed.
    ///
    /// Mirrors the reference's `SessionStatus.finishedWithErrors`, which appears alongside
    /// `sending` in `_uploadHandler`'s `allowedStates` precisely so a retry POST is accepted
    /// (`receive_controller.dart`: "in case it was finishedWithErrors and user retries a failed
    /// file").
    case finishedWithErrors
}

/// Where one file of a receive session has got to.
///
/// Tracked explicitly because the alternative — inferring completion by `stat`-ing the
/// destination — is synchronous I/O inside an actor, and it silently misreports if the user (or
/// anything else) removes a destination while the session is still open.
public enum ReceivedFileStatus: String, Codable, Sendable {
    case queued
    case transferring
    case completed
    case failed

    /// Terminal for the purposes of deciding whether a session as a whole is finished.
    public var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

public struct ReceivedFileRecord: Equatable, Sendable {
    public var file: FileDto
    public var token: String
    public var destinationURL: URL
    public var status: ReceivedFileStatus

    public init(
        file: FileDto,
        token: String,
        destinationURL: URL,
        status: ReceivedFileStatus = .queued
    ) {
        self.file = file
        self.token = token
        self.destinationURL = destinationURL
        self.status = status
    }
}

public struct ReceiveSessionSnapshot: Equatable, Sendable {
    public var sessionId: String
    public var senderIP: String
    public var senderInfo: RegisterInfo
    public var files: [String: ReceivedFileRecord]
    public var status: ReceiveSessionStatus
    public var bytesReceived: Int64
    public var totalBytes: Int64
    public var currentFileID: String?
    public var currentFileBytesReceived: Int64
    public var currentFileTotalBytes: Int64?
    /// Files whose upload failed and which the sender may retry. Derived from the per-file
    /// statuses so there is exactly one source of truth — it was a stored set until per-file
    /// status tracking landed, and two parallel records of "what failed" would inevitably drift.
    public var failedFileIDs: Set<String> {
        Set(files.filter { $0.value.status == .failed }.keys)
    }

    public init(
        sessionId: String,
        senderIP: String,
        senderInfo: RegisterInfo,
        files: [String: ReceivedFileRecord],
        status: ReceiveSessionStatus,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = 0,
        currentFileID: String? = nil,
        currentFileBytesReceived: Int64 = 0,
        currentFileTotalBytes: Int64? = nil
    ) {
        self.sessionId = sessionId
        self.senderIP = senderIP
        self.senderInfo = senderInfo
        self.files = files
        self.status = status
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.currentFileID = currentFileID
        self.currentFileBytesReceived = currentFileBytesReceived
        self.currentFileTotalBytes = currentFileTotalBytes
    }
}

public enum PrepareUploadPolicy: Equatable, Sendable {
    case acceptAll
    case reject
    case acceptOnly(Set<String>)
    case messageOnly
}

public enum PrepareUploadOutcome: Equatable, Sendable {
    case accepted(PrepareUploadResponse)
    case rejected
    case blocked
    case noTransferNeeded
}

public enum ReceiveSessionError: Error, Equatable {
    /// A path needed as a directory is occupied by a file (a batch containing both `a` and
    /// `a/b.txt`), or the directory could not be created. Surfaced as an explicit, logged 500.
    case destinationDirectoryUnavailable
}

public enum UploadFileResult: Equatable, Sendable {
    case success
    case missingParameters
    case forbidden
    case blocked
}

public actor ReceiveSession {
    private var current: ReceiveSessionSnapshot?
    private var lastFinished: ReceiveSessionSnapshot?
    private var pendingRequest: IncomingTransferRequest?

    public init() {}

    public func prepare(
        request: PrepareUploadRequest,
        senderIP: String,
        policy: PrepareUploadPolicy,
        incomingRequestBridge: IncomingTransferRequestBridge? = nil,
        destinationDirectory: URL,
        sessionIdFactory: @Sendable () -> String,
        tokenFactory: @Sendable (String) -> String
    ) async throws -> PrepareUploadOutcome {
        guard request.files.isEmpty == false else {
            return .noTransferNeeded
        }

        // A `.finishedWithErrors` session is retained on purpose (so failed files can be retried),
        // which would otherwise make it block EVERY later transfer with a 409 forever — there is no
        // session timeout anywhere. A brand-new `prepare` is unambiguous evidence the sender has
        // moved on, so the retained session is superseded rather than honoured.
        if current?.status == .finishedWithErrors {
            lastFinished = current
            current = nil
        }

        guard current == nil, pendingRequest == nil else {
            return .blocked
        }

        let decision: IncomingTransferDecision
        if let incomingRequestBridge {
            let bridgeRequest = IncomingTransferRequest(
                senderIP: senderIP,
                info: request.info,
                files: request.files
            )
            pendingRequest = bridgeRequest
            decision = await incomingRequestBridge.awaitDecision(for: bridgeRequest)
            // `ReceiveSession` is an actor but it is REENTRANT across the await above — the actor
            // is not blocked while the prompt is on screen, which is what makes a network-side
            // cancel possible at all, and also what made the old unconditional
            // `pendingRequest = nil` unsafe in two ways:
            //
            //  - Lost cancel: a cancel landing after the bridge resumed but before this line was
            //    reached used to be silently dropped, and `prepare` would then create a session
            //    for a sender that had already torn down. There is no session timeout anywhere,
            //    so that session blocked every later transfer with a 409 forever.
            //  - Wiped successor: a cancel clears `pendingRequest`, the sender retries, a new
            //    `prepare` installs its own `pendingRequest`, and this line used to wipe it —
            //    defeating the `guard current == nil, pendingRequest == nil` block-guard and
            //    leaving two prompts live.
            //
            // So: only clear the pending request if it is still ours, and if our token was
            // invalidated while we were suspended, reject regardless of what the bridge returned.
            guard pendingRequest?.id == bridgeRequest.id else {
                return .rejected
            }
            pendingRequest = nil
            guard current == nil else {
                return .blocked
            }
        } else {
            decision = Self.decision(for: policy)
        }

        switch decision {
        case .reject:
            current = nil
            return .rejected
        case .noTransferNeeded:
            current = nil
            return .noTransferNeeded
        case .acceptAll, .acceptOnly:
            break
        }

        // A message is not a file. The reference detects a request consisting of a single text file
        // that carries a `preview` (`ReceiveSessionState.message`) and, on accept, "accepts
        // nothing": the selection comes back empty, `prepare-upload` answers 204, and the text is
        // written to receive HISTORY instead of to disk.
        //
        // Enforced here, below the decision, rather than at the call site: no policy — not
        // `.acceptAll`, not a future auto-accept rule — may cause unseen text to be written to the
        // user's save folder. The app layer is what records the history entry; this actor is
        // storage-only and has no history to write to.
        //
        // `FileDto.isMessagePayload` is the SAME predicate the quick-save auto-accept gate already
        // uses (`TransferFeatureStore.disposition(for:)`), so the two cannot drift.
        if Self.isMessageRequest(request) {
            current = nil
            return .noTransferNeeded
        }

        let acceptedIDs: Set<String>
        /// fileID -> receiver-chosen name. Untrusted; see `effectiveFileName(for:desiredName:)`.
        let desiredNames: [String: String]
        switch decision {
        case .acceptAll:
            acceptedIDs = Set(request.files.keys)
            desiredNames = [:]
        case .acceptOnly(let ids, let names):
            acceptedIDs = ids.intersection(request.files.keys)
            desiredNames = names
        case .reject, .noTransferNeeded:
            acceptedIDs = []
            desiredNames = [:]
        }

        if acceptedIDs.isEmpty {
            current = nil
            return .noTransferNeeded
        }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let sessionId = sessionIdFactory()
        var records: [String: ReceivedFileRecord] = [:]
        var tokens: [String: String] = [:]

        // Destinations are resolved here, at prepare time, rather than at upload time as the
        // reference does. The reference-equivalent of "the session survives, one bad file fails"
        // is therefore to EXCLUDE the offending fileID from `records`/`tokens`: a missing token is
        // well defined to senders ("the receiver skipped it"), and `acceptedIDs.isEmpty` already
        // yields the 204. Failing a whole 500-file folder over one bad name is too harsh, and
        // silently rewriting a `..` is worse — the user would believe they received what was sent.
        //
        // Names that collide — with another file in the same batch, with a directory this batch
        // needs, or with something already on disk — are RENAMED (`report (2).pdf`), not dropped.
        // Dropping was defensible only while every destination carried a unique `sessionId-fileID-`
        // prefix and a collision therefore meant a genuinely ambiguous name; now that files save
        // under their real name, dropping would silently lose a file the user was told they
        // received. Folding is unchanged (APFS is case- and normalization-insensitive, so two
        // distinct fileIDs can land on the same inode without their paths comparing equal).
        //
        // A receiver-supplied `desiredName` simply REPLACES the sender's `fileName` at the top of
        // this pipeline — it is not a separate, later, weaker rewrite. Everything below (the
        // `..`/absolute-path rejection, the illegal-character legalization, the `NAME_MAX` budget,
        // the reserved-directory set and the ` (2)` probe) therefore applies identically to both
        // origins, and a user typing `../../etc/passwd` is dropped exactly like a malicious sender
        // sending it.
        var claimedDestinationKeys: Set<String> = []
        let effectiveFileNames = acceptedIDs.sorted().compactMap { fileID -> String? in
            guard let file = request.files[fileID] else { return nil }
            return Self.effectiveFileName(for: file, desiredName: desiredNames[fileID])
        }
        let reservedDirectoryKeys = Self.reservedDirectoryKeys(
            fileNames: effectiveFileNames,
            destinationDirectory: destinationDirectory
        )
        for fileID in acceptedIDs.sorted() {
            guard let file = request.files[fileID] else {
                continue
            }
            guard let destinationURL = Self.resolveDestination(
                fileName: Self.effectiveFileName(for: file, desiredName: desiredNames[fileID]),
                destinationDirectory: destinationDirectory,
                claimedDestinationKeys: &claimedDestinationKeys,
                reservedDirectoryKeys: reservedDirectoryKeys
            ) else {
                continue
            }
            let token = tokenFactory(fileID)
            records[fileID] = ReceivedFileRecord(file: file, token: token, destinationURL: destinationURL)
            tokens[fileID] = token
        }

        if records.isEmpty {
            current = nil
            return .noTransferNeeded
        }

        let snapshot = ReceiveSessionSnapshot(
            sessionId: sessionId,
            senderIP: senderIP,
            senderInfo: request.info,
            files: records,
            status: .waiting,
            bytesReceived: 0,
            totalBytes: records.values.reduce(0) { $0 + $1.file.size }
        )
        current = snapshot
        return .accepted(PrepareUploadResponse(sessionId: sessionId, files: tokens))
    }

    public func beginUpload(
        sessionId: String?,
        fileId: String?,
        token: String?,
        senderIP: String
    ) -> Bool {
        guard let sessionId, let fileId, let token else {
            return false
        }
        guard var snapshot = current else {
            return false
        }
        guard snapshot.sessionId == sessionId, snapshot.senderIP == senderIP else {
            return false
        }
        guard Self.acceptsUploads(snapshot.status) else {
            return false
        }
        guard let fileRecord = snapshot.files[fileId], fileRecord.token == token else {
            return false
        }

        snapshot.status = .transferring
        snapshot.currentFileID = fileId
        snapshot.currentFileBytesReceived = 0
        snapshot.currentFileTotalBytes = fileRecord.file.size
        // A retry of a previously failed file re-enters here; clearing the per-file status is what
        // takes it back out of `failedFileIDs`.
        snapshot.files[fileId]?.status = .transferring
        current = snapshot
        return true
    }

    public func expectedByteCount(
        sessionId: String?,
        fileId: String?,
        senderIP: String
    ) -> Int64? {
        guard let sessionId, let fileId else {
            return nil
        }
        guard let snapshot = current,
              snapshot.sessionId == sessionId,
              snapshot.senderIP == senderIP,
              let fileRecord = snapshot.files[fileId] else {
            return nil
        }
        return fileRecord.file.size
    }

    public func updateUploadProgress(
        sessionId: String?,
        fileId: String?,
        senderIP: String,
        bytesReceived: Int64
    ) -> Bool {
        guard let sessionId, let fileId else {
            return false
        }
        guard var snapshot = current else {
            return false
        }
        guard snapshot.sessionId == sessionId, snapshot.senderIP == senderIP else {
            return false
        }
        guard Self.acceptsUploads(snapshot.status) else {
            return false
        }
        guard let fileRecord = snapshot.files[fileId] else {
            return false
        }

        let completedBytes = completedBytesExcludingCurrentFile(in: snapshot, currentFileID: fileId)
        let clampedCurrentBytes = max(0, min(bytesReceived, fileRecord.file.size))
        snapshot.status = .transferring
        snapshot.currentFileID = fileId
        snapshot.currentFileTotalBytes = fileRecord.file.size
        snapshot.currentFileBytesReceived = clampedCurrentBytes
        snapshot.bytesReceived = min(snapshot.totalBytes, completedBytes + clampedCurrentBytes)
        current = snapshot
        return true
    }

    public func upload(
        sessionId: String?,
        fileId: String?,
        token: String?,
        senderIP: String,
        body: HTTPRequestBody
    ) throws -> UploadFileResult {
        guard let sessionId, let fileId, let token else {
            return .missingParameters
        }
        guard var snapshot = current else {
            return .blocked
        }
        guard snapshot.sessionId == sessionId, snapshot.senderIP == senderIP else {
            return .forbidden
        }
        guard Self.acceptsUploads(snapshot.status) else {
            return .blocked
        }
        guard let fileRecord = snapshot.files[fileId], fileRecord.token == token else {
            return .forbidden
        }

        let completedBytes = completedBytesExcludingCurrentFile(in: snapshot, currentFileID: fileId)
        snapshot.status = .transferring
        snapshot.currentFileID = fileId
        snapshot.currentFileTotalBytes = fileRecord.file.size
        snapshot.currentFileBytesReceived = fileRecord.file.size
        snapshot.bytesReceived = min(snapshot.totalBytes, completedBytes + fileRecord.file.size)
        snapshot.files[fileId]?.status = .transferring
        try Self.stage(body: body, to: fileRecord.destinationURL)

        // This file is on disk now. Recording it on the record itself is what clears a previous
        // failure for it — a retry that clears the last outstanding failure brings the session
        // back to `.finished`.
        snapshot.files[fileId]?.status = .completed

        let allExist = snapshot.files.values.allSatisfy { $0.status == .completed }
        if allExist {
            snapshot.status = .finished
            snapshot.currentFileID = nil
            snapshot.currentFileBytesReceived = 0
            snapshot.currentFileTotalBytes = nil
            snapshot.bytesReceived = snapshot.totalBytes
            lastFinished = snapshot
            current = nil
        } else if snapshot.files.values.contains(where: { $0.status == .failed }),
                  snapshot.files.values.allSatisfy({ $0.status.isTerminal }) {
            // Everything is terminal again but some files are still failed — back to
            // `finishedWithErrors`, tokens retained for a further retry.
            snapshot.status = .finishedWithErrors
            snapshot.currentFileID = nil
            snapshot.currentFileBytesReceived = 0
            snapshot.currentFileTotalBytes = nil
            current = snapshot
            lastFinished = snapshot
        } else {
            current = snapshot
        }

        return .success
    }

    public func upload(
        sessionId: String?,
        fileId: String?,
        token: String?,
        senderIP: String,
        body: Data
    ) throws -> UploadFileResult {
        try upload(
            sessionId: sessionId,
            fileId: fileId,
            token: token,
            senderIP: senderIP,
            body: .data(body)
        )
    }

    /// Withdraws an accept/decline prompt that is still in flight, on behalf of a `/cancel` from
    /// the pending sender's IP.
    ///
    /// The reference receiver (`receive_controller.dart:638-671`) does not check `sessionId` at
    /// all while status is `waiting` — the sender's IP alone authorizes. We have no session yet at
    /// that point (ours is allocated only after the decision), so the pending request's sender IP
    /// is the equivalent match.
    ///
    /// `pendingRequest` is cleared *before* the await on the bridge, so the ownership check is
    /// atomic with respect to the reentrant `prepare` that is suspended on the other side.
    public func withdrawPendingRequest(
        senderIP: String,
        incomingRequestBridge: IncomingTransferRequestBridge?
    ) async -> Bool {
        guard let pending = pendingRequest, pending.senderIP == senderIP else {
            return false
        }
        pendingRequest = nil
        if let incomingRequestBridge {
            await incomingRequestBridge.withdraw(requestID: pending.id)
        }
        return true
    }

    /// Cancels the live session on behalf of the sender that owns it — the `/cancel` route. The
    /// sender IP has to match, so a stray cancel from a shared-NAT or spoofed peer cannot kill an
    /// in-flight transfer belonging to someone else.
    public func cancel(sessionId: String, senderIP: String) -> Bool {
        applyCancel(sessionId: sessionId, senderIP: senderIP)
    }

    /// Cancels the live session on behalf of the LOCAL user (the receive-side cancel button).
    ///
    /// No sender-IP authorization: this request did not arrive over the network, and the receiving
    /// user is always entitled to stop a transfer into their own machine. Notifying the sender is
    /// the caller's job — this actor is transport-free by design.
    public func cancelLocally(sessionId: String) -> Bool {
        applyCancel(sessionId: sessionId, senderIP: nil)
    }

    /// `senderIP == nil` means "locally authorized"; a non-nil value must match the session's.
    private func applyCancel(sessionId: String, senderIP: String?) -> Bool {
        guard var snapshot = current else {
            return false
        }
        guard snapshot.sessionId == sessionId else {
            return false
        }
        if let senderIP, snapshot.senderIP != senderIP {
            return false
        }
        // NOT `acceptsUploads`: a `.finishedWithErrors` session is terminal, and the reference
        // rejects a cancel for anything but `waiting`/`sending`
        // (`_cancelHandler`: `if (currentStatus != waiting && currentStatus != sending) → 403`).
        guard snapshot.status == .waiting || snapshot.status == .transferring else {
            return false
        }
        snapshot.status = .canceled
        snapshot.currentFileID = nil
        snapshot.currentFileBytesReceived = 0
        snapshot.currentFileTotalBytes = nil
        lastFinished = snapshot
        current = nil
        return true
    }

    public func failUpload(
        sessionId: String?,
        fileId: String?,
        senderIP: String
    ) -> Bool {
        guard let sessionId else {
            return false
        }
        guard var snapshot = current else {
            return false
        }
        guard snapshot.sessionId == sessionId, snapshot.senderIP == senderIP else {
            return false
        }
        if let fileId, snapshot.currentFileID == nil {
            snapshot.currentFileID = fileId
        }
        guard Self.acceptsUploads(snapshot.status) else {
            return false
        }

        // Record WHICH file failed rather than tearing the session down. The old behaviour
        // (`status = .failed; current = nil`) discarded every per-file token, so the sender's only
        // recovery was to re-send the entire batch — the reference instead keeps the session alive
        // in `finishedWithErrors` and accepts a retry POST for just the failed file.
        let failedFileID = fileId ?? snapshot.currentFileID
        if let failedFileID, snapshot.files[failedFileID] != nil {
            snapshot.files[failedFileID]?.status = .failed
        }
        snapshot.currentFileBytesReceived = 0
        snapshot.currentFileTotalBytes = snapshot.currentFileID.flatMap { snapshot.files[$0]?.file.size }

        // A session where NOTHING succeeded stays a whole-session `.failed`: there is no partial
        // result worth retaining, and the UI's terminal-failure path depends on it.
        let succeededCount = snapshot.files.values.filter { $0.status == .completed }.count
        let pendingCount = snapshot.files.values.filter { $0.status.isTerminal == false }.count

        if pendingCount > 0 {
            // Other files are still in flight; stay transferring and let them finish.
            snapshot.status = .transferring
            snapshot.currentFileID = nil
            current = snapshot
            return true
        }

        if succeededCount == 0 {
            snapshot.status = .failed
            lastFinished = snapshot
            current = nil
            return true
        }

        snapshot.status = .finishedWithErrors
        snapshot.currentFileID = nil
        // Retained, not moved to `lastFinished`: the per-file tokens in `current` are exactly what
        // a retry upload has to match. `prepare` supersedes it when the sender moves on.
        current = snapshot
        lastFinished = snapshot
        return true
    }

    /// Statuses in which a session still accepts an upload for one of its files.
    ///
    /// `finishedWithErrors` is included for the retry case — the reference's `allowedStates`
    /// (`{sending, finishedWithErrors}`) exists for exactly this reason.
    private static func acceptsUploads(_ status: ReceiveSessionStatus) -> Bool {
        switch status {
        case .waiting, .transferring, .finishedWithErrors:
            return true
        case .finished, .canceled, .failed:
            return false
        }
    }

    public func snapshot() -> ReceiveSessionSnapshot? {
        current ?? lastFinished
    }

    /// The id of the LIVE session only — never `lastFinished`. Used to fill in the session id a v1
    /// `/send` or `/cancel` does not carry; resolving to a finished session would let a stale v1
    /// request act on a transfer that is already over.
    public func currentSessionId() -> String? {
        current?.sessionId
    }

    /// The protocol version the live session's sender advertised, for the v1-cancel guard.
    public func currentSenderVersion() -> String? {
        current?.senderInfo.version
    }

    public func pendingIncomingRequest() -> IncomingTransferRequest? {
        pendingRequest
    }

    /// Whether a `prepare-upload` request is a "message request" rather than a file transfer.
    ///
    /// Mirrors `ReceiveSessionState.message` (`receive_session_state.dart`): exactly one file,
    /// which is a text file carrying a `preview`. Two text files, or one text file with no
    /// `preview` at all, are ordinary documents and take the normal write-to-disk path.
    public static func isMessageRequest(_ request: PrepareUploadRequest) -> Bool {
        guard request.files.count == 1, let file = request.files.values.first else {
            return false
        }
        return file.isMessagePayload
    }

    private static func decision(for policy: PrepareUploadPolicy) -> IncomingTransferDecision {
        switch policy {
        case .acceptAll:
            return .acceptAll
        case .reject:
            return .reject
        case .acceptOnly(let acceptedIDs):
            return .acceptOnly(acceptedIDs, desiredNames: [:])
        case .messageOnly:
            return .noTransferNeeded
        }
    }

    private static func stage(body: HTTPRequestBody, to destinationURL: URL) throws {
        // Intermediate directories are created HERE rather than in `prepare`, so a rejected or
        // canceled transfer never leaves an empty directory tree behind. The failure mode this
        // introduces is a *file* already occupying a path a later file needs as a directory
        // (`a` and `a/b.txt` in the same batch); `createDirectory` throws there, and without this
        // mapping it would surface as the runtime's anonymous 500.
        let parentDirectory = destinationURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw ReceiveSessionError.destinationDirectoryUnavailable
        }

        switch body {
        case .data(let data):
            // Already atomic: `.atomic` writes a sibling temp file and renames it into place.
            try data.write(to: destinationURL, options: .atomic)
        case .file(let sourceURL, _):
            // MOVE, never copy. The source lives in `UploadStagingArea` — a hidden subdirectory of
            // this very destination root, therefore the same volume — so this is a true atomic
            // rename: the destination is never observable half-written, and no staging file
            // survives a successful transfer. A copy left both a growing destination (which the
            // completion checks below mistake for a finished file, breaking parallel uploads) and
            // a full-size orphan behind.
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                // `moveItem` refuses to clobber. An occupied destination is legitimate (a retried
                // upload, or a file that appeared after prepare-time collision resolution), and
                // `replaceItemAt` is the atomic form of overwrite.
                guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw error
                }
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: sourceURL)
            }
        }
    }

    /// `FileManager.fileExists(atPath:)` returns `true` for a directory. A batch containing both
    /// `a` (a file) and `a/b.txt` therefore let the directory `a` satisfy the existence check for
    /// the *file* `a`.
    ///
    /// No longer used to infer SESSION state — per-file `ReceivedFileStatus` does that, without
    /// blocking I/O and without being fooled by a destination that disappears underneath us. What
    /// remains here is genuinely a filesystem question: "is this path already occupied", asked by
    /// the collision probe in `resolveDestination`.
    private static func regularFileExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue == false
    }

    private func completedBytesExcludingCurrentFile(
        in snapshot: ReceiveSessionSnapshot,
        currentFileID: String
    ) -> Int64 {
        snapshot.files.reduce(into: Int64.zero) { partialResult, item in
            guard item.key != currentFileID else { return }
            if item.value.status == .completed {
                partialResult += item.value.file.size
            }
        }
    }

    /// The name a file is saved under: the receiver's `desiredName` when one was supplied, the
    /// sender's `fileName` otherwise.
    ///
    /// Only *emptiness* is decided here — a name that is empty or nothing but whitespace would
    /// sanitize down to an empty component, which `destinationPlan` rejects, silently dropping a
    /// file the user meant to keep; falling back to the sender's name is the honest outcome. Every
    /// other judgement about the name (separators, `..`, illegal characters, length) is left to the
    /// shared sanitizer, so there is exactly one place where a name becomes a path.
    static func effectiveFileName(for file: FileDto, desiredName: String?) -> String {
        guard let desiredName,
              desiredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return file.fileName
        }
        return desiredName
    }

    // MARK: - Destination resolution (folder transfers + path traversal)

    private static let maximumPathComponentBytes = 255

    /// How far the ` (n)` collision probe counts before the file is dropped. Bounded so a
    /// pathological batch cannot turn one `prepare` into an unbounded `stat` loop.
    static let maximumCollisionSuffix = 999

    /// Reserved out of `NAME_MAX` *before* truncation, not after. Truncating to the full 255 bytes
    /// first and appending ` (17)` afterwards is how a maximally long name ends up over the limit.
    private static let collisionSuffixReservedBytes = " (\(maximumCollisionSuffix))".utf8.count

    /// Characters that cannot appear in a single path component. `/` and `\` are handled earlier
    /// by the split; the rest are legalized by replacement (as the reference's `legalizeFilename`
    /// does) rather than causing a rejection.
    private static let illegalComponentScalars = Set<Unicode.Scalar>(":*?\"<>|\\".unicodeScalars)

    /// The sanitized shape of a sender-supplied `fileName`, or `nil` if the name must be rejected.
    ///
    /// Unlike the reference (`file_saver.dart:236-258`) the traversal guard runs for EVERY name,
    /// not only ones containing a separator — the reference's `isWithin` check sits inside
    /// `if (fileNameParts.length > 1)`, so a bare `fileName: ".."` skips validation entirely.
    static func destinationPlan(fileName: String) -> (directories: [String], leaf: String)? {
        // Benign shapes are sanitized: backslash separators, leading `/`, `./`, empty components.
        let rawComponents = fileName
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }

        // Anything else is rejected, not rewritten.
        guard rawComponents.isEmpty == false, rawComponents.contains("..") == false else {
            return nil
        }

        let directoryComponents = rawComponents
            .dropLast()
            .map(sanitizedComponent(_:))
            .filter { $0.isEmpty == false }
        let leaf = sanitizedComponent(rawComponents[rawComponents.count - 1])
        guard leaf.isEmpty == false else {
            return nil
        }
        return (directoryComponents, leaf)
    }

    /// Every directory path a whole batch will need, folded. Computed up front so that a plain file
    /// colliding with a sibling's *directory* (`a` and `a/b.txt` in one batch) is suffixed rather
    /// than left to fail at stage time — directories keep their name, files yield.
    static func reservedDirectoryKeys(
        fileNames: [String],
        destinationDirectory: URL
    ) -> Set<String> {
        var keys: Set<String> = []
        for fileName in fileNames {
            guard let plan = destinationPlan(fileName: fileName) else {
                continue
            }
            var url = destinationDirectory
            for component in plan.directories {
                url.appendPathComponent(component)
                keys.insert(collisionKey(for: url))
            }
        }
        return keys
    }

    /// Convenience for callers that resolve a single name in isolation.
    static func resolveDestination(fileName: String, destinationDirectory: URL) -> URL? {
        var claimedDestinationKeys: Set<String> = []
        return resolveDestination(
            fileName: fileName,
            destinationDirectory: destinationDirectory,
            claimedDestinationKeys: &claimedDestinationKeys
        )
    }

    /// Maps a sender-supplied `fileName` (which may carry a relative directory path, for folder
    /// transfers) onto a free destination under `destinationDirectory`, or returns `nil` if the
    /// name must be rejected.
    ///
    /// Files are saved under their real name — there is no `sessionId-fileID-` prefix — so
    /// uniqueness has to be established explicitly. The probe walks ` (2)`, ` (3)`, … and checks
    /// the in-batch claims and the filesystem in the SAME iteration: checking them in separate
    /// passes lets `name (2)` be claimed by the set while `name (2)` also exists on disk.
    static func resolveDestination(
        fileName: String,
        destinationDirectory: URL,
        claimedDestinationKeys: inout Set<String>,
        reservedDirectoryKeys: Set<String> = []
    ) -> URL? {
        guard let plan = destinationPlan(fileName: fileName) else {
            return nil
        }

        // Budget first, truncate second. `truncate` is handed a limit that already excludes the
        // widest suffix the probe can append, so `name (999).ext` still fits `NAME_MAX`.
        let available = maximumPathComponentBytes - collisionSuffixReservedBytes
        guard available > 0 else {
            return nil
        }
        let truncatedLeaf = truncate(plan.leaf, toUTF8ByteCount: available)

        // The staging area lives *inside* the save directory, so it is genuinely under the root and
        // passes every containment check. A sender-supplied `.localdrop-staging/x.txt` (or the same
        // as a user-typed `desiredName`) would therefore resolve to a destination that the next
        // `UploadStagingArea.prepare`/`sweep` deletes — after the session already reported success.
        // Reject rather than suffix: a name that resolves into our private scratch space is not a
        // collision to work around, it is a name we will not honour.
        let stagingKey = collisionKey(for: UploadStagingArea.url(inside: destinationDirectory))

        // Two parallel walks: `directoryURL` is the path the file is actually created at (the one
        // the user sees), `resolvedDirectoryURL` is the same path with symlinks resolved and is used
        // only to decide containment.
        //
        // `standardizedFileURL` collapses `.`/`..` lexically only — it does NOT resolve symlinks, so
        // a pre-existing `X -> /Volumes/Other` in the save folder let `X/file.txt` pass a textual
        // prefix test and be written outside the save root, on another volume, where the final
        // `moveItem` degrades to copy-then-unlink and the destination grows in place.
        //
        // Resolution has to happen component by component: `resolvingSymlinksInPath()` gives up and
        // returns its input unchanged when the last component does not exist yet, which the leaf of
        // a not-yet-created destination never does.
        var directoryURL = destinationDirectory
        var resolvedDirectoryURL = destinationDirectory.standardizedFileURL.resolvingSymlinksInPath()
        for component in plan.directories {
            directoryURL.appendPathComponent(component)
            guard collisionKey(for: directoryURL) != stagingKey else {
                return nil
            }
            // A no-op for a component that does not exist yet — which is correct: a path that is not
            // there cannot be a symlink to somewhere else.
            resolvedDirectoryURL = resolvedDirectoryURL
                .appendingPathComponent(component)
                .resolvingSymlinksInPath()
        }

        // Belt and braces on top of the `..` rejection above: whatever we built must still resolve
        // to a path strictly under the destination root.
        var root = destinationDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if root.hasSuffix("/") == false {
            root += "/"
        }

        for attempt in 1...maximumCollisionSuffix {
            let component = applyingCollisionSuffix(attempt, to: truncatedLeaf)
            let candidate = directoryURL.appendingPathComponent(component)
            let resolvedCandidate = resolvedDirectoryURL
                .appendingPathComponent(component)
                .resolvingSymlinksInPath()
            guard resolvedCandidate.standardizedFileURL.path.hasPrefix(root) else {
                return nil
            }
            let key = collisionKey(for: candidate)
            guard claimedDestinationKeys.contains(key) == false,
                  reservedDirectoryKeys.contains(key) == false,
                  // A *leaf* that lands on the staging directory is only a name clash, so it takes
                  // the ` (n)` suffix like any other occupant rather than being rejected. Listed
                  // explicitly because the directory may not exist on disk at this instant.
                  key != stagingKey,
                  // Any occupant blocks, not just a regular file: a directory sitting on the path
                  // cannot be overwritten by a file either.
                  FileManager.default.fileExists(atPath: candidate.path) == false else {
                continue
            }
            claimedDestinationKeys.insert(key)
            return candidate
        }
        return nil
    }

    /// APFS is case-insensitive and Unicode-normalization-insensitive, so two distinct fileIDs can
    /// land on the same inode without their paths comparing equal. Fold both before comparing.
    private static func collisionKey(for url: URL) -> String {
        url.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `report.pdf` -> `report (2).pdf`. The counter goes BEFORE the extension; `report.pdf (2)`
    /// would strip the file of its type as far as every opener is concerned.
    private static func applyingCollisionSuffix(_ attempt: Int, to name: String) -> String {
        guard attempt > 1 else {
            return name
        }
        let nsName = name as NSString
        let fileExtension = nsName.pathExtension
        let suffix = fileExtension.isEmpty ? "" : "." + fileExtension
        let base = suffix.isEmpty ? name : nsName.deletingPathExtension
        return "\(base) (\(attempt))\(suffix)"
    }

    private static func sanitizedComponent(_ raw: String) -> String {
        var sanitized = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            illegalComponentScalars.contains(scalar) || scalar.value < 0x20 ? Unicode.Scalar(UInt8(0x5F)) : scalar
        }))
        while let last = sanitized.last, last == "." || last == " " {
            sanitized.removeLast()
        }
        return sanitized
    }

    /// `NAME_MAX` is a byte limit on what the filesystem stores, and both APFS and HFS+ store
    /// path components decomposed. Measuring the precomposed form would under-count by a byte per
    /// accented character and let a name slip past the limit.
    private static func componentByteLength(_ value: String) -> Int {
        value.decomposedStringWithCanonicalMapping.utf8.count
    }

    /// Truncates to fit `NAME_MAX` while preserving the extension, so a long basename from a
    /// folder tree does not throw mid-transfer with no recovery. Truncation is on character
    /// boundaries — cutting mid-scalar would produce an unrepresentable name.
    private static func truncate(_ name: String, toUTF8ByteCount limit: Int) -> String {
        guard componentByteLength(name) > limit else {
            return name
        }
        let nsName = name as NSString
        let fileExtension = nsName.pathExtension
        var suffix = fileExtension.isEmpty ? "" : "." + fileExtension
        if componentByteLength(suffix) >= limit {
            suffix = ""
        }
        let base = suffix.isEmpty ? name : nsName.deletingPathExtension

        var result = ""
        var usedBytes = 0
        let budget = limit - componentByteLength(suffix)
        for character in base {
            let characterBytes = componentByteLength(String(character))
            if usedBytes + characterBytes > budget {
                break
            }
            result.append(character)
            usedBytes += characterBytes
        }

        let truncated = result + suffix
        return truncated.isEmpty ? "file" : truncated
    }
}

public enum SendSessionStatus: String, Codable, Sendable {
    case waiting
    case finished
    case canceled
}

public enum DownloadSource: Equatable, Sendable {
    case data(Data)
    case file(URL, byteCount: Int64)
}

public struct LocalSharedFile: Equatable, Sendable {
    public var file: FileDto
    public var source: DownloadSource

    public init(file: FileDto, source: DownloadSource) {
        self.file = file
        self.source = source
    }

    public func loadData() throws -> Data {
        switch source {
        case .data(let data):
            return data
        case .file(let url, _):
            return try Data(contentsOf: url)
        }
    }

    public var responseBody: HTTPResponseBody {
        switch source {
        case .data(let data):
            return .data(data)
        case .file(let url, let byteCount):
            return .file(url, byteCount: byteCount)
        }
    }
}

public struct SendSessionSnapshot: Equatable, Sendable {
    public var sessionId: String
    public var requesterIP: String
    public var files: [String: LocalSharedFile]
    public var status: SendSessionStatus

    public init(sessionId: String, requesterIP: String, files: [String: LocalSharedFile], status: SendSessionStatus) {
        self.sessionId = sessionId
        self.requesterIP = requesterIP
        self.files = files
        self.status = status
    }
}

public enum PrepareDownloadOutcome: Equatable, Sendable {
    case accepted(PrepareDownloadResponse)
    case rejected
}

public actor SendSession {
    private var sessionsByID: [String: SendSessionSnapshot] = [:]

    public init() {}

    public func prepare(
        requesterIP: String,
        localInfo: InfoResponse,
        files: [String: LocalSharedFile],
        allow: Bool
    ) -> PrepareDownloadOutcome {
        guard allow else {
            return .rejected
        }

        let sessionId = requesterIP
        if let existing = sessionsByID[sessionId], existing.status == .waiting {
            let responseFiles = Dictionary(uniqueKeysWithValues: existing.files.map { ($0.key, $0.value.file) })
            return .accepted(PrepareDownloadResponse(info: localInfo, sessionId: sessionId, files: responseFiles))
        }

        let snapshot = SendSessionSnapshot(
            sessionId: sessionId,
            requesterIP: requesterIP,
            files: files,
            status: .waiting
        )
        sessionsByID[sessionId] = snapshot
        let responseFiles = Dictionary(uniqueKeysWithValues: files.map { ($0.key, $0.value.file) })
        return .accepted(PrepareDownloadResponse(info: localInfo, sessionId: sessionId, files: responseFiles))
    }

    public func download(sessionId: String, fileId: String, requesterIP: String) throws -> LocalSharedFile? {
        guard let snapshot = sessionsByID[sessionId], snapshot.requesterIP == requesterIP, snapshot.status == .waiting else {
            return nil
        }
        guard let sharedFile = snapshot.files[fileId] else {
            return nil
        }

        var finished = snapshot
        finished.status = .finished
        sessionsByID[sessionId] = finished
        return sharedFile
    }

    public func cancel(sessionId: String, requesterIP: String) -> Bool {
        guard let snapshot = sessionsByID[sessionId], snapshot.requesterIP == requesterIP else {
            return false
        }
        guard snapshot.status == .waiting else {
            return false
        }
        sessionsByID.removeValue(forKey: sessionId)
        return true
    }

    public func snapshot(sessionId: String) -> SendSessionSnapshot? {
        sessionsByID[sessionId]
    }

    public func snapshots() -> [SendSessionSnapshot] {
        sessionsByID.values.sorted { $0.sessionId < $1.sessionId }
    }
}
