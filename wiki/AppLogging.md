# AppLogging

AppLogging is a standalone Swift Package Manager library that provides structured, OpenTelemetry-shaped logging. It is imported by LocalSendKit and FeatureTransfer.

## Responsibilities

- Define severity levels and log record shapes.
- Support typed attributes and sensitive-value redaction.
- Provide async fire-and-forget and awaitable emit APIs.
- Offer pluggable sinks: in-memory recording, JSON Lines file output, and OSLog bridging.
- Batch and rotate file output.

## File Reference

- `AppLogging.swift`: core implementation.
- `Package.swift`: package definition with `AppLogging` library target and `AppLoggingTests` test target.
- `Tests/AppLoggingTests/AppLoggingTests.swift`: tests for severity mapping, JSON encoding, redaction, sink batching, rotation, and timer flushing.

## Types

- `AppLogLevel`: trace, debug, info, notice, warning, error, critical. Each level maps to an OpenTelemetry-style severity number and text label.
- `AppLogRecord`: a Codable, Sendable value. Contains timestamp, observed timestamp, severity, body, attributes, trace/span IDs, resource, and instrumentation scope.
- `AppLogAttribute`: typed value (`string`, `int`, `int64`, `double`, `bool`) with an optional `public`/`sensitive` privacy flag.
- `AppLoggerConfiguration`: controls `minimumLevel` and redaction behavior.
- `AppLogger`: provides `emit(...)` and `emitAndWait(...)`. Errors and above force a flush. The logger is `@unchecked Sendable`; writes are serialized through an `AppLoggerCore` actor.
- `AppLogSink`: protocol for custom sinks.
  - `RecordingLogSink`: in-memory sink for testing.
  - `JSONLFileSink`: JSON Lines file output with batching, timer flush, and rotation.
  - `OSLogSink`: bridges to Apple `Logger` / `OSLog`.

## Usage

```swift
import AppLogging

let logger = AppLogger(...)
await logger.emit(level: .info, body: "Runtime started", attributes: [
    .init(key: "port", value: .int(53317))
])
```

## Safety

Sensitive attributes are redacted at the chokepoint before they reach a sink. The `AppLoggerConfiguration` controls whether redaction is enabled.
