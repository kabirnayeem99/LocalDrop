import SwiftUI

public struct TransferMenuActions {
    let sendFiles: @MainActor () -> Void
    let sendFolders: @MainActor () -> Void
    let openLocalDrop: @MainActor () -> Void
    let openPreferences: @MainActor () -> Void
    let quit: @MainActor () -> Void

    public init(
        sendFiles: @escaping @MainActor () -> Void,
        sendFolders: @escaping @MainActor () -> Void,
        openLocalDrop: @escaping @MainActor () -> Void,
        openPreferences: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void
    ) {
        self.sendFiles = sendFiles
        self.sendFolders = sendFolders
        self.openLocalDrop = openLocalDrop
        self.openPreferences = openPreferences
        self.quit = quit
    }
}

struct TransferMenuSummary: Equatable {
    let statusSymbol: String
    let headerTitle: String
    let statusText: String
    let stagedItemCount: Int
    let nearbyPeerCount: Int
    let canSendToPeers: Bool
    let activeTransferTitle: String?
    let incomingRequestTitle: String?
    let recentHistoryEntries: [HistoryEntry]
}

struct TransferMenuBarExtraView: View {
    @Bindable var store: TransferFeatureStore
    let actions: TransferMenuActions

    var body: some View {
        let summary = store.menuSummary

        Text(summary.headerTitle)
        Text(summary.statusText)
        Divider()

        Button("Send File…") {
            actions.sendFiles()
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Button("Send Folder…") {
            actions.sendFolders()
        }

        Button("Send Text / Clipboard…") {}
            .disabled(true)

        Divider()

        Menu("Nearby Devices") {
            if store.nearbyPeers.isEmpty {
                Text("No nearby devices")
            } else {
                ForEach(store.nearbyPeers) { peer in
                    Button(peer.name) {
                        store.send(to: peer.id)
                    }
                    .disabled(store.stagedItems.isEmpty)
                }
            }

            Divider()

            Button("Refresh") {
                store.refreshNearbyPeers()
            }
            .keyboardShortcut("r", modifiers: [.command])
        }

        Menu("Receiving: \(store.quickSave.menuLabel)") {
            ForEach(QuickSaveMode.allCases) { mode in
                Button(mode.menuLabel) {
                    store.updateQuickSave(mode)
                }
                .disabled(store.quickSave == mode)
            }

            Divider()

            Button("Pause Receiving") {}
                .disabled(true)
        }

        if let activeTransfer = store.activeTransfer {
            Divider()

            Text(summary.activeTransferTitle ?? "Active Transfer")
            Button("Cancel") {
                store.cancelActiveTransfer()
            }
            .disabled(activeTransfer.progress >= 1)
        }

        if store.incomingRequest != nil {
            Divider()

            Text(summary.incomingRequestTitle ?? "Incoming Request")
            Button("Accept") {
                store.acceptIncomingRequest()
            }
            Button("Decline") {
                store.declineIncomingRequest()
            }
        }

        Divider()

        Menu("Recent Transfers") {
            if summary.recentHistoryEntries.isEmpty {
                Text("No recent transfers")
            } else {
                ForEach(summary.recentHistoryEntries) { entry in
                    Text(entry.menuTitle)
                }
            }

            Divider()

            Button("Show All in History…") {
                store.screen = .history
                actions.openLocalDrop()
            }
        }

        Divider()

        Button("Open LocalDrop") {
            actions.openLocalDrop()
        }
        .keyboardShortcut("o", modifiers: [.command])

        Button("Preferences…") {
            store.screen = .settings
            actions.openPreferences()
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("Quit LocalDrop") {
            actions.quit()
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}

extension TransferFeatureStore {
    var menuSummary: TransferMenuSummary {
        TransferMenuSummary(
            statusSymbol: menuStatusSymbol,
            headerTitle: deviceName.isEmpty ? "LocalDrop" : deviceName,
            statusText: menuStatusText,
            stagedItemCount: stagedItems.count,
            nearbyPeerCount: nearbyPeers.count,
            canSendToPeers: stagedItems.isEmpty == false && nearbyPeers.isEmpty == false,
            activeTransferTitle: activeTransfer?.menuTitle,
            incomingRequestTitle: incomingRequest?.menuTitle,
            recentHistoryEntries: Array(historyEntries.prefix(5))
        )
    }

    var menuStatusSymbol: String {
        if incomingRequest != nil {
            return "paperplane.badge.clock"
        }
        if activeTransfer != nil {
            return "paperplane.fill"
        }
        if isRuntimeAvailable == false {
            return "paperplane.circle"
        }
        return "paperplane"
    }

    private var menuStatusText: String {
        if let incomingRequest {
            return "Incoming request from \(incomingRequest.deviceName)"
        }
        if let activeTransfer {
            return activeTransfer.menuTitle
        }
        return runtimeStatusText
    }

    func updateQuickSave(_ mode: QuickSaveMode) {
        quickSave = mode
        persistSettings()
    }
}

extension ActiveTransferProgress {
    var menuTitle: String {
        let action = direction == .sending ? "Sending" : "Receiving"
        return "\(action) \(fileName) \(Int(progress * 100))%"
    }
}

extension IncomingTransferRequest {
    var menuTitle: String {
        "\(deviceName) wants to send \(files.count == 1 ? "1 file" : "\(files.count) files")"
    }
}

extension HistoryEntry: Equatable {
    static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.fileName == rhs.fileName
            && lhs.counterpart == rhs.counterpart
            && lhs.size == rhs.size
            && lhs.timestamp == rhs.timestamp
            && lhs.direction == rhs.direction
            && lhs.outcome == rhs.outcome
    }

    var menuTitle: String {
        "\(fileName) — \(timestamp)"
    }
}

extension QuickSaveMode {
    var menuLabel: String {
        switch self {
        case .off: "Ask Each Time"
        case .favorites: "Favorites Only"
        case .on: "Downloads"
        }
    }
}
