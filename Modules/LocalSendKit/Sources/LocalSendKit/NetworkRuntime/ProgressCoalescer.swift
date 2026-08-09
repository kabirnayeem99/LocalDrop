import Foundation

/// Decides whether a progress sample is worth publishing.
///
/// A transfer reports bytes every read — 64 KiB at a time, so roughly 16,000 samples for a 1 GB
/// file. Each one costs an actor hop, a full snapshot recompute and a broadcast to every state
/// observer, none of which a human can perceive at that rate.
///
/// Both a byte threshold and a time threshold are applied, whichever trips first, because either
/// alone has a bad case: bytes-only goes silent on a slow link (a stalled 1 KiB/s transfer would
/// never repaint), and time-only still fires far more often than needed on a fast one.
///
/// What this deliberately does NOT do is change any published *number*. It drops intermediate
/// samples; it never rounds, estimates or interpolates. Callers must still publish their terminal
/// value unconditionally — `shouldReport` is for the streaming middle of a transfer, so the final
/// byte count stays exact and the byte-accurate totals / EWMA speed / ETA model is preserved.
struct ProgressCoalescer {
    /// Publish once this many bytes have accumulated since the last published sample.
    let byteThreshold: Int64
    /// ...or once this long has passed, whichever happens first.
    let timeThreshold: TimeInterval
    private let now: @Sendable () -> TimeInterval

    private var lastReportedBytes: Int64 = 0
    private var lastReportedTime: TimeInterval?

    /// 256 KiB / 100 ms keeps a fast local transfer to about 10 updates per second while still
    /// repainting promptly on a slow one. At 64 KiB per read this is one publish per four reads
    /// at worst, cutting the 1 GB case from ~16,000 updates to ~4,000 by bytes and far fewer in
    /// practice because the time threshold dominates on fast links.
    init(
        byteThreshold: Int64 = 256 * 1024,
        timeThreshold: TimeInterval = 0.1,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.byteThreshold = byteThreshold
        self.timeThreshold = timeThreshold
        self.now = now
    }

    /// Whether `bytes` should be published now. Mutating: a `true` answer records the sample as
    /// published, so the next call measures from here.
    ///
    /// The first sample of a transfer always publishes — otherwise a transfer smaller than the
    /// byte threshold would show no progress at all until it finished.
    mutating func shouldReport(bytes: Int64) -> Bool {
        let currentTime = now()
        guard let lastReportedTime else {
            self.lastReportedTime = currentTime
            lastReportedBytes = bytes
            return true
        }

        // Never publish a sample that would move the count backwards; a stale out-of-order sample
        // is worse than no sample.
        guard bytes > lastReportedBytes else {
            return false
        }

        let bytesElapsed = bytes - lastReportedBytes
        let timeElapsed = currentTime - lastReportedTime
        guard bytesElapsed >= byteThreshold || timeElapsed >= timeThreshold else {
            return false
        }

        self.lastReportedTime = currentTime
        lastReportedBytes = bytes
        return true
    }
}

/// Reference wrapper so the coalescer can be mutated from an escaping, non-isolated progress
/// callback without the callback having to be `mutating` or actor-isolated.
///
/// `NSLock` rather than an actor: `shouldReport` is called on the transfer's own I/O path for
/// every read, and making that path `await` a separate actor would reintroduce exactly the hop
/// this type exists to remove.
final class ProgressCoalescerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var coalescer: ProgressCoalescer

    init(_ coalescer: ProgressCoalescer = ProgressCoalescer()) {
        self.coalescer = coalescer
    }

    func shouldReport(bytes: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return coalescer.shouldReport(bytes: bytes)
    }
}
