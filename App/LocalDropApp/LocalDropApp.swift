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
    @State private var isFileImporterPresented = false
    @State private var isFolderImporterPresented = false
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
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            container.rootView(sendEntryActions: sendEntryActions)
                .fileImporter(
                    isPresented: $isFileImporterPresented,
                    allowedContentTypes: [.item],
                    allowsMultipleSelection: true,
                    onCompletion: handleImportedItems,
                    onCancellation: {}
                )
                .fileDialogMessage(Text("Choose files to send"))
                .fileImporter(
                    isPresented: $isFolderImporterPresented,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: true,
                    onCompletion: handleImportedItems,
                    onCancellation: {}
                )
                .fileDialogMessage(Text("Choose folders to send"))
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
            CommandGroup(replacing: .newItem) {
                Button("Send File…") {
                    beginFileSend()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Send Folder…") {
                    beginFolderSend()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Send Text…") {
                    beginTextSend()
                }
                    .keyboardShortcut("t", modifiers: [.command])

                Divider()

                Button("Clear History") {
                    container.clearHistory()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            }

            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") {
                    openPreferences()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandMenu("View") {
                Button("Receive") {
                    container.showReceive()
                    openLocalDrop()
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Send") {
                    container.showSend()
                    openLocalDrop()
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("History") {
                    container.showHistory()
                    openLocalDrop()
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button("Settings") {
                    container.showSettings()
                    openLocalDrop()
                }
                .keyboardShortcut("4", modifiers: [.command])
            }

            CommandGroup(replacing: .help) {
                Link("LocalDrop Help", destination: URL(string: "https://localsend.org")!)
                Link("LocalSend Protocol Docs", destination: URL(string: "https://github.com/localsend/protocol")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/localsend/localsend/issues")!)
            }
        }

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
            Label("LocalDrop", systemImage: container.menuStatusSymbol)
        }
        .menuBarExtraStyle(.menu)
    }

    private func showFileImporter() {
        container.recordImporterPresented(kind: "file")
        isFileImporterPresented = true
    }

    private func showFolderImporter() {
        container.recordImporterPresented(kind: "folder")
        isFolderImporterPresented = true
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
        showTextEntry(prefilledText: prefilledText)
    }

    private var sendEntryActions: SendEntryActions {
        SendEntryActions(
            sendFiles: beginFileSend,
            sendFolders: beginFolderSend,
            sendText: { beginTextSend() },
            sendClipboard: sendTextOrClipboard
        )
    }

    private func openLocalDrop() {
        openWindow(id: "main")
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
            openLocalDrop()
        case .failure(let error):
            container.reportImportFailure(error)
        }
    }

    private func showTextEntry(prefilledText: String = "") {
        textEntryDraft = prefilledText
        container.showSend()
        isTextEntryPresented = true
        openLocalDrop()
    }

    private func dismissTextSheet() {
        isTextEntryPresented = false
        textEntryDraft = ""
    }

    private func stageText(_ text: String) {
        if container.stagePastedText(text) {
            dismissTextSheet()
            openLocalDrop()
        }
    }

    private func sendTextOrClipboard() {
        container.showSend()
        switch container.stageClipboardTextIfAvailable() {
        case .staged:
            openLocalDrop()
        case .requiresTextEntry:
            showTextEntry()
        case .failed:
            openLocalDrop()
        }
    }

    @MainActor
    private func loadLiveContainer() async {
        guard shouldBootstrapLiveContainer else { return }
        shouldBootstrapLiveContainer = false

        container = await TransferFeatureContainer.liveAsync()
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var minimizeToMenuBarProvider: (() -> Bool)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // When the user opted into minimize-to-menu-bar, keep the process alive on last
        // window close so the MenuBarExtra stays reachable; otherwise quit as before.
        !(minimizeToMenuBarProvider?() ?? false)
    }
}
