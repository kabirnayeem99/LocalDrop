import AppLogging
import AppKit
import Dispatch
import Foundation
import LocalSendKit
import SwiftUI

@MainActor
public final class TransferFeatureContainer {
    let store: TransferFeatureStore
    private let logger: AppLogger

    init(store: TransferFeatureStore, logger: AppLogger) {
        self.store = store
        self.logger = logger
    }

    public var rootView: some View {
        RootView(store: store)
            .environment(\.accentTheme, store.accentColor.theme)
    }

    public func rootView(sendEntryActions: SendEntryActions) -> some View {
        RootView(store: store, sendEntryActions: sendEntryActions)
            .environment(\.accentTheme, store.accentColor.theme)
    }

    public var menuStatusSymbol: String {
        store.menuStatusSymbol
    }

    public func menuBarExtraView(actions: TransferMenuActions) -> some View {
        TransferMenuBarExtraView(store: store, actions: actions)
            .applyingLanguageOverride(store.language)
            .environment(\.accentTheme, store.accentColor.theme)
    }

    public func applyingCurrentLanguageOverride<Content: View>(to view: Content) -> some View {
        view.applyingLanguageOverride(store.language)
    }

    public func syncLocalizationLanguage() {
        FeatureTransferLocalization.setLanguage(store.language)
    }

    public var shouldMinimizeToMenuBar: Bool {
        store.minimizeToMenuBar
    }

    public func startIfNeeded() async {
        await store.start()
    }

    public func stop() async {
        logger.emit(level: .info, event: "app.runtime.stop.requested", scope: "TransferFeatureContainer")
        await store.stop()
        await logger.flush()
    }

    public func showReceive() {
        store.screen = .receive
    }

    public func showSend() {
        store.screen = .send
    }

    public func showHistory() {
        store.screen = .history
    }

    public func showSettings() {
        store.screen = .settings
    }

    public func clearHistory() {
        store.clearHistory()
    }

    public func stageImportedItems(_ urls: [URL]) {
        logger.emit(
            level: .info,
            event: "app.import.files.selected",
            scope: "TransferFeatureContainer",
            attributes: [
                .int("event.file_count", urls.count),
                .string("app.screen", Screen.send.rawValue)
            ]
        )
        store.stageDroppedItems(urls)
        store.screen = .send
    }

    @discardableResult
    public func stagePastedText(
        _ text: String,
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            recordTextStagingFailure(
                message: "Text cannot be empty.",
                localizedMessage: FeatureTransferLocalization.string(forKey: "feedback.textEmpty"),
                event: "app.import.text.empty"
            )
            return false
        }

