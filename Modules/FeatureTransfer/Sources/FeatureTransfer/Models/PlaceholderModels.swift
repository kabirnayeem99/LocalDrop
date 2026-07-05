import Foundation

enum DeviceKind {
    case macbook
    case desktop
    case phone
    case tablet

    var symbol: String {
        switch self {
        case .macbook: return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        }
    }
}

struct Device: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let subtitle: String
    let kind: DeviceKind
    var unreadCount: Int = 0
    var isFavorite: Bool = false

    static func == (lhs: Device, rhs: Device) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Device {
    static let nearby: [Device] = [
        Device(name: "iPhone 15 Pro", subtitle: "Ken's iPhone · #4", kind: .phone),
        Device(name: "iMac Studio", subtitle: "Living Room · #12", kind: .desktop),
        Device(name: "iPad Air", subtitle: "Studio · #7", kind: .tablet),
        Device(name: "Galaxy S24", subtitle: "Nearby · #2", kind: .phone, unreadCount: 2, isFavorite: true)
    ]
}

enum TransferDirection {
    case sent
    case received
}

enum TransferOutcome {
    case completed
    case declined

    var label: String {
        switch self {
        case .completed: return "Completed"
        case .declined: return "Declined"
        }
    }

    var symbol: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        }
    }
}

struct HistoryEntry: Identifiable {
    let id = UUID()
    let fileName: String
    let counterpart: String
    let size: String
    let timestamp: String
    let direction: TransferDirection
    let outcome: TransferOutcome
}

extension HistoryEntry {
    static let samples: [HistoryEntry] = [
        HistoryEntry(
            fileName: "Design-Assets.zip",
            counterpart: "iPhone 15 Pro",
            size: "24.6 MB",
            timestamp: "Today, 2:14 PM",
            direction: .received,
            outcome: .completed
        ),
        HistoryEntry(
            fileName: "Q3-Report.pdf",
            counterpart: "iMac Studio",
            size: "4.2 MB",
            timestamp: "Today, 11:02 AM",
            direction: .sent,
            outcome: .completed
        ),
        HistoryEntry(
            fileName: "IMG_4021.HEIC",
            counterpart: "iPad Air",
            size: "3.1 MB",
            timestamp: "Yesterday",
            direction: .received,
            outcome: .completed
        ),
        HistoryEntry(
            fileName: "presentation.key",
            counterpart: "Galaxy S24",
            size: "18.9 MB",
            timestamp: "Mon",
            direction: .sent,
            outcome: .declined
        )
    ]

    var subtitle: String {
        let verb = direction == .received ? "Received from" : "Sent to"
        return "\(verb) \(counterpart) · \(size)"
    }
}

struct IncomingFile: Identifiable {
    let id = UUID()
    let name: String
    let size: String
    let symbol: String
}

struct StagedFile {
    let name: String
    let subtitle: String
}

struct IncomingRequest {
    let deviceName: String
    let subtitle: String
    let files: [IncomingFile]

    static let sample = IncomingRequest(
        deviceName: "iPhone 15 Pro",
        subtitle: "Ken's iPhone · 3 items · 24.6 MB",
        files: [
            IncomingFile(name: "keynote-final.key", size: "18.9 MB", symbol: "doc.fill"),
            IncomingFile(name: "cover.png", size: "3.4 MB", symbol: "photo.fill"),
            IncomingFile(name: "notes.pdf", size: "2.3 MB", symbol: "doc.fill")
        ]
    )
}
