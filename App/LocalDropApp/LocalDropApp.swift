import SwiftUI
import FeatureTransfer
import Darwin
import UniformTypeIdentifiers

@main
struct LocalDropApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var container: TransferFeatureContainer
    @State private var isFileImporterPresented = false
    @State private var isFolderImporterPresented = false

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        _container = State(initialValue: isUITesting ? .testing() : .live())
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            container.rootView
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
                .task {
                    await container.startIfNeeded()
                }
        }
        .defaultSize(width: 1120, height: 704)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Send File…") {
                    showFileImporter()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Send Folder…") {
                    showFolderImporter()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Send Text…") {}
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(true)

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
                    sendFiles: showFileImporter,
                    sendFolders: showFolderImporter,
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
        isFileImporterPresented = true
    }

    private func showFolderImporter() {
        isFolderImporterPresented = true
    }

    private func openLocalDrop() {
        openWindow(id: "main")
    }

    private func openPreferences() {
        container.showSettings()
        openLocalDrop()
    }

    private func terminate() {
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
}