        let directory = directory ?? Self.outboundTextDirectory(fileManager: fileManager)
        let fileURL = directory.appendingPathComponent(Self.generatedTextFilename(), isDirectory: false)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
            logger.emit(
                level: .info,
                event: "app.import.text.staged",
                scope: "TransferFeatureContainer",
                attributes: [
                    .string("transfer.file_name", fileURL.lastPathComponent),
                    .int("transfer.character_count", trimmed.count)
                ]
            )
            store.stageDroppedItems([fileURL])
            store.screen = .send
            return true
        } catch {
            recordTextStagingFailure(
                message: "Text could not be staged.",
                localizedMessage: FeatureTransferLocalization.string(forKey: "feedback.textStagingFailed"),
                event: "app.import.text.failed",
                error: error
            )
            return false
        }
    }

    public func stageClipboardTextIfAvailable(
        stringProvider: () -> String? = { NSPasteboard.general.string(forType: .string) },
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> ClipboardTextStagingResult {
        guard let text = stringProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else {
            return .requiresTextEntry
        }
        return stagePastedText(text, in: directory, fileManager: fileManager) ? .staged : .failed
    }

    public func reportImportFailure(_ error: any Error) {
        logger.emit(
            level: .error,
            event: "app.import.files.failed",
            scope: "TransferFeatureContainer",
            attributes: [
                .string("result", "failure"),
                .string("error.message", error.localizedDescription)
            ]
        )
        store.lastErrorMessage = error.localizedDescription
    }

    public func recordLaunchStarted(mode: String) {
        logger.emit(
            level: .info,
            event: "app.launch.started",
            scope: "TransferFeatureContainer",
            attributes: [
                .string("app.launch.mode", mode),
                .string("app.component", "LocalDropApp")
            ]
        )
    }

    public func recordImporterPresented(kind: String) {
        logger.emit(
            level: .debug,
            event: "app.import.files.selected",
            scope: "TransferFeatureContainer",
            attributes: [
                .string("event.action", "picker_presented"),
                .string("app.import.kind", kind)
            ]
        )
    }

    public func recordTerminationRequested() {
        logger.emit(
            level: .info,
            event: "app.runtime.stop.requested",
            scope: "TransferFeatureContainer",
            attributes: [.string("app.component", "LocalDropApp")]
        )
    }

    public static func live(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> TransferFeatureContainer {
        makeLiveContainer(from: buildLiveBootstrap(userDefaults: userDefaults, fileManager: fileManager))
    }

    public static func liveAsync(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) async -> TransferFeatureContainer {
        let bootstrap = await prepareLiveBootstrap(userDefaults: userDefaults, fileManager: fileManager)
        return makeLiveContainer(from: bootstrap)
    }

    public static func bootstrap(
        fileManager: FileManager = .default
    ) -> TransferFeatureContainer {
        let saveLocation = defaultSaveLocation(fileManager: fileManager)
        let deviceName = LocalDeviceIdentity.systemName()
        let snapshot = TransferSettingsSnapshot.default(deviceName: deviceName, saveLocation: saveLocation)
        let store = TransferFeatureStore(
            runtime: NoopTransferRuntime(),
            settingsPersistence: NoopSettingsPersistence(snapshot: snapshot),
            historyPersistence: InMemoryHistoryPersistence(entries: []),
            loginItemManaging: NoopLoginItemManager(),
            snapshot: snapshot,
            progressThrottleIntervalNanoseconds: 100_000_000,
            logger: .disabled()
        )
        return TransferFeatureContainer(store: store, logger: .disabled())
    }

    public static func testing(
        requirePIN: Bool = false,
        incomingPIN: String = "123456"
    ) -> TransferFeatureContainer {
        var snapshot = TransferSettingsSnapshot.default(
            deviceName: "LocalDrop UI Test Mac",
            saveLocation: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        snapshot.protocolSettings.requirePIN = requirePIN
        snapshot.protocolSettings.incomingPIN = incomingPIN
        let store = TransferFeatureStore(
            runtime: NoopTransferRuntime(),
            settingsPersistence: NoopSettingsPersistence(snapshot: snapshot),
            historyPersistence: InMemoryHistoryPersistence(),
            loginItemManaging: NoopLoginItemManager(),
            snapshot: snapshot,
            progressThrottleIntervalNanoseconds: 100_000_000,
            logger: .disabled()
        )
        store.runtimeStatusText = FeatureTransferLocalization.string(forKey: "runtime.discoverable")
        store.isRuntimeAvailable = true
        return TransferFeatureContainer(store: store, logger: .disabled())
    }

    private static func makeLiveContainer(from bootstrap: LiveBootstrap) -> TransferFeatureContainer {
        let store = TransferFeatureStore(
            runtime: bootstrap.runtime ?? NoopTransferRuntime(),
            settingsPersistence: bootstrap.settingsPersistence,
            historyPersistence: bootstrap.historyPersistence,
            loginItemManaging: bootstrap.loginItemManaging,
            snapshot: bootstrap.snapshot,
            progressThrottleIntervalNanoseconds: 100_000_000,
            logger: bootstrap.logger
        )

        if let error = bootstrap.error {
            store.lastErrorMessage = error.localizedDescription
            store.runtimeStatusText = FeatureTransferLocalization.string(forKey: "runtime.unavailable")
        }

        return TransferFeatureContainer(store: store, logger: bootstrap.logger)
    }

    private nonisolated static func prepareLiveBootstrap(
        userDefaults: UserDefaults,
        fileManager: FileManager
    ) async -> LiveBootstrap {
        let input = LiveBootstrapInput(userDefaults: userDefaults, fileManager: fileManager)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: buildLiveBootstrap(userDefaults: input.userDefaults, fileManager: input.fileManager))
            }
        }
    }

    private nonisolated static func buildLiveBootstrap(
        userDefaults: UserDefaults,
        fileManager: FileManager
    ) -> LiveBootstrap {
        let bootstrapStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let baseDirectory = applicationSupportDirectory(fileManager: fileManager)
        var previousStepUptimeNanoseconds = bootstrapStartUptimeNanoseconds
        let recordBootstrapStep: (AppLogger, String) -> Void = { logger, step in
            let now = DispatchTime.now().uptimeNanoseconds
            logger.emit(
                level: .info,
                event: "app.launch.bootstrap.step",
                scope: "TransferFeatureContainer",
                attributes: [
                    .string("startup.step", step),
                    .double(
                        "startup.step_elapsed_ms",
                        Double(now - previousStepUptimeNanoseconds) / 1_000_000
                    ),
                    .double(
                        "startup.bootstrap_elapsed_ms",
                        Double(now - bootstrapStartUptimeNanoseconds) / 1_000_000
                    )
                ]
            )
            previousStepUptimeNanoseconds = now
        }
        let saveLocation = defaultSaveLocation(fileManager: fileManager)
        let deviceName = LocalDeviceIdentity.systemName()
        let logger = makeLogger(baseDirectory: baseDirectory, hostName: deviceName)
        logger.emit(level: .info, event: "app.launch.started", scope: "TransferFeatureContainer")
        recordBootstrapStep(logger, "application_support_and_logger")
        recordBootstrapStep(logger, "default_save_location")
        recordBootstrapStep(logger, "host_localized_name")
        let defaultSnapshot = TransferSettingsSnapshot.default(deviceName: deviceName, saveLocation: saveLocation)
        recordBootstrapStep(logger, "default_snapshot")
        let settingsPersistence = SettingsPersistenceAdapter(
            userDefaults: userDefaults,
            fallback: defaultSnapshot
        )
        recordBootstrapStep(logger, "settings_persistence_init")
        var snapshot = settingsPersistence.load()
        recordBootstrapStep(logger, "settings_load")
        let historyPersistence = HistoryPersistenceAdapter(
            directory: baseDirectory,
            fileManager: fileManager
        )
        recordBootstrapStep(logger, "history_persistence_init")
        let loginItemManaging = SMAppServiceLoginItemManager()
        recordBootstrapStep(logger, "login_item_manager_init")
        let actuallyLaunchesAtLogin = loginItemManaging.isRegistered
        recordBootstrapStep(logger, "login_item_status")
        if snapshot.launchAtLogin != actuallyLaunchesAtLogin {
            snapshot.launchAtLogin = actuallyLaunchesAtLogin
            settingsPersistence.save(snapshot)
            recordBootstrapStep(logger, "settings_save_launch_at_login")
        }

        logger.emit(
            level: .info,
            event: "app.launch.completed",
            scope: "TransferFeatureContainer",
            attributes: [
                .string("app.component", "TransferFeatureContainer"),
                .bool("settings.use_https", snapshot.protocolSettings.useHTTPS),
                .bool("settings.allow_downloads", snapshot.protocolSettings.allowDownloads),
                .string("settings.save_location.last_path_component", snapshot.protocolSettings.saveLocation.lastPathComponent),
                .double(
                    "startup.bootstrap_elapsed_ms",
                    elapsedMilliseconds(since: bootstrapStartUptimeNanoseconds)
                )
            ]
        )

        do {
            let identityURL = baseDirectory.appendingPathComponent("identity.json")
            let certificateStore = FileCertificateStore(identityURL: identityURL)
            let makeComponents: @Sendable (TransferProtocolSettings) throws -> LiveRuntimeComponents = { settings in
                let identity = try CertificateAuthority(store: certificateStore).loadOrCreateIdentity()
                let bridge = IncomingTransferRequestBridge()
                let registerInfo = RegisterInfo(
                    alias: settings.deviceName,
                    deviceModel: "LocalDrop for macOS",
                    deviceType: .desktop,
                    fingerprint: identity.fingerprint,
                    port: settings.tcpPort,
                    protocolType: settings.protocolType,
                    download: settings.allowDownloads
                )
                let runtimeConfiguration = LocalSendRuntimeConfiguration(
                    registerInfo: registerInfo,
                    protocolType: settings.protocolType,
                    tcpPort: UInt16(clamping: settings.tcpPort),
                    storageDirectory: settings.saveLocation,
                    pin: settings.requirePIN ? settings.incomingPIN : nil,
                    incomingRequestBridge: bridge,
                    allowDownloads: settings.allowDownloads
                )
                let node = try LocalSendNode(
                    runtimeConfiguration: runtimeConfiguration,
                    certificateStore: certificateStore,
                    logger: logger
                )
                return LiveRuntimeComponents(node: node, registerInfo: registerInfo)
            }
            let runtime = LocalSendRuntimeAdapter(
                components: try makeComponents(snapshot.protocolSettings),
                settings: snapshot.protocolSettings,
                makeComponents: makeComponents,
                logger: logger
            )
            return LiveBootstrap(
                logger: logger,
                settingsPersistence: settingsPersistence,
                historyPersistence: historyPersistence,
                loginItemManaging: loginItemManaging,
                snapshot: snapshot,
                runtime: runtime,
                error: nil
            )
        } catch {
            logger.emit(
                level: .critical,
                event: "app.runtime.start.failed",
                scope: "TransferFeatureContainer",
                attributes: [
                    .string("result", "failure"),
                    .string("error.message", error.localizedDescription),
                    .string("app.component", "NoopTransferRuntime")
                ]
            )
            return LiveBootstrap(
                logger: logger,
                settingsPersistence: settingsPersistence,
                historyPersistence: historyPersistence,
                loginItemManaging: loginItemManaging,
                snapshot: snapshot,
                runtime: nil,
                error: error
            )
        }
    }

    private nonisolated static func makeLogger(baseDirectory: URL, hostName: String) -> AppLogger {
        let launchID = UUID().uuidString.lowercased()
        let logsDirectory = baseDirectory.appendingPathComponent("Logs", isDirectory: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let environment: String
        let minimumLevel: AppLogLevel
        #if DEBUG
        minimumLevel = .debug
        environment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? "development" : "test"
        #else
        minimumLevel = .info
        environment = "production"
        #endif
        let resource: [AppLogAttribute] = [
            .string("service.name", "LocalDrop"),
            .string("service.namespace", "com.localdrop"),
            .string("service.version", version),
            .string("deployment.environment", environment),
            .string("host.name", hostName),
            .string("host.arch", ProcessInfo.processInfo.machineArchitectureName),
            .string("os.type", ProcessInfo.processInfo.operatingSystemVersionString),
            .int("process.pid", Int(ProcessInfo.processInfo.processIdentifier)),
            .string("app.launch_id", launchID)
        ]

        return AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: minimumLevel, redactSensitiveValues: true),
            resource: resource,
            sinks: [
                OSLogSink(subsystem: "com.localdrop.LocalDrop", category: "telemetry"),
                JSONLFileSink(fileURL: logsDirectory.appendingPathComponent("localdrop.jsonl"))
            ]
        )
    }

    private nonisolated static func applicationSupportDirectory(fileManager: FileManager) -> URL {
        let root = homeDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return root.appendingPathComponent("LocalDrop", isDirectory: true)
    }

    private nonisolated static func defaultSaveLocation(fileManager: FileManager) -> URL {
        homeDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private nonisolated static func outboundTextDirectory(fileManager: FileManager) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("OutgoingText", isDirectory: true)
    }

    private nonisolated static func generatedTextFilename() -> String {
        "LocalDrop Text \(UUID().uuidString.lowercased()).txt"
    }

    private nonisolated static func homeDirectoryURL(fileManager: FileManager) -> URL {
        let path = NSHomeDirectory()
        if path.isEmpty == false {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    private nonisolated static func elapsedMilliseconds(since startUptimeNanoseconds: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startUptimeNanoseconds) / 1_000_000
    }

    private func recordTextStagingFailure(
        message: String,
        localizedMessage: String? = nil,
        event: String,
        error: (any Error)? = nil
    ) {
        let failureText = error?.localizedDescription ?? message
        logger.emit(
            level: .error,
            event: event,
            scope: "TransferFeatureContainer",
            attributes: [
                .string("result", "failure"),
                .string("error.message", failureText)
            ]
        )
        store.lastErrorMessage = failureText
        store.feedback = TransferFeedback(
            message: localizedMessage ?? message,
            symbol: "exclamationmark.triangle.fill",
            tone: .destructive
        )
        store.screen = .send
    }
}

