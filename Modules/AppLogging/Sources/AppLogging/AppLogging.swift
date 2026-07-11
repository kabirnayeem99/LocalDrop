import Foundation
import OSLog

public enum AppLogLevel: Int, CaseIterable, Codable, Sendable, Comparable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    public static func < (lhs: AppLogLevel, rhs: AppLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var severityNumber: Int {
        switch self {
        case .trace: 1
        case .debug: 5
        case .info: 9
        case .notice: 10
        case .warning: 13
        case .error: 17
        case .critical: 21
        }
    }

    public var severityText: String {
        switch self {
        case .trace: "TRACE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARN"
        case .error: "ERROR"
        case .critical: "CRITICAL"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .trace, .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .error
        case .error, .critical: .fault
        }
    }
}

public enum AppLogPrivacy: Sendable, Equatable {
    case `public`
    case sensitive
}

public enum AppLogAttributeValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int64(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .int64(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .int64(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): String(value)
        }
    }
}

public struct AppLogAttribute: Equatable, Sendable {
    public var key: String
    public var value: AppLogAttributeValue
    public var privacy: AppLogPrivacy

    public init(key: String, value: AppLogAttributeValue, privacy: AppLogPrivacy = .public) {
        self.key = key
        self.value = value
        self.privacy = privacy
    }

    public static func string(_ key: String, _ value: String, privacy: AppLogPrivacy = .public) -> AppLogAttribute {
        AppLogAttribute(key: key, value: .string(value), privacy: privacy)
    }

    public static func int(_ key: String, _ value: Int, privacy: AppLogPrivacy = .public) -> AppLogAttribute {
        AppLogAttribute(key: key, value: .int(value), privacy: privacy)
    }

    public static func int64(_ key: String, _ value: Int64, privacy: AppLogPrivacy = .public) -> AppLogAttribute {
        AppLogAttribute(key: key, value: .int64(value), privacy: privacy)
    }

    public static func double(_ key: String, _ value: Double, privacy: AppLogPrivacy = .public) -> AppLogAttribute {
        AppLogAttribute(key: key, value: .double(value), privacy: privacy)
    }

    public static func bool(_ key: String, _ value: Bool, privacy: AppLogPrivacy = .public) -> AppLogAttribute {
        AppLogAttribute(key: key, value: .bool(value), privacy: privacy)
    }
}

public struct AppLogContext: Equatable, Sendable {
    public var attributes: [AppLogAttribute]
    public var traceID: String?
    public var spanID: String?

    public init(
        attributes: [AppLogAttribute] = [],
        traceID: String? = nil,
        spanID: String? = nil
    ) {
        self.attributes = attributes
        self.traceID = traceID
        self.spanID = spanID
    }

    public func merging(attributes other: [AppLogAttribute]) -> AppLogContext {
        var merged = self
        merged.attributes.append(contentsOf: other)
        return merged
    }
}

public struct AppLoggerConfiguration: Equatable, Sendable {
    public var minimumLevel: AppLogLevel
    public var redactSensitiveValues: Bool

    public init(
        minimumLevel: AppLogLevel = .info,
        redactSensitiveValues: Bool = true
    ) {
        self.minimumLevel = minimumLevel
        self.redactSensitiveValues = redactSensitiveValues
    }
}

public struct AppLogInstrumentationScope: Codable, Equatable, Sendable {
    public var name: String
    public var version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

public struct AppLogRecord: Codable, Equatable, Sendable {
    public var timeUnixNano: String
    public var observedTimeUnixNano: String
    public var severityNumber: Int
    public var severityText: String
    public var body: String
    public var attributes: [String: AppLogAttributeValue]
    public var traceId: String
    public var spanId: String
    public var resource: [String: AppLogAttributeValue]
    public var instrumentationScope: AppLogInstrumentationScope

