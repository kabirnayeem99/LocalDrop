import Foundation
import XCTest
@testable import AppLogging

final class AppLoggingTests: XCTestCase {
    func testAppLogLevelSeverityMappingsMatchExpectedOpenTelemetryValues() {
        XCTAssertEqual(AppLogLevel.trace.severityNumber, 1)
        XCTAssertEqual(AppLogLevel.debug.severityNumber, 5)
        XCTAssertEqual(AppLogLevel.info.severityNumber, 9)
        XCTAssertEqual(AppLogLevel.notice.severityNumber, 10)
        XCTAssertEqual(AppLogLevel.warning.severityNumber, 13)
        XCTAssertEqual(AppLogLevel.error.severityNumber, 17)
        XCTAssertEqual(AppLogLevel.critical.severityNumber, 21)
        XCTAssertEqual(AppLogLevel.warning.severityText, "WARN")
    }

    func testAttributeValueEncodesExpectedJSONScalars() throws {
        let payload: [String: AppLogAttributeValue] = [
            "string": .string("value"),
            "int": .int(3),
            "int64": .int64(7),
            "double": .double(1.5),
            "bool": .bool(true)
        ]

        let encoded = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(json.contains("\"string\":\"value\""))
        XCTAssertTrue(json.contains("\"int\":3"))
        XCTAssertTrue(json.contains("\"int64\":7"))
        XCTAssertTrue(json.contains("\"double\":1.5"))
        XCTAssertTrue(json.contains("\"bool\":true"))
    }

    func testLoggerEmitsOpenTelemetryShapedRecordAndRedactsSensitiveAttributes() async throws {
        let sink = RecordingLogSink()
        let logger = AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: .debug, redactSensitiveValues: true),
            resource: [
                .string("service.name", "LocalDrop"),
                .string("app.launch_id", "launch-1")
            ],
            sinks: [sink],
            clock: AppLogClock(now: { 123 })
        )

        await logger.emitAndWait(
            level: .info,
            event: "transfer.send.started",
            scope: "TransferFeatureStore",
            context: AppLogContext(
                attributes: [.string("transfer.session_id", "session-1")],
                traceID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                spanID: "bbbbbbbbbbbbbbbb"
            ),
            attributes: [
                .string("peer.alias", "Kabir MacBook"),
                .string("incoming.pin", "123456", privacy: .sensitive)
            ]
        )

        let records = await sink.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.timeUnixNano, "123")
        XCTAssertEqual(record.observedTimeUnixNano, "123")
        XCTAssertEqual(record.severityNumber, 9)
        XCTAssertEqual(record.severityText, "INFO")
        XCTAssertEqual(record.body, "transfer.send.started")
        XCTAssertEqual(record.traceId, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(record.spanId, "bbbbbbbbbbbbbbbb")
        XCTAssertEqual(record.attributes["event.name"], .string("transfer.send.started"))
        XCTAssertEqual(record.attributes["transfer.session_id"], .string("session-1"))
        XCTAssertEqual(record.attributes["incoming.pin"], .string("<redacted>"))
        XCTAssertEqual(record.resource["service.name"], .string("LocalDrop"))
        XCTAssertEqual(record.instrumentationScope.name, "TransferFeatureStore")
    }

    func testLoggerSkipsDisabledLevelsWithoutBuildingAttributes() async {
        let sink = RecordingLogSink()
        let logger = AppLogger(
            configuration: AppLoggerConfiguration(minimumLevel: .error),
            sinks: [sink]
        )
        var didBuildAttributes = false

        logger.emit(
            level: .info,
            event: "ignored",
            scope: "Tests",
            attributes: {
                didBuildAttributes = true
                return [.string("never", "called")]
            }()
        )
        await logger.flush()

        XCTAssertFalse(didBuildAttributes)
        let records = await sink.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testJSONLFileSinkBatchesFlushesAndRotates() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("localdrop.log")
        let sink = JSONLFileSink(
            fileURL: fileURL,
            rotation: .init(maximumFileSizeBytes: 180, maximumArchivedFiles: 2),
            flushThreshold: 2
        )
        let record1 = makeRecord(body: "one")
        let record2 = makeRecord(body: "two")
        let record3 = makeRecord(body: "three")

        try await sink.write(records: [record1])
        let pendingAfterFirstWrite = await sink.pendingCount()
        XCTAssertEqual(pendingAfterFirstWrite, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        try await sink.write(records: [record2])
        let pendingAfterSecondWrite = await sink.pendingCount()
        XCTAssertEqual(pendingAfterSecondWrite, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try await sink.write(records: [record3])
        try await sink.flush()

        let archivedURL = fileURL.deletingPathExtension().appendingPathExtension("1").appendingPathExtension("log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedURL.path))

        let latestData = try Data(contentsOf: fileURL)
        let latestString = try XCTUnwrap(String(data: latestData, encoding: .utf8))
        XCTAssertTrue(latestString.contains("\"body\":\"three\""))
    }

    func testJSONLFileSinkFlushesPendingRecordsOnTimer() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("localdrop.log")
        let sink = JSONLFileSink(
            fileURL: fileURL,
            flushThreshold: 10,
            flushIntervalNanoseconds: 20_000_000
        )

        try await sink.write(records: [makeRecord(body: "timer")])
        let pendingAfterWrite = await sink.pendingCount()
        XCTAssertEqual(pendingAfterWrite, 1)
        try await Task.sleep(nanoseconds: 80_000_000)

        let pendingAfterTimer = await sink.pendingCount()
        XCTAssertEqual(pendingAfterTimer, 0)
        let fileData = try Data(contentsOf: fileURL)
        let fileString = try XCTUnwrap(String(data: fileData, encoding: .utf8))
        XCTAssertTrue(fileString.contains("\"body\":\"timer\""))
    }

    func testDisabledLoggerUsesCriticalMinimumLevel() {
        XCTAssertFalse(AppLogger.disabled().isEnabled(.info))
        XCTAssertTrue(AppLogger.disabled().isEnabled(.critical))
    }

    private func makeRecord(body: String) -> AppLogRecord {
        AppLogRecord(
            timeUnixNano: "1",
            observedTimeUnixNano: "1",
            severityNumber: 9,
            severityText: "INFO",
            body: body,
            attributes: ["event.name": .string(body)],
            traceId: String(repeating: "0", count: 32),
            spanId: String(repeating: "0", count: 16),
            resource: ["service.name": .string("LocalDrop")],
            instrumentationScope: AppLogInstrumentationScope(name: "Tests")
        )
    }
}