public enum ClipboardTextStagingResult: Equatable {
    case staged
    case requiresTextEntry
    case failed
}

private struct LiveBootstrap: @unchecked Sendable {
    let logger: AppLogger
    let settingsPersistence: SettingsPersistenceAdapter
    let historyPersistence: HistoryPersistenceAdapter
    let loginItemManaging: SMAppServiceLoginItemManager
    let snapshot: TransferSettingsSnapshot
    let runtime: LocalSendRuntimeAdapter?
    let error: (any Error)?
}

private struct LiveBootstrapInput: @unchecked Sendable {
    let userDefaults: UserDefaults
    let fileManager: FileManager
}

private extension ProcessInfo {
    var machineArchitectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

actor NoopTransferRuntime: TransferRuntime {
    func start() async throws {}
    func stop() async {}
    func refreshDiscovery() async {}
    func discoveredPeers() async -> AsyncStream<[NearbyPeerItem]> { AsyncStream { $0.yield([]) } }
    func inboundRequests() async -> AsyncStream<IncomingTransferRequest> { AsyncStream { _ in } }
    func progressEvents() async -> AsyncStream<TransferProgressEvent> { AsyncStream { _ in } }
    func updateSettings(_ settings: TransferProtocolSettings) async throws {}
    func stage(_ items: [StagedTransferItem]) async {}
    func sendStagedItems(to peerID: NearbyPeerItem.ID, pin: String?) async throws {}
    func respondToIncomingRequest(_ response: IncomingTransferDecision) async throws {}
    func cancelActiveTransfer(_ id: ActiveTransferProgress.ID) async throws {}
}

private final class NoopSettingsPersistence: TransferSettingsPersisting {
    private let snapshot: TransferSettingsSnapshot

    init(snapshot: TransferSettingsSnapshot) {
        self.snapshot = snapshot
    }

    func load() -> TransferSettingsSnapshot {
        snapshot
    }

    func save(_ snapshot: TransferSettingsSnapshot) {}
}

final class InMemoryHistoryPersistence: HistoryPersisting {
    private var entries: [HistoryEntry]

    init(entries: [HistoryEntry] = HistoryEntry.samples) {
        self.entries = entries
    }

    func load() -> [HistoryEntry] {
        entries
    }

    func save(_ entries: [HistoryEntry]) {
        self.entries = entries
    }
}

private struct NoopLoginItemManager: LoginItemManaging {
    func register() throws {}
    func unregister() throws {}
    var isRegistered: Bool { false }
}
