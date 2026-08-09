import AppKit
import AppLogging
import Dispatch
import Foundation
import Observation

@MainActor
@Observable
final class TransferFeatureStore {
    var screen: Screen = .receive
    var quickSave: QuickSaveMode
    var appearance: AppearanceSetting
    var accentColor: AccentColorChoice
    var language: LanguageSetting
    var minimizeToMenuBar: Bool
    var launchAtLogin: Bool
    var reduceMotion: Bool
    var autoAcceptFavorites: Bool
    var sendMode: SendMode
    var shareViaLinkAutoAccept: Bool
    var deviceName: String
    var port: String
    var saveLocation: String
    var requirePIN: Bool
    var incomingPIN: String
    var allowDownloads: Bool
    var useHTTPS: Bool
    var isRuntimeAvailable = false
    var runtimeStatusText: String
    var nearbyPeers: [NearbyPeerItem] = []
    var stagedItems: [StagedTransferItem] = []
    var historyEntries: [HistoryEntry]
    var favorites: [FavoriteDevice]
    var incomingRequest: IncomingTransferRequest?
    /// The sender-side PIN prompt currently on screen, if any.
    var pinPrompt: SendPINPrompt?
    /// The transfer the detail sheet is showing — the most recently updated one.
    var activeTransfer: ActiveTransferProgress?

    /// Every transfer currently in flight, keyed by id.
    ///
    /// `activeTransfer` alone was sufficient only while one transfer could exist at a time. Now
    /// that sends to several devices run concurrently, showing just the newest would silently hide
    /// a transfer that is still running — so the in-flight list is rendered from this instead.
    /// Terminal entries are removed as they settle.
    private(set) var activeTransfersByID: [String: ActiveTransferProgress] = [:]

    /// In-flight transfers for display, oldest first so a running transfer does not jump position
    /// when another one updates.
    var inFlightTransfers: [ActiveTransferProgress] {
        activeTransfersByID.values
            .sorted { lhs, rhs in
                if lhs.startedAtMonotonic == rhs.startedAtMonotonic {
                    return lhs.id < rhs.id
                }
                return lhs.startedAtMonotonic < rhs.startedAtMonotonic
            }
    }

    /// Whether the in-flight list is worth showing at all — with one transfer the existing detail
    /// view already says everything the list would.
    var hasConcurrentTransfers: Bool {
        activeTransfersByID.count > 1
    }

    var feedback: TransferFeedback?
    var isRefreshingDiscovery = false
    var isScanningDiscovery = false
    var lastErrorMessage: String?
    private let runtime: any TransferRuntime
    private let settingsPersistence: any TransferSettingsPersisting
    private let historyPersistence: any HistoryPersisting
    private let favoritesPersistence: any FavoritesPersisting
    private let loginItemManaging: any LoginItemManaging
    private let logger: AppLogger
    private let progressReducer = TransferProgressReducer()
    private let progressThrottleIntervalNanoseconds: UInt64
    static let maxHistoryEntries = 200
    private var runtimeStatusKey = "runtime.starting"
    private var hasStarted = false
    @ObservationIgnored
    nonisolated(unsafe) private var observationTasks: [Task<Void, Never>] = []
    @ObservationIgnored
    nonisolated(unsafe) private var progressCompletionTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var feedbackDismissTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var pendingProgressEmissionTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var pendingProgressSnapshot: ActiveTransferProgress?
    @ObservationIgnored
    nonisolated(unsafe) private var authoritativeActiveTransfer: ActiveTransferProgress?
    /// Request IDs whose withdrawal arrived before the request itself.
    ///
    /// The inbound-request stream and the withdrawal stream are consumed by two independent tasks with
    /// no ordering guarantee between them, so a sender that cancels immediately can have its withdrawal
    /// observed first. Without this, `withdrawIncomingRequest(id:)` would find nothing to clear and the
    /// request task would then prompt for — or auto-accept — an already-dead request.
    /// Bounded so a peer spamming withdrawals for IDs that never arrive cannot grow it without limit.
    @ObservationIgnored
    private var withdrawnRequestIDs: [String] = []
    private static let maxTrackedWithdrawnRequestIDs = 32
    @ObservationIgnored
    nonisolated(unsafe) private var autoAcceptResponseTasks: [UUID: Task<Void, Never>] = [:]
    /// Suspends the in-flight `/prepare-upload` retry loop while the PIN sheet is up.
    ///
    /// The submitted PIN travels through this continuation's resumption value and nowhere else —
    /// it is never assigned to a stored property.
    @ObservationIgnored
    private var pinPromptContinuation: CheckedContinuation<String?, Never>?

    /// MainActor-isolated read-only view of the two task collections, for tests only.
    ///
    /// The storage itself stays `private` + `nonisolated(unsafe)`: the "unsafe" is only sound
    /// because every access is inside this file, on the MainActor (plus `deinit`). Exposing the
    /// arrays would hand out a nonisolated getter on MainActor-mutated state and void that
    /// invariant, so tests observe the derived facts instead.
    var hasActiveObservationTasks: Bool {
        observationTasks.isEmpty == false
    }

    var hasPendingAutoAcceptTasks: Bool {
        autoAcceptResponseTasks.isEmpty == false
    }

    init(
        runtime: any TransferRuntime,
        settingsPersistence: any TransferSettingsPersisting,
        historyPersistence: any HistoryPersisting,
        favoritesPersistence: any FavoritesPersisting = InMemoryFavoritesPersistence(),
        loginItemManaging: any LoginItemManaging,
        snapshot: TransferSettingsSnapshot,
        progressThrottleIntervalNanoseconds: UInt64 = 0,
        logger: AppLogger = .disabled()
    ) {
        self.runtime = runtime
        self.settingsPersistence = settingsPersistence
        self.historyPersistence = historyPersistence
        self.favoritesPersistence = favoritesPersistence
        self.loginItemManaging = loginItemManaging
        self.logger = logger
        self.progressThrottleIntervalNanoseconds = progressThrottleIntervalNanoseconds
        self.quickSave = snapshot.quickSave
        self.appearance = snapshot.appearance
        self.accentColor = snapshot.accentColor
        self.language = snapshot.language
        self.minimizeToMenuBar = snapshot.minimizeToMenuBar
        self.launchAtLogin = snapshot.launchAtLogin
        self.reduceMotion = snapshot.reduceMotion
        self.autoAcceptFavorites = snapshot.autoAcceptFavorites
        self.sendMode = snapshot.sendMode
        self.shareViaLinkAutoAccept = snapshot.shareViaLinkAutoAccept
        self.deviceName = LocalDeviceIdentity.normalizedCustomName(snapshot.protocolSettings.deviceName)
            ?? LocalDeviceIdentity.systemName()
        self.port = String(snapshot.protocolSettings.tcpPort)
        self.saveLocation = snapshot.protocolSettings.saveLocation.path
        self.requirePIN = snapshot.protocolSettings.requirePIN
        self.incomingPIN = snapshot.protocolSettings.incomingPIN
        self.allowDownloads = snapshot.protocolSettings.allowDownloads
        self.useHTTPS = snapshot.protocolSettings.useHTTPS
        self.historyEntries = historyPersistence.load()
        self.favorites = favoritesPersistence.load()
        self.runtimeStatusText = FeatureTransferLocalization.string(forKey: "runtime.starting")
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
        autoAcceptResponseTasks.values.forEach { $0.cancel() }
        progressCompletionTask?.cancel()
        feedbackDismissTask?.cancel()
        pendingProgressEmissionTask?.cancel()
    }

