import Foundation

public struct SendEntryActions {
    let sendFiles: @MainActor () -> Void
    let sendFolders: @MainActor () -> Void
    let sendText: @MainActor () -> Void
    let sendClipboard: @MainActor () -> Void

    public init(
        sendFiles: @escaping @MainActor () -> Void,
        sendFolders: @escaping @MainActor () -> Void,
        sendText: @escaping @MainActor () -> Void,
        sendClipboard: @escaping @MainActor () -> Void
    ) {
        self.sendFiles = sendFiles
        self.sendFolders = sendFolders
        self.sendText = sendText
        self.sendClipboard = sendClipboard
    }
}

extension SendEntryActions {
    static let noop = SendEntryActions(
        sendFiles: {},
        sendFolders: {},
        sendText: {},
        sendClipboard: {}
    )
}

enum SendEntryKind: String, CaseIterable, Identifiable {
    case file = "File"
    case folder = "Folder"
    case text = "Text"
    case paste = "Paste"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .file:
            return "doc"
        case .folder:
            return "folder"
        case .text:
            return "text.alignleft"
        case .paste:
            return "doc.on.clipboard"
        }
    }

    @MainActor
    func perform(using actions: SendEntryActions) {
        switch self {
        case .file:
            actions.sendFiles()
        case .folder:
            actions.sendFolders()
        case .text:
            actions.sendText()
        case .paste:
            actions.sendClipboard()
        }
    }
}