    public init(
        timeUnixNano: String,
        observedTimeUnixNano: String,
        severityNumber: Int,
        severityText: String,
        body: String,
        attributes: [String: AppLogAttributeValue],
        traceId: String,
        spanId: String,
        resource: [String: AppLogAttributeValue],
        instrumentationScope: AppLogInstrumentationScope
    ) {
        self.timeUnixNano = timeUnixNano
        self.observedTimeUnixNano = observedTimeUnixNano
        self.severityNumber = severityNumber
        self.severityText = severityText
        self.body = body
        self.attributes = attributes
        self.traceId = traceId
        self.spanId = spanId
        self.resource = resource
        self.instrumentationScope = instrumentationScope
    }
}

public protocol AppLogSink: Sendable {
    func write(records: [AppLogRecord]) async throws
}

public struct AppLogClock: Sendable {
    public var now: @Sendable () -> UInt64

    public init(now: @escaping @Sendable () -> UInt64 = {
        UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }) {
        self.now = now
    }
}

public final class AppLogger: @unchecked Sendable {
    private let core: AppLoggerCore
    private let configuration: AppLoggerConfiguration
    private let resource: [String: AppLogAttributeValue]
    private let clock: AppLogClock

    public init(
        configuration: AppLoggerConfiguration = AppLoggerConfiguration(),
        resource: [AppLogAttribute] = [],
        sinks: [any AppLogSink] = [],
        clock: AppLogClock = AppLogClock()
    ) {
        self.configuration = configuration
        self.resource = Dictionary(uniqueKeysWithValues: resource.map { ($0.key, $0.value) })
        self.clock = clock
        core = AppLoggerCore(sinks: sinks)
    }

    public static func disabled() -> AppLogger {
        AppLogger(configuration: AppLoggerConfiguration(minimumLevel: .critical), sinks: [])
    }

    public func isEnabled(_ level: AppLogLevel) -> Bool {
        level >= configuration.minimumLevel
    }

    public func emit(
        level: AppLogLevel,
        event: String,
        message: String? = nil,
        scope: String,
        context: AppLogContext = AppLogContext(),
        attributes: @autoclosure () -> [AppLogAttribute] = []
    ) {
        guard isEnabled(level) else {
            return
        }
        let resolvedAttributes = attributes()
        let record = makeRecord(
            level: level,
            event: event,
            message: message,
            scope: scope,
            context: context,
            attributes: resolvedAttributes
        )

        Task {
            try? await core.write(record: record, forceFlush: level >= .error)
        }
    }

    public func emitAndWait(
        level: AppLogLevel,
        event: String,
        message: String? = nil,
        scope: String,
        context: AppLogContext = AppLogContext(),
        attributes: [AppLogAttribute] = []
    ) async {
        guard isEnabled(level) else {
            return
        }

        try? await core.write(
            record: makeRecord(level: level, event: event, message: message, scope: scope, context: context, attributes: attributes),
            forceFlush: level >= .error
        )
    }

    public func flush() async {
        try? await core.flush()
    }

    private func serialize(attributes: [AppLogAttribute]) -> [String: AppLogAttributeValue] {
        var serialized: [String: AppLogAttributeValue] = [:]
        for attribute in attributes {
            if configuration.redactSensitiveValues, attribute.privacy == .sensitive {
                serialized[attribute.key] = .string("<redacted>")
            } else {
                serialized[attribute.key] = attribute.value
            }
        }
        return serialized
    }

    private func normalizedTraceID(_ traceID: String?) -> String {
        traceID?.isEmpty == false ? traceID! : String(repeating: "0", count: 32)
    }

    private func normalizedSpanID(_ spanID: String?) -> String {
        spanID?.isEmpty == false ? spanID! : String(repeating: "0", count: 16)
    }