    var activeSheet: ActiveSheet? {
        if incomingRequest != nil {
            return .incoming
        }
        if pinPrompt != nil {
            return .pinEntry
        }
        if activeTransfer != nil {
            return .progress
        }
        return nil
    }

    /// Resolves the sheet the user actually dismissed — and only that one.
    ///
    /// `activeSheet` prioritises `.incoming`, so an inbound request arriving while the sender-side
    /// PIN sheet is up preempts it. Resolving every non-nil state on a single dismissal would then
    /// also cancel that live PIN prompt, whose continuation resolves nil and discards the user's
    /// whole staged outbound batch behind a generic "canceled" toast.
    func dismissActiveSheet() {
        switch activeSheet {
        case .incoming:
            declineIncomingRequest()
        case .pinEntry:
            // Dismissing the PIN sheet is the same decision as tapping Cancel in it.
            cancelSendPIN()
        case .progress:
            dismissProgress()
        case nil:
            break
        }
    }

    var waitingIdentifier: String {
        let source = resolvedDeviceName.isEmpty ? "LD" : resolvedDeviceName
        return String(source.prefix(2)).uppercased()
    }

    var currentProtocolSettings: TransferProtocolSettings {
        TransferProtocolSettings(
            deviceName: resolvedDeviceName,
            tcpPort: Int(port) ?? 53317,
            requirePIN: requirePIN,
            incomingPIN: resolvedIncomingPIN,
            allowDownloads: allowDownloads,
            useHTTPS: useHTTPS,
            saveLocation: URL(fileURLWithPath: saveLocation)
        )
    }

    func start() async {
        guard hasStarted == false else { return }
        hasStarted = true
        bindRuntimeStreamsIfNeeded()
        setRuntimeStatus("runtime.starting")
        let runtimeStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        logger.emit(
            level: .info,
            event: "app.runtime.start.requested",
            scope: "TransferFeatureStore",
            attributes: [
                .string("app.screen", screen.rawValue),
                .bool("settings.use_https", useHTTPS)
            ]
        )

        do {
            try await runtime.start()
            isRuntimeAvailable = true
            setRuntimeStatus("runtime.discoverable")
            logger.emit(
                level: .info,
                event: "app.runtime.discoverable",
                scope: "TransferFeatureStore",
                attributes: [
                    .string("result", "success"),
                    .string("runtime.status", runtimeStatusText),
                    .double(
                        "startup.runtime_start_elapsed_ms",
                        Self.elapsedMilliseconds(since: runtimeStartUptimeNanoseconds)
                    )
                ]
            )
        } catch {
            isRuntimeAvailable = false
            setRuntimeStatus("runtime.unavailable")
            recordError(event: "app.runtime.start.failed", error: error)
        }
    }

    func refreshLocalizedStatusText() {
        runtimeStatusText = FeatureTransferLocalization.string(forKey: runtimeStatusKey)
    }

    private func setRuntimeStatus(_ key: String) {
        runtimeStatusKey = key
        runtimeStatusText = FeatureTransferLocalization.string(forKey: key)
    }

    func stop() async {
        cancelProgressCompletionTask()
        // Never leave the send loop suspended on a sheet that is about to disappear.
        resolvePINPrompt(with: nil)
        activeTransfer = nil
        logger.emit(level: .info, event: "app.runtime.stop.requested", scope: "TransferFeatureStore")
        // Shut the runtime down BEFORE tearing the observers down: the runtime emits terminal
        // progress/withdrawal events while stopping, and cancelling the observation tasks first
        // would drop them on the floor.
        await runtime.stop()
        cancelObservationAndAutoAcceptTasks()
        // Without this, `start()`'s `guard hasStarted == false` short-circuits the next start and
        // `bindRuntimeStreamsIfNeeded()` never re-subscribes — the store would stay permanently
        // deaf to requests, progress and peers after a stop/start cycle.
        hasStarted = false
        logger.emit(level: .info, event: "app.runtime.stop.completed", scope: "TransferFeatureStore")
        await logger.flush()
    }

    func refreshNearbyPeers() {
        refreshDiscovery(shouldShowFeedback: true, scan: false)
    }

    func scanNearbyPeers() {
        refreshDiscovery(shouldShowFeedback: true, scan: true)
    }

    private func refreshDiscovery(shouldShowFeedback: Bool, scan: Bool) {
        logger.emit(
            level: .info,
            event: scan ? "discovery.scan.requested" : "discovery.refresh.requested",
            scope: "TransferFeatureStore",
            attributes: [
                .string("event.domain", "discovery"),
                .string("event.action", scan ? "scan" : "refresh")
            ]
        )
        if scan {
            isScanningDiscovery = true
        } else {
            isRefreshingDiscovery = true
        }
        Task {
            await runtime.refreshDiscovery()
            if scan {
                isScanningDiscovery = false
            } else {
                isRefreshingDiscovery = false
            }
            if shouldShowFeedback {
                showFeedback(
                    TransferFeedback(
                        message: scan
                            ? FeatureTransferLocalization.string(forKey: "feedback.discoveryScanStarted")
                            : FeatureTransferLocalization.string(forKey: "feedback.discoveryRefreshed"),
                        symbol: scan ? "dot.radiowaves.left.and.right" : "arrow.clockwise",
                        tone: .neutral
                    )
                )
            }
        }
    }

    func stageDroppedItems(_ urls: [URL]) {
        let staged = urls.map(Self.makeStagedItem(url:))
        stagedItems = staged
        logger.emit(
            level: .info,
            event: "transfer.stage.completed",
            scope: "TransferFeatureStore",
            attributes: [
                .int("transfer.file_count", staged.count),
                .string("transfer.direction", "sending")
            ]
        )
        Task {
            await runtime.stage(staged)
        }
        showFeedback(
            TransferFeedback(
                message: staged.count == 1
                    ? FeatureTransferLocalization.string(forKey: "feedback.fileStaged")
                    : FeatureTransferLocalization.format("feedback.itemsStaged", staged.count),
                symbol: "checkmark.circle.fill",
                tone: .success
            )
        )
    }

