import SwiftUI

public struct TransferMenuActions {
    let sendFiles: @MainActor () -> Void
    let sendFolders: @MainActor () -> Void
    let sendTextOrClipboard: @MainActor () -> Void
    let openLocalDrop: @MainActor () -> Void
    let openPreferences: @MainActor () -> Void
    let quit: @MainActor () -> Void

    public init(
        sendFiles: @escaping @MainActor () -> Void,
        sendFolders: @escaping @MainActor () -> Void,
        sendTextOrClipboard: @escaping @MainActor () -> Void,
        openLocalDrop: @escaping @MainActor () -> Void,
        openPreferences: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void
    ) {
        self.sendFiles = sendFiles
        self.sendFolders = sendFolders
        self.sendTextOrClipboard = sendTextOrClipboard
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
    let stagedItemsText: String?
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

        Label(summary.headerTitle, systemImage: summary.statusSymbol)
        Text(summary.statusText)
        if let stagedItemsText = summary.stagedItemsText {
            Text(stagedItemsText)
        }
        Divider()

        Button(FeatureTransferLocalization.resource("menubar.sendFile")) {
            actions.sendFiles()
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Button(FeatureTransferLocalization.resource("menubar.sendFolder")) {
            actions.sendFolders()
        }

        Button(FeatureTransferLocalization.resource("menubar.sendTextOrClipboard")) {
            actions.sendTextOrClipboard()
        }

        Divider()

        Menu {
            if store.stagedItems.isEmpty {
                Text(FeatureTransferLocalization.resource("menubar.stageFirst"))
            } else if store.nearbyPeers.isEmpty {
                Text(FeatureTransferLocalization.resource("send.noDevices"))
            } else {
                ForEach(store.nearbyPeers) { peer in
                    Button(peer.name) {
                        store.send(to: peer.id)
                    }
                }
            }

            Divider()

            Button(FeatureTransferLocalization.resource("root.refresh")) {
                store.refreshNearbyPeers()
            }
            .keyboardShortcut("r", modifiers: [.command])
        } label: {
            Text(FeatureTransferLocalization.resource("menubar.sendToNearby"))
        }

        let receivingTitle = FeatureTransferLocalization.format("menubar.receivingTitle", store.quickSave.menuLabel)
        Menu {
            ForEach(QuickSaveMode.allCases) { mode in
                Button(mode.menuLabel) {
                    store.updateQuickSave(mode)
                }
                .disabled(store.quickSave == mode)
            }

            Divider()

            Button(FeatureTransferLocalization.resource("menubar.pauseReceiving")) {}
                .disabled(true)
        } label: {
            Text(receivingTitle)
        }

        if let activeTransfer = store.activeTransfer {
            Divider()

            Text(summary.activeTransferTitle ?? FeatureTransferLocalization.string(forKey: "menubar.activeTransfer"))
            Button(FeatureTransferLocalization.resource("general.cancel")) {
                store.cancelActiveTransfer()
            }
            .disabled(activeTransfer.status != .running)
        }

        if store.incomingRequest != nil {
            Divider()

            Text(summary.incomingRequestTitle ?? FeatureTransferLocalization.string(forKey: "menubar.incomingRequest"))
            Button(FeatureTransferLocalization.resource("incomingRequest.accept")) {
                store.acceptIncomingRequest()
            }
            Button(FeatureTransferLocalization.resource("incomingRequest.decline")) {
                store.declineIncomingRequest()
            }
        }

        Divider()

        Menu {
            if summary.recentHistoryEntries.isEmpty {
                Text(FeatureTransferLocalization.resource("history.noTransfers"))
            } else {
                ForEach(summary.recentHistoryEntries) { entry in
                    Text(entry.menuTitle)
                }
            }

            Divider()

            Button(FeatureTransferLocalization.resource("menubar.showAllHistory")) {
                store.screen = .history
                actions.openLocalDrop()
            }
        } label: {
            Text(FeatureTransferLocalization.resource("menubar.recentTransfers"))
        }

        Divider()

        Button(FeatureTransferLocalization.resource("menubar.openLocalDrop")) {
            actions.openLocalDrop()
        }
        .keyboardShortcut("o", modifiers: [.command])

        Button(FeatureTransferLocalization.resource("menubar.preferences")) {
            store.screen = .settings
            actions.openPreferences()
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button(FeatureTransferLocalization.resource("menubar.quitLocalDrop")) {
            actions.quit()
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}

extension TransferFeatureStore {
    var menuSummary: TransferMenuSummary {
        TransferMenuSummary(
            statusSymbol: menuStatusSymbol,
            headerTitle: deviceName.isEmpty
                ? FeatureTransferLocalization.string(forKey: "root.localDrop")
                : deviceName,
            statusText: menuStatusText,
            stagedItemCount: stagedItems.count,
            stagedItemsText: stagedItems.isEmpty ? nil : stagedItems.stagedBatchSummaryLabel,
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
            return FeatureTransferLocalization.format("menubar.incomingRequestFromFormat", incomingRequest.deviceName)
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
        let action = direction == .sending
            ? FeatureTransferLocalization.string(forKey: "transfer.progress.sending")
            : FeatureTransferLocalization.string(forKey: "transfer.progress.receiving")
        let itemTitle: String
        if files.count > 1 {
            let completedCount = files.filter { $0.status == .completed }.count
            itemTitle = "\(completedCount) of \(files.count) completed"
        } else {
            itemTitle = fileName
        }
        if hasKnownTotal {
            return FeatureTransferLocalization.format("transfer.progress.menuTitleFormat", action, itemTitle, stablePercent)
        }
        return "\(action) · \(itemTitle)"
    }
}

extension IncomingTransferRequest {
    var menuTitle: String {
        let fileCountString = files.count == 1
            ? FeatureTransferLocalization.string(forKey: "incomingRequest.files.one")
            : FeatureTransferLocalization.format("incomingRequest.files.many", files.count)
        return FeatureTransferLocalization.format("incomingRequest.menuTitleFormat", deviceName, fileCountString)
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
            && lhs.fileURL == rhs.fileURL
    }

    var menuTitle: String {
        FeatureTransferLocalization.format("history.menuTitleFormat", fileName, timestampDisplay)
    }
}

extension QuickSaveMode {
    var menuLabel: String {
        switch self {
        case .off:
            return FeatureTransferLocalization.string(forKey: "quicksave.menuLabel.off")
        case .favorites:
            return FeatureTransferLocalization.string(forKey: "quicksave.menuLabel.favorites")
        case .on:
            return FeatureTransferLocalization.string(forKey: "quicksave.menuLabel.on")
        }
    }
}
