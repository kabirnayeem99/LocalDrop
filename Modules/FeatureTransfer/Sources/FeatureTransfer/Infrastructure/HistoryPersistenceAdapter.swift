import Foundation

/// File-backed persistence for transfer history, mirroring the lightweight
/// convention of `SettingsPersistenceAdapter`. Stores a JSON array of
/// `HistoryEntry` values in `history.json` under the shared application
/// support directory. `load()` fails safe to `[]` on a missing, unreadable, or
/// corrupt file and never throws.
struct HistoryPersistenceAdapter: HistoryPersisting {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        directory: URL,
        fileName: String = "history.json",
        fileManager: FileManager = .default
    ) {
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        self.fileManager = fileManager
    }

    func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    func save(_ entries: [HistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