    func removeStagedItem(id: StagedTransferItem.ID) {
        stagedItems.removeAll { $0.id == id }
        logger.emit(
            level: .info,
            event: "transfer.stage.item_removed",
            scope: "TransferFeatureStore",
            attributes: [
                .string("transfer.file_id", id),
                .int("transfer.file_count", stagedItems.count)
            ]
        )
        Task {
            await runtime.stage(stagedItems)
        }
    }

    func send(to peerID: NearbyPeerItem.ID) {
        guard stagedItems.isEmpty == false else {
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.sendRequiresStagedItems"),
                    symbol: "tray.fill",
                    tone: .pending
                )
            )
            return
        }
        logger.emit(
            level: .info,
            event: "transfer.send.requested",
            scope: "TransferFeatureStore",
            attributes: [
                .string("peer.id", peerID),
                .int("transfer.file_count", stagedItems.count)
            ]
        )
        Task {
            do {
                await runtime.stage(stagedItems)
                // No PIN up front — LocalDrop never persists one. The runtime asks via `requestPIN`
                // if and only if the recipient answers 401, and retries inside this one call.
                try await runtime.sendStagedItems(
                    to: peerID,
                    pin: nil,
                    requestPIN: { [weak self] context in
                        guard let self else { return nil }
                        return await self.requestSendPIN(context)
                    }
                )
            } catch {
                recordError(event: "transfer.send.failed", error: error)
            }
        }
    }

    // MARK: - Sender PIN prompt

    /// Presents the PIN sheet and suspends until the user submits or dismisses it.
    ///
    /// Called from the runtime's `/prepare-upload` retry loop, so every retry is a deliberate user
    /// submission — nothing here retries on its own, which matters because the receiver locks out
    /// after three wrong non-empty PINs.
    private func requestSendPIN(_ context: TransferPINPromptContext) async -> String? {
        // A second request while one is live can only mean the first was abandoned; resolve it as
        // canceled rather than stranding its continuation.
        resolvePINPrompt(with: nil)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            pinPromptContinuation = continuation
            pinPrompt = SendPINPrompt(
                peerName: peerDisplayName(forID: context.peerID, fallback: context.peerName),
                isFirstAttempt: context.isFirstAttempt
            )
        }
    }

    /// Hands the submitted PIN to the waiting retry. The value is never logged and never stored.
    func submitSendPIN(_ candidate: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let prompt = pinPrompt else { return }
        logger.emit(
            level: .notice,
            event: "transfer.send.pin_submitted",
            scope: "TransferFeatureStore",
            attributes: [.bool("transfer.pin_first_attempt", prompt.isFirstAttempt)]
        )
        resolvePINPrompt(with: trimmed)
    }

    /// Dismissing the prompt discards the send: the runtime drops the held batch and reports no
    /// failure, and the staged list is cleared here so the UI agrees.
    func cancelSendPIN() {
        guard pinPrompt != nil else { return }
        logger.emit(
            level: .notice,
            event: "transfer.send.pin_prompt_canceled",
            scope: "TransferFeatureStore"
        )
        resolvePINPrompt(with: nil)
        stagedItems.removeAll()
        showFeedback(
            TransferFeedback(
                message: FeatureTransferLocalization.string(forKey: "feedback.transferCanceled"),
                symbol: "xmark.circle",
                tone: .neutral
            )
        )
    }

    private func resolvePINPrompt(with pin: String?) {
        pinPrompt = nil
        guard let continuation = pinPromptContinuation else { return }
        pinPromptContinuation = nil
        continuation.resume(returning: pin)
    }

    private func peerDisplayName(forID id: NearbyPeerItem.ID, fallback: String) -> String {
        guard let peer = nearbyPeers.first(where: { $0.id == id }) else { return fallback }
        return displayName(for: peer)
    }

    func selectSendMode(_ mode: SendMode) {
        if mode == .link, stagedItems.isEmpty {
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.linkRequiresStagedItems"),
                    symbol: "link.badge.plus",
                    tone: .pending
                )
            )
            return
        }
        sendMode = mode
        persistSettings()
    }

    // MARK: - Favorites

    func isFavorite(fingerprint: String) -> Bool {
        favorite(fingerprint: fingerprint) != nil
    }

    func favorite(fingerprint: String) -> FavoriteDevice? {
        let normalized = FavoriteDevice.normalizedFingerprint(fingerprint)
        guard normalized.isEmpty == false else { return nil }
        return favorites.first { $0.fingerprint == normalized }
    }

    func isFavorite(_ peer: NearbyPeerItem) -> Bool {
        isFavorite(fingerprint: peer.fingerprint)
    }

    /// Name to render for a discovered peer: a favorite's `aliasOverride` wins over the alias the
    /// peer announced, otherwise the announced alias is used unchanged.
    func displayName(for peer: NearbyPeerItem) -> String {
        favorite(fingerprint: peer.fingerprint)?.displayName(fallback: peer.name) ?? peer.name
    }

    /// Adds or removes the favorite for `fingerprint` and persists the result.
    /// Returns whether the device is favorited after the toggle.
    @discardableResult
    func toggleFavorite(fingerprint: String, lastKnownAlias: String = "") -> Bool {
        let normalized = FavoriteDevice.normalizedFingerprint(fingerprint)
        guard normalized.isEmpty == false else { return false }

        let isFavoritedAfterToggle: Bool
        if let index = favorites.firstIndex(where: { $0.fingerprint == normalized }) {
            favorites.remove(at: index)
            isFavoritedAfterToggle = false
        } else {
            favorites.append(
                FavoriteDevice(fingerprint: normalized, aliasOverride: nil, lastKnownAlias: lastKnownAlias)
            )
            isFavoritedAfterToggle = true
        }
        favoritesPersistence.save(favorites)
        logger.emit(
            level: .info,
            event: isFavoritedAfterToggle ? "settings.favorite.added" : "settings.favorite.removed",
            scope: "TransferFeatureStore",
            attributes: [
                .string("peer.fingerprint_suffix", String(normalized.suffix(8))),
                .int("settings.favorite_count", favorites.count)
            ]
        )
        return isFavoritedAfterToggle
    }

    @discardableResult
    func toggleFavorite(for peer: NearbyPeerItem) -> Bool {
        toggleFavorite(fingerprint: peer.fingerprint, lastKnownAlias: peer.name)
    }

    /// Name to render for a favorite that may or may not be on the network right now.
    ///
    /// Routed through the same `FavoriteDevice.displayName(fallback:)` rule the device list uses, with
    /// the live announced alias supplied as the fallback when the peer happens to be nearby. A
    /// favorite with no override, no live peer and no cached alias renders a localized placeholder
    /// rather than an empty row.
    func displayName(for favorite: FavoriteDevice) -> String {
        let resolved = favorite.displayName(fallback: liveAlias(forFingerprint: favorite.fingerprint))
        guard resolved.isEmpty == false else {
            return FeatureTransferLocalization.string(forKey: "settings.favorites.unknownDevice")
        }
        return resolved
    }

    /// Alias the peer with this fingerprint is announcing right now, or `""` when it is not nearby.
    private func liveAlias(forFingerprint fingerprint: String) -> String {
        let normalized = FavoriteDevice.normalizedFingerprint(fingerprint)
        return nearbyPeers.first {
            FavoriteDevice.normalizedFingerprint($0.fingerprint) == normalized
        }?.name ?? ""
    }

    /// Every favorite, in a stable order: display name first (case- and diacritic-insensitive), then
    /// fingerprint as the tie-break so two devices sharing an alias never swap places between reads.
    ///
    /// This is the only user-reachable inventory of favorites. Discovery cannot supply it: a device
    /// that is gone for good never reappears in `nearbyPeers`, yet its persisted auto-accept grant
    /// survives every relaunch.
    var sortedFavorites: [FavoriteListItem] {
        favorites
            .map { favorite in
                FavoriteListItem(
                    fingerprint: favorite.fingerprint,
                    displayName: displayName(for: favorite),
                    shortFingerprint: FavoriteDevice.shortFingerprint(favorite.fingerprint)
                )
            }
            .sorted { lhs, rhs in
                switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    return lhs.fingerprint < rhs.fingerprint
                }
            }
    }

    /// Sets (or clears) a favorite's user-chosen display name.
    ///
    /// `aliasOverride` has existed on the model, in persistence and in the `displayName(for:)`
    /// render path since favorites shipped, but nothing could ever set it — `toggleFavorite`
    /// hardcodes `nil` and there was no rename affordance. This is that missing setter.
    ///
    /// Passing `nil`, an empty string, or whitespace CLEARS the override, so the favorite goes back
    /// to showing whatever the device announces. That is the only way back, so it must not be
    /// treated as invalid input.
    ///
    /// Returns whether a favorite was actually updated.
    @discardableResult
    func renameFavorite(fingerprint: String, alias: String?) -> Bool {
        let normalized = FavoriteDevice.normalizedFingerprint(fingerprint)
        guard
            normalized.isEmpty == false,
            let index = favorites.firstIndex(where: { $0.fingerprint == normalized })
        else {
            return false
        }

        // Rebuilt through the initializer rather than assigning the property directly, so the
        // alias goes through the same trim/empty-to-nil normalization as every other entry point.
        let existing = favorites[index]
        favorites[index] = FavoriteDevice(
            fingerprint: existing.fingerprint,
            aliasOverride: alias,
            lastKnownAlias: existing.lastKnownAlias
        )
        favoritesPersistence.save(favorites)
        logger.emit(
            level: .info,
            event: favorites[index].aliasOverride == nil
                ? "settings.favorite.alias_cleared"
                : "settings.favorite.renamed",
            scope: "TransferFeatureStore",
            attributes: [.string("peer.fingerprint_suffix", String(normalized.suffix(8)))]
        )
        return true
    }

    /// The override currently set for a favorite, or `nil`. Used to pre-fill the rename field so
    /// the user edits their existing name instead of starting from an empty box.
    func aliasOverride(forFingerprint fingerprint: String) -> String? {
        favorite(fingerprint: fingerprint)?.aliasOverride
    }

    /// Refreshes each favorite's cached `lastKnownAlias` from the peers currently on the network.
    ///
    /// It was written once, at star time, and never updated — so a device that was renamed by its
    /// owner kept rendering its old name forever once it went offline. Only a non-empty live alias
    /// overwrites the cache, and only when it actually differs, so this is a no-op in the common
    /// case and never blanks a good cached name with an empty one.
    ///
    /// The user's `aliasOverride` is untouched: this refreshes the *fallback*, not the override.
    private func refreshFavoriteAliases() {
        var didChange = false
        for (index, favorite) in favorites.enumerated() {
            let liveName = liveAlias(forFingerprint: favorite.fingerprint)
            guard liveName.isEmpty == false, liveName != favorite.lastKnownAlias else {
                continue
            }
            favorites[index] = FavoriteDevice(
                fingerprint: favorite.fingerprint,
                aliasOverride: favorite.aliasOverride,
                lastKnownAlias: liveName
            )
            didChange = true
        }
        guard didChange else { return }
        favoritesPersistence.save(favorites)
    }

    /// Drops the favorite for `fingerprint` and persists the removal.
    ///
    /// Unlike ``toggleFavorite(fingerprint:lastKnownAlias:)`` this can never *add* a favorite, so a
    /// double-tap on a revoke button cannot resurrect the auto-accept grant it just destroyed.
    /// Returns whether an entry was actually removed.
    @discardableResult
    func revokeFavorite(fingerprint: String) -> Bool {
        let normalized = FavoriteDevice.normalizedFingerprint(fingerprint)
        guard
            normalized.isEmpty == false,
            let index = favorites.firstIndex(where: { $0.fingerprint == normalized })
        else {
            return false
        }

        favorites.remove(at: index)
        favoritesPersistence.save(favorites)
        logger.emit(
            level: .notice,
            event: "settings.favorite.revoked",
            scope: "TransferFeatureStore",
            attributes: [
                .string("peer.fingerprint_suffix", String(normalized.suffix(8))),
                .int("settings.favorite_count", favorites.count)
            ]
        )
        return true
    }

    // MARK: - Incoming requests

    /// Decides whether an inbound request is answered automatically or shown to the user.
    ///
    /// Lives here rather than in LocalSendKit because it reads user settings; the kit stays
    /// settings-agnostic. `QuickSaveMode.favorites` restricts quick save to favorited senders,
    /// which is why it is not treated as a blanket "on".
    func disposition(for request: IncomingTransferRequest) -> IncomingRequestDisposition {
        let senderIsFavorite = isFavorite(fingerprint: request.senderFingerprint)

        // Auto-accept never applies to a message. The reference gates its quick-save branch on
        // `settings.quickSave && session?.message == null` (`receive_controller.dart:262-263`), so a
        // message payload always reaches the user. Every auto-accept path is exempted — both
        // quick-save branches and auto-accept-from-favorites: a favorited device is still not
        // authorised to write unseen text to disk.
        let isMessage = request.isMessagePayload

        switch quickSave {
        case .on:
            if isMessage == false {
                return .autoAccept(reason: .quickSave)
            }
        case .favorites:
            if senderIsFavorite, isMessage == false {
                return .autoAccept(reason: .quickSaveFavorites)
            }
        case .off:
            break
        }

        if autoAcceptFavorites, senderIsFavorite, isMessage == false {
            return .autoAccept(reason: .favorite)
        }

        return .prompt
    }

    /// Entry point for every inbound request. Auto-accepted requests never touch `incomingRequest`,
    /// so no prompt is presented — not even for a frame.
    func handleIncomingRequest(_ request: IncomingTransferRequest) {
        // Out-of-order withdrawal: the sender already canceled this request before we observed it.
        // Never prompt for it and never auto-accept it.
        if consumeWithdrawal(id: request.id) {
            logger.emit(
                level: .notice,
                event: "transfer.incoming.withdrawn_before_arrival",
                scope: "TransferFeatureStore",
                attributes: [.string("transfer.request_id", request.id)]
            )
            return
        }

        switch disposition(for: request) {
        case .autoAccept(let reason):
            autoAcceptIncomingRequest(request, reason: reason)
        case .prompt:
            incomingRequest = request
            logger.emit(
                level: .info,
                event: "transfer.incoming.prompt_displayed",
                scope: "TransferFeatureStore",
                attributes: [
                    .string("transfer.request_id", request.id),
                    .int("transfer.file_count", request.files.count)
                ]
            )
        }
    }

    /// Accepts through the same path as a user "accept all" so history, progress and runtime
    /// logging behave identically; only the store-side log line differs.
    private func autoAcceptIncomingRequest(_ request: IncomingTransferRequest, reason: AutoAcceptReason) {
        logger.emit(
            level: .info,
            event: "transfer.incoming.auto_accepted",
            scope: "TransferFeatureStore",
            attributes: [
                .string("transfer.request_id", request.id),
                .int("transfer.file_count", request.files.count),
                .string("transfer.accept_source", "auto"),
                .string("transfer.auto_accept_reason", reason.rawValue)
            ]
        )
        showFeedback(
            TransferFeedback(
                message: FeatureTransferLocalization.string(forKey: "feedback.transferAutoAccepted"),
                symbol: "checkmark.circle.fill",
                tone: .success
            )
        )
        // Tracked (unlike the user-driven accept/decline paths) because nobody is watching the screen
        // when this fires: a failure has to reach the log, and store teardown has to cancel it.
        let token = UUID()
        autoAcceptResponseTasks[token] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runtime.respondToIncomingRequest(.acceptAll(requestID: request.id))
            } catch {
                self.logger.emit(
                    level: .error,
                    event: "transfer.incoming.auto_accept_failed",
                    scope: "TransferFeatureStore",
                    attributes: [
                        .string("result", "failure"),
                        .string("transfer.request_id", request.id),
                        .string("transfer.auto_accept_reason", reason.rawValue),
                        .string("error.message", error.localizedDescription),
                        .string("error.type", String(describing: type(of: error)))
                    ]
                )
            }
            self.autoAcceptResponseTasks[token] = nil
        }
    }

    func declineIncomingRequest() {
        guard let request = incomingRequest else { return }
        incomingRequest = nil
        logger.emit(
            level: .notice,
            event: "transfer.incoming.rejected",
            scope: "TransferFeatureStore",
            attributes: [.string("transfer.request_id", request.id)]
        )
        showFeedback(
            TransferFeedback(message: FeatureTransferLocalization.string(forKey: "feedback.transferDeclined"), symbol: "xmark.circle.fill", tone: .destructive)
        )
        for file in request.files {
            appendHistoryEntry(
                HistoryEntry(
                    fileName: file.name,
                    counterpart: request.deviceName,
                    size: file.size,
                    timestamp: Date(),
                    direction: .received,
                    outcome: .declined,
                    fileURL: nil
                )
            )
        }
        Task {
            try? await runtime.respondToIncomingRequest(.reject(requestID: request.id))
        }
    }

    /// The sender canceled while the prompt was still on screen. Deliberately NOT routed through
    /// `declineIncomingRequest()`: that writes a `.declined` history entry per file and shows
    /// "transfer declined" feedback, which would falsify the user's history — they never declined
    /// anything. The bridge has already resolved the awaiting decision, so there is nothing to
    /// respond to either.
    ///
    /// `activeSheet` is derived from `incomingRequest`, so nil-ing it dismisses the sheet with no
    /// view changes and no AppKit.
    func withdrawIncomingRequest(id: String) {
        guard incomingRequest?.id == id else {
            // The request has not been observed yet (or was already resolved). Remember the withdrawal
            // so `handleIncomingRequest(_:)` can drop it if it still arrives.
            rememberWithdrawal(id: id)
            return
        }
        incomingRequest = nil
        logger.emit(
            level: .notice,
            event: "transfer.incoming.withdrawn",
            scope: "TransferFeatureStore",
            attributes: [.string("transfer.request_id", id)]
        )
        showFeedback(
            TransferFeedback(
                message: FeatureTransferLocalization.string(forKey: "feedback.transferCanceled"),
                symbol: "xmark.circle",
                tone: .neutral
            )
        )
    }

    /// Records a withdrawal whose request has not been seen yet, evicting the oldest entry once the
    /// bound is reached.
    private func rememberWithdrawal(id: String) {
        guard id.isEmpty == false, withdrawnRequestIDs.contains(id) == false else { return }
        withdrawnRequestIDs.append(id)
        if withdrawnRequestIDs.count > Self.maxTrackedWithdrawnRequestIDs {
            withdrawnRequestIDs.removeFirst(withdrawnRequestIDs.count - Self.maxTrackedWithdrawnRequestIDs)
        }
    }

    /// Returns `true` when `id` had been withdrawn ahead of time, consuming the record so a later
    /// request reusing the same ID is not swallowed.
    private func consumeWithdrawal(id: String) -> Bool {
        guard let index = withdrawnRequestIDs.firstIndex(of: id) else { return false }
        withdrawnRequestIDs.remove(at: index)
        return true
    }

    func acceptIncomingRequest() {
        guard let request = incomingRequest else { return }
        incomingRequest = nil
        logger.emit(
            level: .info,
            event: "transfer.incoming.accepted",
            scope: "TransferFeatureStore",
            attributes: [
                .string("transfer.request_id", request.id),
                .string("transfer.accept_source", "user")
            ]
        )
        showFeedback(
            TransferFeedback(message: FeatureTransferLocalization.string(forKey: "feedback.transferAccepted"), symbol: "checkmark.circle.fill", tone: .success)
        )
        recordMessageIfNeeded(request)
        Task {
            try? await runtime.respondToIncomingRequest(.acceptAll(requestID: request.id))
        }
    }

    /// Accepting a *message* records it in receive history instead of saving a file.
    ///
    /// The reference does the same (`receive_controller.dart`: `AddHistoryEntryAction(fileName:
    /// message, isMessage: true, path: null)`), and its accept handler then "accepts nothing" so
    /// `prepare-upload` answers 204. `ReceiveSession.prepare` enforces that 204 kit-side regardless
    /// of what we respond with, so the response below stays `.acceptAll` — no second code path, and
    /// no risk of the two disagreeing about what a message is.
    ///
    /// No-op for ordinary file transfers, whose history entries are written on completion by the
    /// progress pipeline.
    /// - Parameter acceptedFileIDs: the subset the user kept, or `nil` for "accept everything".
    ///   A message the user deselected is not a message they received, so it must not be recorded.
    private func recordMessageIfNeeded(_ request: IncomingTransferRequest, acceptedFileIDs: Set<String>? = nil) {
        guard request.isMessagePayload, let messageText = request.messageText else {
            return
        }
        if let acceptedFileIDs, acceptedFileIDs.contains(request.files[0].id) == false {
            return
        }
        appendHistoryEntry(
            HistoryEntry(
                fileName: messageText,
                counterpart: request.deviceName,
                size: ByteCountFormatter.string(
                    fromByteCount: Int64(messageText.utf8.count),
                    countStyle: .file
                ),
                timestamp: Date(),
                direction: .received,
                outcome: .completed,
                fileURL: nil,
                isMessage: true
            )
        )
        logger.emit(
            level: .info,
            event: "transfer.incoming.message_recorded",
            scope: "TransferFeatureStore",
            attributes: [.string("transfer.request_id", request.id)]
        )
    }

    /// - Parameter desiredNames: fileID -> receiver-chosen filename, for the rows the user renamed.
    ///   Entries for files that are not being accepted are dropped here so the log count and the
    ///   payload agree; the names themselves are neither validated nor logged — `LocalSendKit`
    ///   sanitizes them with the same code that sanitizes sender-supplied names.
    func acceptIncomingRequest(fileIDs: Set<String>, desiredNames: [String: String] = [:]) {
        guard let request = incomingRequest else { return }
        incomingRequest = nil
        let acceptedCount = fileIDs.count
        let acceptedDesiredNames = desiredNames.filter { fileIDs.contains($0.key) }
        logger.emit(
            level: .info,
            event: acceptedCount == request.files.count ? "transfer.incoming.accepted" : "transfer.incoming.accepted_subset",
            scope: "TransferFeatureStore",
            attributes: [
                .string("transfer.request_id", request.id),
                .int("transfer.accepted_file_count", acceptedCount),
                .int("transfer.renamed_file_count", acceptedDesiredNames.count)
            ]
        )
        showFeedback(
            TransferFeedback(
                message: acceptedCount == request.files.count
                    ? FeatureTransferLocalization.string(forKey: "feedback.transferAccepted")
                    : FeatureTransferLocalization.format("feedback.filesAccepted", acceptedCount),
                symbol: "checkmark.circle.fill",
                tone: .success
            )
        )
        recordMessageIfNeeded(request, acceptedFileIDs: fileIDs)
        Task {
            try? await runtime.respondToIncomingRequest(
                .acceptSubset(requestID: request.id, fileIDs: fileIDs, desiredNames: acceptedDesiredNames)
            )
        }
    }

    func dismissProgress() {
        cancelProgressCompletionTask()
        activeTransfer = nil
    }

    func cancelActiveTransfer() {
        guard let activeTransfer else { return }
        cancelProgressCompletionTask()
        logger.emit(
            level: .notice,
            event: "transfer.send.canceled",
            scope: "TransferFeatureStore",
            attributes: [.string("transfer.session_id", activeTransfer.id)]
        )
        Task {
            try? await runtime.cancelActiveTransfer(activeTransfer.id)
        }
    }

    func clearHistory() {
        historyEntries.removeAll()
        historyPersistence.save(historyEntries)
    }

    func revealInFinder(_ entry: HistoryEntry) {
        guard let url = resolvedHistoryFileURL(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openHistoryItem(_ entry: HistoryEntry) {
        guard let url = resolvedHistoryFileURL(for: entry) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Returns the on-disk URL for a history entry when it still exists, or
    /// `nil` (surfacing a feedback banner for missing files) so callers can
    /// no-op safely without touching AppKit.
    private func resolvedHistoryFileURL(for entry: HistoryEntry) -> URL? {
        guard let url = entry.fileURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.fileUnavailable"),
                    symbol: "exclamationmark.triangle.fill",
                    tone: .destructive
                )
            )
            return nil
        }
        return url
    }

    private func appendHistoryEntry(_ entry: HistoryEntry) {
        historyEntries.insert(entry, at: 0)
        if historyEntries.count > Self.maxHistoryEntries {
            historyEntries.removeLast(historyEntries.count - Self.maxHistoryEntries)
        }
        historyPersistence.save(historyEntries)
    }

    func applyLaunchAtLogin() {
        let desired = launchAtLogin
        // Reality already matches the request (e.g. after a reverted failure re-fires this
        // via onChange); persist quietly without re-touching the login item or clobbering feedback.
        guard loginItemManaging.isRegistered != desired else {
            settingsPersistence.save(makeSnapshot())
            return
        }
        do {
            if desired {
                try loginItemManaging.register()
            } else {
                try loginItemManaging.unregister()
            }
            persistSettings()
        } catch {
            recordError(event: "settings.launch_at_login.failed", error: error)
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.launchAtLoginFailed"),
                    symbol: "exclamationmark.triangle.fill",
                    tone: .destructive
                )
            )
            launchAtLogin = !desired
        }
    }

    func persistSettings() {
        if requirePIN {
            ensureIncomingPIN()
        }
        logger.emit(
            level: .info,
            event: "settings.persist.requested",
            scope: "TransferFeatureStore",
            attributes: settingsAttributes()
        )
        settingsPersistence.save(makeSnapshot())
        logger.emit(
            level: .info,
            event: "settings.persist.succeeded",
            scope: "TransferFeatureStore",
            attributes: settingsAttributes()
        )
        showFeedback(
            TransferFeedback(message: FeatureTransferLocalization.string(forKey: "feedback.settingsSaved"), symbol: "checkmark.circle.fill", tone: .success)
        )
        Task {
            do {
                try await runtime.updateSettings(currentProtocolSettings)
                logger.emit(
                    level: .info,
                    event: "settings.runtime_update.succeeded",
                    scope: "TransferFeatureStore",
                    attributes: settingsAttributes()
                )
            } catch {
                recordError(event: "settings.runtime_update.failed", error: error)
                showFeedback(
                    TransferFeedback(message: FeatureTransferLocalization.string(forKey: "feedback.settingsFailed"), symbol: "exclamationmark.triangle.fill", tone: .destructive)
                )
            }
        }
    }

    func updateSaveLocation(_ url: URL) {
        saveLocation = url.path
        persistSettings()
        showFeedback(
            TransferFeedback(message: FeatureTransferLocalization.string(forKey: "feedback.saveLocationChanged"), symbol: "folder.fill", tone: .success)
        )
    }

    func ensureIncomingPIN() {
        incomingPIN = resolvedIncomingPIN
    }

    func regenerateIncomingPIN() {
        incomingPIN = TransferProtocolSettings.generateIncomingPIN()
        logger.emit(level: .notice, event: "settings.persist.requested", scope: "TransferFeatureStore", attributes: settingsAttributes())
        persistSettings()
        showFeedback(
            TransferFeedback(message: FeatureTransferLocalization.string(forKey: "feedback.incomingPINRegenerated"), symbol: "number.circle.fill", tone: .success)
        )
    }

    func updateIncomingPIN(_ candidate: String) -> Bool {
        guard let normalized = TransferProtocolSettings.normalizedIncomingPIN(from: candidate) else {
            logger.emit(
                level: .warning,
                event: "settings.runtime_update.failed",
                scope: "TransferFeatureStore",
                attributes: [
                    .string("error.message", "Incoming PIN must be exactly \(TransferProtocolSettings.incomingPINLength) digits"),
                    .string("error.type", "validation")
                ]
            )
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.format("settings.incomingPINValidation", TransferProtocolSettings.incomingPINLength),
                    symbol: "exclamationmark.triangle.fill",
                    tone: .destructive
                )
            )
            return false
        }

        incomingPIN = normalized
        persistSettings()
        showFeedback(
            TransferFeedback(message: FeatureTransferLocalization.string(forKey: "feedback.incomingPINUpdated"), symbol: "number.circle.fill", tone: .success)
        )
        return true
    }

    @discardableResult
    func updateDeviceName(_ candidate: String) -> Bool {
        guard let normalized = LocalDeviceIdentity.normalizedCustomName(candidate) else {
            return false
        }
        applyResolvedDeviceName(normalized)
        return true
    }

    @discardableResult
    func useSystemDeviceName(resolver: () -> String = LocalDeviceIdentity.systemName) -> String {
        applyResolvedDeviceName(resolver())
    }

    @discardableResult
    func generateRandomDeviceNameAlias(generator: () -> String = { LocalDeviceIdentity.randomAlias() }) -> String {
        applyResolvedDeviceName(generator())
    }

    /// Mirrors the `deinit` teardown of the stream observation and auto-accept tasks.
    /// Clearing both collections keeps repeated `stop()` calls (and `stop()` before
    /// `start()`) idempotent: there are no stale handles left to double-cancel.
    private func cancelObservationAndAutoAcceptTasks() {
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()
        autoAcceptResponseTasks.values.forEach { $0.cancel() }
        autoAcceptResponseTasks.removeAll()
    }

    private func bindRuntimeStreamsIfNeeded() {
        guard observationTasks.isEmpty else { return }

        observationTasks = [
            Task { [weak self] in
                guard let self else { return }
                let stream = await self.runtime.discoveredPeers()
                for await peers in stream {
                    self.nearbyPeers = peers
                    // Keeps each favorite's offline fallback name current; see
                    // `refreshFavoriteAliases()`.
                    self.refreshFavoriteAliases()
                }
            },
            Task { [weak self] in
                guard let self else { return }
                let stream = await self.runtime.inboundRequests()
                for await request in stream {
                    self.handleIncomingRequest(request)
                }
            },
            Task { [weak self] in
                guard let self else { return }
                let stream = await self.runtime.inboundRequestWithdrawals()
                for await requestID in stream {
                    self.withdrawIncomingRequest(id: requestID)
                }
            },
            Task { [weak self] in
                guard let self else { return }
                let stream = await self.runtime.progressEvents()
                for await event in stream {
                    switch event {
                    case .event(let rawEvent):
                        await self.handleProgressEvent(rawEvent)
                    case .reset:
                        await self.resetActiveTransferState()
                    }
                }
            }
        ]
    }

    private func handleProgressEvent(_ event: TransferProgressRawEvent) async {
        cancelProgressCompletionTask()
        let progress = await progressReducer.reduce(event)
        authoritativeActiveTransfer = progress
        if shouldBypassProgressThrottle(for: progress) {
            cancelPendingProgressEmission()
            applyDisplayedProgress(progress)
            handleTerminalSideEffectsIfNeeded(progress)
            return
        }
        queueDisplayedProgress(progress)
    }

    private func queueDisplayedProgress(_ progress: ActiveTransferProgress) {
        pendingProgressSnapshot = progress
        guard pendingProgressEmissionTask == nil else { return }
        pendingProgressEmissionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.progressThrottleIntervalNanoseconds ?? 100_000_000)
            guard let self else { return }
            guard let pending = self.pendingProgressSnapshot else {
                self.pendingProgressEmissionTask = nil
                return
            }
            self.pendingProgressSnapshot = nil
            self.pendingProgressEmissionTask = nil
            self.applyDisplayedProgress(pending)
        }
    }

    private func applyDisplayedProgress(_ progress: ActiveTransferProgress) {
        cancelProgressCompletionTask()
        activeTransfer = progress
        // A terminal transfer leaves the in-flight list immediately; the detail view keeps showing
        // it briefly via `scheduleTerminalDismissal`, which is a separate concern.
        if progress.status.isTerminal {
            activeTransfersByID.removeValue(forKey: progress.id)
        } else {
            activeTransfersByID[progress.id] = progress
        }
    }

    /// Cancels ONE transfer by id, for the per-row cancel button in the in-flight list.
    ///
    /// Cancelling the send to device A must not disturb a concurrent send to device B, so this
    /// deliberately does not touch `activeTransfer` or the shared completion task — the runtime
    /// answers with a `.canceled` progress event for that id alone, and the normal pipeline applies
    /// it.
    func cancelTransfer(id: ActiveTransferProgress.ID) {
        guard activeTransfersByID[id] != nil else { return }
        logger.emit(
            level: .notice,
            event: "transfer.send.canceled",
            scope: "TransferFeatureStore",
            attributes: [.string("transfer.session_id", id)]
        )
        Task {
            try? await runtime.cancelActiveTransfer(id)
        }
    }

    private func shouldBypassProgressThrottle(for progress: ActiveTransferProgress) -> Bool {
        if progress.status.isTerminal {
            return true
        }
        return progress.status == .running && progress.overallProgressValue == 1
    }

    private func handleTerminalSideEffectsIfNeeded(_ progress: ActiveTransferProgress) {
        guard progress.status.isTerminal else { return }
        switch progress.status {
        case .completed:
            logger.emit(
                level: .info,
                event: progress.direction == .sending ? "transfer.send.completed" : "transfer.receive.completed",
                scope: "TransferFeatureStore",
                attributes: [
                    .string("transfer.session_id", progress.id),
                    .string("transfer.file_name", progress.fileName)
                ]
            )
            showFeedback(
                TransferFeedback(
                    message: progress.direction == .sending
                        ? FeatureTransferLocalization.format("feedback.fileSent", progress.fileName)
                        : FeatureTransferLocalization.format("feedback.fileReceived", progress.fileName),
                    symbol: "checkmark.circle.fill",
                    tone: .success
                )
            )
            for entry in Self.makeCompletedHistoryEntries(from: progress) {
                appendHistoryEntry(entry)
            }
        case .canceled:
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.transferCanceled"),
                    symbol: "xmark.circle.fill",
                    tone: .destructive
                )
            )
            scheduleTerminalDismissal()
        case .failed:
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.transferFailed"),
                    symbol: "exclamationmark.triangle.fill",
                    tone: .destructive
                )
            )
            scheduleTerminalDismissal()
        // The `/prepare-upload` refusals (protocol section 4.1) each get their own copy so the
        // sender can tell "they said no" from "they're busy" from "you need a PIN".
        case .pinRequired:
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.transferPINRequired"),
                    symbol: "lock.fill",
                    tone: .destructive
                )
            )
            scheduleTerminalDismissal()
        case .rejected:
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.transferDeclined"),
                    symbol: "hand.raised.fill",
                    tone: .destructive
                )
            )
            scheduleTerminalDismissal()
        case .blocked:
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.transferBlocked"),
                    symbol: "person.crop.circle.badge.exclamationmark.fill",
                    tone: .destructive
                )
            )
            scheduleTerminalDismissal()
        case .rateLimited:
            showFeedback(
                TransferFeedback(
                    message: FeatureTransferLocalization.string(forKey: "feedback.transferRateLimited"),
                    symbol: "clock.badge.exclamationmark.fill",
                    tone: .destructive
                )
            )
            scheduleTerminalDismissal()
        case .running:
            break
        }
    }

    private func scheduleTerminalDismissal() {
        progressCompletionTask?.cancel()
        progressCompletionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.activeTransfer = nil
            self?.authoritativeActiveTransfer = nil
        }
    }

    private func resetActiveTransferState() async {
        cancelPendingProgressEmission()
        cancelProgressCompletionTask()
        authoritativeActiveTransfer = nil
        activeTransfer = nil
        activeTransfersByID.removeAll()
        await progressReducer.reset()
    }

    private func cancelProgressCompletionTask() {
        progressCompletionTask?.cancel()
        progressCompletionTask = nil
    }

    private func cancelPendingProgressEmission() {
        pendingProgressEmissionTask?.cancel()
        pendingProgressEmissionTask = nil
        pendingProgressSnapshot = nil
    }

    private func showFeedback(_ newFeedback: TransferFeedback) {
        feedbackDismissTask?.cancel()
        feedback = newFeedback
        feedbackDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            if self?.feedback?.id == newFeedback.id {
                self?.feedback = nil
                self?.feedbackDismissTask = nil
            }
        }
    }

    private func makeSnapshot() -> TransferSettingsSnapshot {
        TransferSettingsSnapshot(
            quickSave: quickSave,
            appearance: appearance,
            accentColor: accentColor,
            language: language,
            minimizeToMenuBar: minimizeToMenuBar,
            launchAtLogin: launchAtLogin,
            reduceMotion: reduceMotion,
            autoAcceptFavorites: autoAcceptFavorites,
            sendMode: sendMode,
            shareViaLinkAutoAccept: shareViaLinkAutoAccept,
            protocolSettings: currentProtocolSettings
        )
    }

    private var resolvedIncomingPIN: String {
        TransferProtocolSettings.normalizedIncomingPIN(from: incomingPIN) ?? TransferProtocolSettings.generateIncomingPIN()
    }

    private var resolvedDeviceName: String {
        LocalDeviceIdentity.normalizedCustomName(deviceName) ?? LocalDeviceIdentity.systemName()
    }

    private func settingsAttributes() -> [AppLogAttribute] {
        [
            .bool("settings.require_pin", requirePIN),
            .bool("settings.allow_downloads", allowDownloads),
            .bool("settings.use_https", useHTTPS),
            .string("settings.quick_save_mode", quickSave.rawValue)
        ]
    }

    @discardableResult
    private func applyResolvedDeviceName(_ candidate: String) -> String {
        let normalized = LocalDeviceIdentity.normalizedCustomName(candidate) ?? LocalDeviceIdentity.systemName()
        let didChange = normalized != resolvedDeviceName
        deviceName = normalized
        if didChange {
            persistSettings()
        }
        return normalized
    }

    private func recordError(event: String, error: any Error) {
        // A transport error can wrap the request URL, and the sender's PIN rides in its query
        // string. Redact before it reaches either a log sink or `lastErrorMessage`.
        let message = SensitiveTextRedaction.redactedDescription(of: error)
        lastErrorMessage = message
        logger.emit(
            level: .error,
            event: event,
            scope: "TransferFeatureStore",
            attributes: [
                .string("result", "failure"),
                .string("error.message", message),
                .string("error.type", String(describing: type(of: error)))
            ]
        )
    }

    private static func makeCompletedHistoryEntries(from progress: ActiveTransferProgress) -> [HistoryEntry] {
        progress.files
            .filter { $0.status == .completed }
            .map { file in
                let size = file.effectiveTotalBytesForDisplay.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? "—"
                return HistoryEntry(
                    fileName: file.fileName,
                    counterpart: progress.counterpartName,
                    size: size,
                    timestamp: Date(),
                    direction: progress.direction == .sending ? .sent : .received,
                    outcome: .completed,
                    fileURL: file.fileURL
                )
            }
    }

    private static func makeStagedItem(url: URL) -> StagedTransferItem {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let byteCount = values?.fileSize.map(Int64.init)
        let itemCountLabel = (values?.isDirectory == true)
            ? FeatureTransferLocalization.string(forKey: "send.stagedFolderReady")
            : FeatureTransferLocalization.string(forKey: "send.stagedFileReady")
        let subtitle: String
        if let byteCount {
            subtitle = FeatureTransferLocalization.format(
                "send.stagedSubtitleFormat",
                ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file),
                itemCountLabel
            )
        } else {
            subtitle = itemCountLabel
        }
        return StagedTransferItem(
            id: url.absoluteString,
            fileURL: url,
            name: url.lastPathComponent,
            subtitle: subtitle,
            fileTypeSymbol: values?.isDirectory == true ? "folder.fill" : "doc.fill",
            byteCount: byteCount
        )
    }

    private nonisolated static func elapsedMilliseconds(since startUptimeNanoseconds: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startUptimeNanoseconds) / 1_000_000
    }
}