    private func makeRecord(
        level: AppLogLevel,
        event: String,
        message: String?,
        scope: String,
        context: AppLogContext,
        attributes: [AppLogAttribute]
    ) -> AppLogRecord {
        let timestamp = String(clock.now())
        let mergedAttributes = serialize(attributes: context.attributes + attributes)
        return AppLogRecord(
            timeUnixNano: timestamp,
            observedTimeUnixNano: timestamp,
            severityNumber: level.severityNumber,
            severityText: level.severityText,
            body: message ?? event,
            attributes: mergedAttributes.merging(["event.name": .string(event)]) { _, new in new },
            traceId: normalizedTraceID(context.traceID),
            spanId: normalizedSpanID(context.spanID),
            resource: resource,
            instrumentationScope: AppLogInstrumentationScope(name: scope)
        )
    }
}

actor AppLoggerCore {
    private let sinks: [any AppLogSink]

    init(sinks: [any AppLogSink]) {
        self.sinks = sinks
    }

    func write(record: AppLogRecord, forceFlush: Bool) async throws {
        for sink in sinks {
            try await sink.write(records: [record])
        }
        if forceFlush {
            try await flush()
        }
    }

    func flush() async throws {
        for sink in sinks {
            if let flushable = sink as? any AppLogFlushableSink {
                try await flushable.flush()
            }
        }
    }
}

public protocol AppLogFlushableSink: AppLogSink {
    func flush() async throws
}

public actor RecordingLogSink: AppLogFlushableSink {
    private var storedRecords: [AppLogRecord] = []

    public init() {}

    public func write(records: [AppLogRecord]) async throws {
        storedRecords.append(contentsOf: records)
    }

    public func flush() async throws {}

    public func records() -> [AppLogRecord] {
        storedRecords
    }
}

public actor JSONLFileSink: AppLogFlushableSink {
    public struct RotationConfiguration: Equatable, Sendable {
        public var maximumFileSizeBytes: Int
        public var maximumArchivedFiles: Int

        public init(maximumFileSizeBytes: Int = 5 * 1024 * 1024, maximumArchivedFiles: Int = 3) {
            self.maximumFileSizeBytes = maximumFileSizeBytes
            self.maximumArchivedFiles = maximumArchivedFiles
        }
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let rotation: RotationConfiguration
    private let flushThreshold: Int
    private var pendingLines: [Data] = []

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        rotation: RotationConfiguration = RotationConfiguration(),
        flushThreshold: Int = 32
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.rotation = rotation
        self.flushThreshold = max(flushThreshold, 1)
    }

    public func write(records: [AppLogRecord]) async throws {
        for record in records {
            let encoded = try encoder.encode(record) + Data([0x0A])
            pendingLines.append(encoded)
        }
        if pendingLines.count >= flushThreshold {
            try flushPendingLines()
        }
    }

    public func flush() async throws {
        try flushPendingLines()
    }

    public func pendingCount() -> Int {
        pendingLines.count
    }

    private func flushPendingLines() throws {
        guard pendingLines.isEmpty == false else {
            return
        }

        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rotateIfNeeded(for: pendingLines.reduce(0) { $0 + $1.count })
        let data = pendingLines.reduce(into: Data(), { $0.append($1) })
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: fileURL)
        }
        pendingLines.removeAll(keepingCapacity: true)
    }

    private func rotateIfNeeded(for appendedBytes: Int) throws {
        let existingSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard existingSize + appendedBytes > rotation.maximumFileSizeBytes, existingSize > 0 else {
            return
        }

        for index in stride(from: rotation.maximumArchivedFiles, through: 1, by: -1) {
            let archivedURL = archivedFileURL(index: index)
            if fileManager.fileExists(atPath: archivedURL.path) {
                if index == rotation.maximumArchivedFiles {
                    try fileManager.removeItem(at: archivedURL)
                } else {
                    try fileManager.moveItem(at: archivedURL, to: archivedFileURL(index: index + 1))
                }
            }
        }

        try fileManager.moveItem(at: fileURL, to: archivedFileURL(index: 1))
    }

    private func archivedFileURL(index: Int) -> URL {
        fileURL.deletingPathExtension()
            .appendingPathExtension("\(index)")
            .appendingPathExtension(fileURL.pathExtension)
    }
}

public struct OSLogSink: AppLogSink {
    private let logger: Logger

    public init(subsystem: String, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func write(records: [AppLogRecord]) async throws {
        for record in records {
            logger.log(level: record.severityText.osLogLevel, "\(record.body, privacy: .public)")
        }
    }
}

private extension String {
    var osLogLevel: OSLogType {
        switch self {
        case "TRACE", "DEBUG": .debug
        case "INFO": .info
        case "NOTICE": .default
        case "WARN": .error
        case "ERROR", "CRITICAL": .fault
        default: .default
        }
    }
}
