import Foundation

actor TransferProgressReducer {
    private struct State: Sendable {
        var snapshot: ActiveTransferProgress
        var lastActualTransferredBytes: Int64
        var lastSpeedSampleTime: TimeInterval
        var lastSpeedSampleBytes: Int64
        var smoothedBytesPerSecond: Double?
        var hasSpeedSample = false
        var lastPositiveByteTime: TimeInterval
    }

    private let alpha: Double
    private let minimumSpeedForETA: Double
    private let stalledInterval: TimeInterval
    private var state: State?

    init(
        alpha: Double = 0.2,
        minimumSpeedForETA: Double = 1,
        stalledInterval: TimeInterval = 2
    ) {
        self.alpha = alpha
        self.minimumSpeedForETA = minimumSpeedForETA
        self.stalledInterval = stalledInterval
    }

    func reset() {
        state = nil
    }

    func reduce(_ event: TransferProgressRawEvent) -> ActiveTransferProgress {
        let previousState = state
        let previousSnapshot = previousState?.snapshot
        let isSameTransfer = previousSnapshot?.id == event.transferID
        let startedAt = previousSnapshot.map { snapshot in
            if isSameTransfer, snapshot.attemptID == event.attemptID {
                return snapshot.startedAtMonotonic
            }
            return event.eventMonotonicTime
        } ?? event.eventMonotonicTime

        let mergedFiles = mergeFiles(
            rawFiles: event.files,
            previousFiles: isSameTransfer ? (previousSnapshot?.files ?? []) : [],
            status: status(for: event.kind)
        )
        let totalBytesKnown = resolvedTotalBytesKnown(
            explicitTotal: event.totalBytesKnown,
            files: mergedFiles,
            status: status(for: event.kind)
        )
        let contributedBytes = mergedFiles.reduce(into: Int64.zero) { partialResult, file in
            partialResult += contribution(for: file)
        }
        let previousDisplayBytes = isSameTransfer ? (previousSnapshot?.displayableTransferredBytes ?? 0) : 0
        let displayableTransferredBytes = max(previousDisplayBytes, contributedBytes)
        let actualTransferredBytes = max(event.actualTransferredBytes, 0)

        let speedState = reduceSpeed(
            previous: isSameTransfer ? previousState : nil,
            currentDisplayableBytes: displayableTransferredBytes,
            eventTime: event.eventMonotonicTime
        )
        let snapshot = ActiveTransferProgress(
            id: event.transferID,
            attemptID: event.attemptID,
            direction: event.direction,
            counterpartName: event.counterpartName,
            counterpartKind: event.counterpartKind,
            status: status(for: event.kind),
            files: mergedFiles,
            totalBytesKnown: totalBytesKnown,
            displayableTransferredBytes: displayableTransferredBytes,
            actualTransferredBytes: actualTransferredBytes,
            smoothedBytesPerSecond: speedState.smoothedBytesPerSecond,
            eta: makeETA(
                status: status(for: event.kind),
                totalBytesKnown: totalBytesKnown,
                displayableTransferredBytes: displayableTransferredBytes,
                smoothedBytesPerSecond: speedState.smoothedBytesPerSecond,
                lastPositiveByteTime: speedState.lastPositiveByteTime,
                eventTime: event.eventMonotonicTime,
                hasSpeedSample: speedState.hasSpeedSample
            ),
            startedAtMonotonic: startedAt,
            lastProgressAtMonotonic: event.eventMonotonicTime
        )

        state = State(
            snapshot: snapshot,
            lastActualTransferredBytes: actualTransferredBytes,
            lastSpeedSampleTime: speedState.lastSpeedSampleTime,
            lastSpeedSampleBytes: speedState.lastSpeedSampleBytes,
            smoothedBytesPerSecond: speedState.smoothedBytesPerSecond,
            hasSpeedSample: speedState.hasSpeedSample,
            lastPositiveByteTime: speedState.lastPositiveByteTime
        )
        return snapshot
    }

    private func mergeFiles(
        rawFiles: [TransferProgressRawFile],
        previousFiles: [TransferFileProgress],
        status: ActiveTransferProgress.Status
    ) -> [TransferFileProgress] {
        let previousByID = Dictionary(uniqueKeysWithValues: previousFiles.map { ($0.id, $0) })
        return rawFiles.map { raw in
            let previous = previousByID[raw.fileID]
            let displayedTransferredBytes = max(previous?.displayedTransferredBytes ?? 0, raw.actualTransferredBytes)
            let effectiveTotal = effectiveTotal(
                declaredTotalBytes: raw.declaredTotalBytes,
                displayedTransferredBytes: displayedTransferredBytes
            )
            let completedContribution = max(
                previous?.completedBytesContribution ?? 0,
                raw.state == .completed ? terminalContribution(total: effectiveTotal, transferred: displayedTransferredBytes) : 0
            )
            let failedContribution = max(
                previous?.failedBytesContribution ?? 0,
                (raw.state == .failed || raw.state == .canceled) ? displayedTransferredBytes : 0
            )
            let resolvedStatus: TransferFileProgress.Status
            if status == .completed, raw.state == .queued {
                resolvedStatus = .completed
            } else if status == .failed, raw.state == .queued {
                resolvedStatus = .failed
            } else if status == .canceled, raw.state == .queued {
                resolvedStatus = .canceled
            } else {
                resolvedStatus = raw.state
            }

            return TransferFileProgress(
                id: raw.fileID,
                fileName: raw.displayName,
                attemptIndex: raw.attemptIndex,
                status: resolvedStatus,
                totalBytes: raw.declaredTotalBytes,
                effectiveTotalBytesForDisplay: effectiveTotal,
                actualTransferredBytes: raw.actualTransferredBytes,
                displayedTransferredBytes: displayedTransferredBytes,
                completedBytesContribution: completedContribution,
                failedBytesContribution: failedContribution,
                lastEventSequence: raw.attemptIndex == 0 ? 0 : Int64(raw.attemptIndex),
                lastProgressAtMonotonic: previous?.lastProgressAtMonotonic ?? 0,
                errorSummary: raw.errorSummary,
                fileURL: raw.fileURL,
                order: raw.order
            )
        }
    }

    private func contribution(for file: TransferFileProgress) -> Int64 {
        switch file.status {
        case .completed:
            return terminalContribution(total: file.effectiveTotalBytesForDisplay, transferred: file.displayedTransferredBytes)
        case .failed, .canceled:
            return max(file.failedBytesContribution, file.displayedTransferredBytes)
        case .transferring, .retrying:
            if let total = file.effectiveTotalBytesForDisplay {
                return min(max(file.displayedTransferredBytes, file.completedBytesContribution), total)
            }
            return max(file.displayedTransferredBytes, file.completedBytesContribution)
        case .queued:
            return 0
        }
    }

    private func terminalContribution(total: Int64?, transferred: Int64) -> Int64 {
        if let total, total > 0 {
            return max(total, transferred)
        }
        return transferred
    }

    private func effectiveTotal(declaredTotalBytes: Int64?, displayedTransferredBytes: Int64) -> Int64? {
        guard let declaredTotalBytes, declaredTotalBytes > 0 else { return nil }
        return max(declaredTotalBytes, displayedTransferredBytes)
    }

    private func resolvedTotalBytesKnown(
        explicitTotal: Int64?,
        files: [TransferFileProgress],
        status: ActiveTransferProgress.Status
    ) -> Int64? {
        if let explicitTotal, explicitTotal > 0 {
            return max(explicitTotal, files.reduce(0) { $0 + ($1.effectiveTotalBytesForDisplay ?? 0) })
        }
        let knownTotals = files.compactMap(\.effectiveTotalBytesForDisplay)
        guard knownTotals.count == files.count else {
            return status == .completed ? files.reduce(0) { $0 + max($1.displayedTransferredBytes, $1.effectiveTotalBytesForDisplay ?? 0) } : nil
        }
        return knownTotals.reduce(0, +)
    }

    private func status(for kind: TransferProgressRawEvent.Kind) -> ActiveTransferProgress.Status {
        switch kind {
        case .transferStarted, .snapshot:
            return .running
        case .transferCompleted:
            return .completed
        case .transferFailed:
            return .failed
        case .transferCanceled:
            return .canceled
        }
    }

    private func reduceSpeed(
        previous: State?,
        currentDisplayableBytes: Int64,
        eventTime: TimeInterval
    ) -> (
        lastSpeedSampleTime: TimeInterval,
        lastSpeedSampleBytes: Int64,
        smoothedBytesPerSecond: Double?,
        hasSpeedSample: Bool,
        lastPositiveByteTime: TimeInterval
    ) {
        guard let previous else {
            return (eventTime, currentDisplayableBytes, nil, false, eventTime)
        }

        let deltaTime = eventTime - previous.lastSpeedSampleTime
        let deltaBytes = currentDisplayableBytes - previous.lastSpeedSampleBytes
        var smoothed = previous.smoothedBytesPerSecond
        var hasSample = previous.hasSpeedSample
        var lastPositiveByteTime = previous.lastPositiveByteTime

        if deltaTime > 0, deltaBytes > 0 {
            let instantaneous = Double(deltaBytes) / deltaTime
            smoothed = smoothed.map { ($0 * (1 - alpha)) + (instantaneous * alpha) } ?? instantaneous
            hasSample = true
            lastPositiveByteTime = eventTime
        }

        return (eventTime, currentDisplayableBytes, smoothed, hasSample, lastPositiveByteTime)
    }

    private func makeETA(
        status: ActiveTransferProgress.Status,
        totalBytesKnown: Int64?,
        displayableTransferredBytes: Int64,
        smoothedBytesPerSecond: Double?,
        lastPositiveByteTime: TimeInterval,
        eventTime: TimeInterval,
        hasSpeedSample: Bool
    ) -> TransferETA {
        guard status == .running else { return .none }
        guard let totalBytesKnown, totalBytesKnown > 0 else {
            return .none
        }
        guard hasSpeedSample else {
            return .calculating
        }
        if eventTime - lastPositiveByteTime >= stalledInterval {
            return .stalled
        }
        guard let smoothedBytesPerSecond, smoothedBytesPerSecond >= minimumSpeedForETA else {
            return .calculating
        }
        let remaining = max(totalBytesKnown - displayableTransferredBytes, 0)
        guard remaining > 0 else { return .none }
        return .estimated(seconds: Double(remaining) / smoothedBytesPerSecond)
    }
}
