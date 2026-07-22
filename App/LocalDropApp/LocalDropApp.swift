import AppKit
import Darwin
import FeatureTransfer
import SwiftUI
import UniformTypeIdentifiers

@main
struct LocalDropApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var container: TransferFeatureContainer
    @State private var importerKind: ImporterKind?
    @State private var isTextEntryPresented = false
    @State private var textEntryDraft = ""
    @State private var shouldStartInitialContainer: Bool
    @State private var shouldBootstrapLiveContainer: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        let enableIncomingPINForUITests = arguments.contains("--ui-testing-incoming-pin-enabled")
        let seedStagedBatchForUITests = arguments.contains("--ui-testing-seed-staged-batch")
        let initialContainer: TransferFeatureContainer

        if isUITesting {
            let container = TransferFeatureContainer.testing(requirePIN: enableIncomingPINForUITests)
            if seedStagedBatchForUITests {
                Self.seedUITestStagedBatch(into: container)
            }
            initialContainer = container
        } else {
            initialContainer = .bootstrap()
        }

        _container = State(initialValue: initialContainer)
        _shouldStartInitialContainer = State(initialValue: isUITesting)
        _shouldBootstrapLiveContainer = State(initialValue: isUITesting == false)
        initialContainer.syncLocalizationLanguage()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            container.applyingCurrentLanguageOverride(to: container.rootView(sendEntryActions: sendEntryActions))
                .fileImporter(
                    isPresented: Binding(
                        get: { importerKind != nil },
                        set: { presented in if !presented { importerKind = nil } }
                    ),
                    allowedContentTypes: importerKind == .folder ? [.folder] : [.item],
                    allowsMultipleSelection: true,
                    onCompletion: handleImportedItems,
                    onCancellation: {}
                )
                .fileDialogMessage(
                    Text(
                        importerKind == .folder
                            ? localized("app.dialog.chooseFoldersToSend")
                            : localized("app.dialog.chooseFilesToSend")
                    )
                )
                .sheet(isPresented: $isTextEntryPresented) {
                    SendTextEntrySheet(
                        initialText: textEntryDraft,
                        onStage: stageText,
                        onCancel: dismissTextSheet
                    )
                }
                .task {
                    appDelegate.minimizeToMenuBarProvider = {
                        MainActor.assumeIsolated { container.shouldMinimizeToMenuBar }
                    }
                    if shouldBootstrapLiveContainer {
                        await loadLiveContainer()
                    } else if shouldStartInitialContainer {
                        shouldStartInitialContainer = false
                        container.recordLaunchStarted(mode: "ui_testing")
                        await container.startIfNeeded()
                    }
                }
        }
        .defaultSize(width: 1120, height: 704)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(localized("app.about.title")) {
                    openAbout()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button(localized("menubar.sendFile")) {
                    beginFileSend()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button(localized("menubar.sendFolder")) {
                    beginFolderSend()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button(localized("app.menu.sendText")) {
                    beginTextSend()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Divider()

                Button(localized("app.menu.clearHistory")) {
                    container.clearHistory()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            }

            CommandGroup(replacing: .appSettings) {
                Button(localized("menubar.preferences")) {
                    openPreferences()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandMenu(localized("app.menu.view")) {
                Button(localized("screen.receive.title")) {
                    container.showReceive()
                    openLocalDrop()
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button(localized("screen.send.title")) {
                    container.showSend()
                    openLocalDrop()
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button(localized("screen.history.title")) {
                    container.showHistory()
                    openLocalDrop()
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button(localized("screen.settings.title")) {
                    container.showSettings()
                    openLocalDrop()
                }
                .keyboardShortcut("4", modifiers: [.command])
            }

            CommandGroup(replacing: .help) {
                Link(localized("app.help.localDropHelp"), destination: URL(string: "https://localsend.org")!)
                Link(localized("app.help.protocolDocs"), destination: URL(string: "https://github.com/localsend/protocol")!)
                Link(localized("app.help.reportIssue"), destination: URL(string: "https://github.com/localsend/localsend/issues")!)
            }
        }

        Window(localized("app.about.title"), id: "about") {
            container.applyingCurrentLanguageOverride(to: AboutLocalDropView())
                .windowTitleUpdater(localized("app.about.title"))
        }
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentSize)

        MenuBarExtra {
            container.menuBarExtraView(
                actions: TransferMenuActions(
                    sendFiles: beginFileSend,
                    sendFolders: beginFolderSend,
                    sendTextOrClipboard: sendTextOrClipboard,
                    openLocalDrop: openLocalDrop,
                    openPreferences: openPreferences,
                    quit: terminate
                )
            )
        } label: {
            Label(localized("root.localDrop"), systemImage: container.menuStatusSymbol)
        }
        .menuBarExtraStyle(.menu)
    }

    private func localized(_ key: String) -> String {
        FeatureTransferLocalization.string(forKey: key)
    }

    private func showFileImporter() {
        container.recordImporterPresented(kind: "file")
        importerKind = .file
    }

    private func showFolderImporter() {
        container.recordImporterPresented(kind: "folder")
        importerKind = .folder
    }

    private func beginFileSend() {
        container.showSend()
        openLocalDrop()
        showFileImporter()
    }

    private func beginFolderSend() {
        container.showSend()
        openLocalDrop()
        showFolderImporter()
    }

    private func beginTextSend(prefilledText: String = "") {
        openLocalDrop()
        showTextEntry(prefilledText: prefilledText)
    }

    // Used by SendView's in-window entry actions: the main window is already open and
    // frontmost here, so these must NOT call openLocalDrop()/openWindow(id:) — doing so
    // spawns a redundant window (a new tab, once window tabbing is involved) instead of
    // just performing the action in place.
    private var sendEntryActions: SendEntryActions {
        SendEntryActions(
            sendFiles: showFileImporter,
            sendFolders: showFolderImporter,
            sendText: { showTextEntry() },
            sendClipboard: stageClipboardTextIfAvailable
        )
    }

    private func openLocalDrop() {
        openWindow(id: "main")
    }

    private func openAbout() {
        openWindow(id: "about")
    }

    private func openPreferences() {
        container.showSettings()
        openLocalDrop()
    }

    private func terminate() {
        container.recordTerminationRequested()
        Task {
            await container.stop()
            exit(EXIT_SUCCESS)
        }
    }

    private func handleImportedItems(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            container.stageImportedItems(urls)
        case .failure(let error):
            container.reportImportFailure(error)
        }
    }

    private func showTextEntry(prefilledText: String = "") {
        textEntryDraft = prefilledText
        container.showSend()
        isTextEntryPresented = true
    }

    private func dismissTextSheet() {
        isTextEntryPresented = false
        textEntryDraft = ""
    }

    private func stageText(_ text: String) {
        if container.stagePastedText(text) {
            dismissTextSheet()
        }
    }

    private func stageClipboardTextIfAvailable() {
        container.showSend()
        switch container.stageClipboardTextIfAvailable() {
        case .staged, .failed:
            break
        case .requiresTextEntry:
            showTextEntry()
        }
    }

    private func sendTextOrClipboard() {
        openLocalDrop()
        stageClipboardTextIfAvailable()
    }

    @MainActor
    private func loadLiveContainer() async {
        guard shouldBootstrapLiveContainer else { return }
        shouldBootstrapLiveContainer = false

        container = await TransferFeatureContainer.liveAsync()
        container.syncLocalizationLanguage()
        appDelegate.minimizeToMenuBarProvider = {
            MainActor.assumeIsolated { container.shouldMinimizeToMenuBar }
        }
        container.recordLaunchStarted(mode: "standard")
        await container.startIfNeeded()
    }

    private static func seedUITestStagedBatch(into container: TransferFeatureContainer) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalDropUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = [
            ("alpha.txt", "alpha"),
            ("bravo.pdf", "bravo"),
            ("charlie.jpg", "charlie")
        ]

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = files.map { name, contents -> URL in
            let url = root.appendingPathComponent(name, isDirectory: false)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        container.stageImportedItems(urls)
    }
}

private enum ImporterKind {
    case file
    case folder
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var minimizeToMenuBarProvider: (() -> Bool)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // When the user opted into minimize-to-menu-bar, keep the process alive on last
        // window close so the MenuBarExtra stays reachable; otherwise quit as before.
        !(minimizeToMenuBarProvider?() ?? false)
    }
}

private struct AboutLocalDropView: View {
    private let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private let privacyPolicyURL = URL(string: "https://localsend.org/privacy")!
    private let supportLocalSendURL = URL(string: "https://localsend.org/donate")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(FeatureTransferLocalization.resource("root.localDrop"))
                            .font(.system(size: 28, weight: .semibold))
                        Text(FeatureTransferLocalization.resource("app.about.tagline"))
                            .foregroundStyle(.secondary)
                        Text(FeatureTransferLocalization.resource("app.about.exclusiveMacOS"))
                            .fontWeight(.semibold)
                    }
                }

                Group {
                    Text(FeatureTransferLocalization.resource("app.about.description1"))
                    Text(FeatureTransferLocalization.resource("app.about.description2"))
                    Text(FeatureTransferLocalization.resource("app.about.description3"))
                }
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Link(destination: termsOfUseURL) { Text(FeatureTransferLocalization.resource("app.about.termsOfUse")) }
                    Link(destination: privacyPolicyURL) { Text(FeatureTransferLocalization.resource("app.about.privacyPolicy")) }
                    Link(destination: supportLocalSendURL) { Text(FeatureTransferLocalization.resource("app.about.supportLocalSend")) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

private extension View {
    func windowTitleUpdater(_ title: String) -> some View {
        background(WindowTitleUpdater(title: title))
    }
}
