import SwiftUI
import DesignSystem
import UniformTypeIdentifiers

struct SendView: View {
    @Bindable var store: TransferFeatureStore
    let actions: SendEntryActions

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    @State private var dropZoneState: DropZoneInteractionState = .idle
    @State private var dropZoneResetTask: Task<Void, Never>?
    @State private var dropZoneStateToken = 0
    @State private var selectedSelectionType: SendEntryKind = .file
    @State private var isSendModeHelpPresented = false

    private let columns = [GridItem(.flexible(), spacing: Spacing.sm), GridItem(.flexible(), spacing: Spacing.sm)]
    private let selectionColumns = Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 4)
    private let stagedItemsMaxHeight: CGFloat = 248
    private var nearbyDevicesPresentationState: NearbyDevicesPresentationState {
        NearbyDevicesPresentationState(
            peerCount: store.nearbyPeers.count,
            isRefreshing: store.isRefreshingDiscovery,
            isScanning: store.isScanningDiscovery
        )
    }

    init(store: TransferFeatureStore, actions: SendEntryActions = .noop) {
        self._store = Bindable(store)
        self.actions = actions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle(FeatureTransferLocalization.resource("send.selectionTitle"))

                LazyVGrid(columns: selectionColumns, spacing: Spacing.sm) {
                    ForEach(SendEntryKind.allCases) { type in
                        SelectionTypeButton(
                            symbol: type.symbol,
                            label: type.labelResource,
                            isSelected: selectedSelectionType == type
                        ) {
                            selectedSelectionType = type
                            type.perform(using: actions)
                        }
                    }
                }
                .padding(.top, Spacing.sm)

                if store.stagedItems.isEmpty == false {
                    stagedItemsSection
                        .padding(.top, Spacing.sm + Spacing.xxs)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                }

                HStack {
                    Text(FeatureTransferLocalization.resource("send.nearbyDevices"))
                        .appFont(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: Spacing.xs) {
                        Menu {
                            ForEach(SendMode.allCases) { mode in
                                Button {
                                    store.selectSendMode(mode)
                                } label: {
                                    if store.sendMode == mode {
                                        Label {
                                            Text(sendModeResource(for: mode))
                                        } icon: {
                                            Image(systemName: "checkmark")
                                        }
                                    } else {
                                        Text(sendModeResource(for: mode))
                                    }
                                }
                            }
                            Divider()
                            Button(FeatureTransferLocalization.resource("send.mode.explanation")) {
                                isSendModeHelpPresented = true
                            }
                        } label: {
                            Label {
                                Text(sendModeResource(for: store.sendMode))
                            } icon: {
                                Image(systemName: sendModeSymbol(for: store.sendMode))
                            }
                        }
                        .help(Text(FeatureTransferLocalization.resource("send.mode.help")))

                        HStack(spacing: 0) {
                        Button { store.refreshNearbyPeers() } label: {
                            RefreshIcon(isRefreshing: store.isRefreshingDiscovery)
                        }
                        .help(Text(FeatureTransferLocalization.resource(store.isRefreshingDiscovery ? "root.refreshingDiscovery" : "root.refresh")))
                        .disabled(store.isRefreshingDiscovery)
                        Button { store.scanNearbyPeers() } label: {
                            ScanIcon(isScanning: store.isScanningDiscovery)
                        }
                        .help(Text(FeatureTransferLocalization.resource(store.isScanningDiscovery ? "send.scanning" : "send.scan")))
                        .disabled(store.isScanningDiscovery)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)
                }
                .padding(.top, Spacing.xl + Spacing.xxs)

                if nearbyDevicesPresentationState == .results {
                    LazyVGrid(columns: columns, spacing: Spacing.sm) {
                        ForEach(store.nearbyPeers) { device in
                            DeviceCardView(device: device) {
                                store.send(to: device.id)
                            }
                        }
                    }
                    .padding(.top, Spacing.sm)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity
                    ))
                } else {
                    NearbyDevicesEmptyState(state: nearbyDevicesPresentationState)
                        .padding(.top, Spacing.sm)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                DropZoneView(
                    state: dropZoneState,
                    systemImage: "arrow.up.doc",
                    acceptedSystemImage: "checkmark.circle.fill",
                    label: resolvedDropZoneLabel
                )
                .frame(minHeight: 80)
                .padding(.top, Spacing.md)
                .dropDestination(for: URL.self) { urls, _ in
                    guard urls.isEmpty == false else {
                        cancelDropZoneReset()
                        dropZoneStateToken += 1
                        dropZoneState = .idle
                        return false
                    }
                    store.stageDroppedItems(urls)
                    flashDropZoneAccepted()
                    return true
                } isTargeted: { targeted in
                    if targeted {
                        cancelDropZoneReset()
                        dropZoneStateToken += 1
                        dropZoneState = .targeted
                    } else if dropZoneState != .accepted {
                        // Don't stomp the accepted flash when the drag exits on drop.
                        cancelDropZoneReset()
                        dropZoneStateToken += 1
                        dropZoneState = .idle
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, Spacing.xl + Spacing.xxs)
            .padding(.bottom, Spacing.xxxl - Spacing.xs)
            .animation(
                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                value: store.stagedItems
            )
        }
        .onDisappear {
            cancelDropZoneReset()
            dropZoneStateToken += 1
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.22),
            value: nearbyDevicesPresentationState
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82),
            value: store.nearbyPeers.map(\.id)
        )
        .sheet(isPresented: $isSendModeHelpPresented) {
            SendModeHelpSheet()
        }
    }

    private func sectionTitle(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .appFont(.headline)
            .foregroundStyle(.primary)
    }

    var resolvedDropZoneLabel: String {
        String(localized: "send.dropZoneLabel", bundle: FeatureTransferLocalization.bundle)
    }

    private var stagedItemsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                sectionTitle(FeatureTransferLocalization.resource("send.stagedItems"))
                Spacer(minLength: 0)
                Text(store.stagedItems.stagedBatchSummaryLabel)
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("send-staged-summary")
            }

            ScrollView {
                LazyVStack(spacing: Spacing.xs + Spacing.xxs) {
                    ForEach(store.stagedItems) { staged in
                        StagedFileChip(file: staged) {
                            store.removeStagedItem(id: staged.id)
                        }
                        .accessibilityIdentifier("send-staged-item-\(staged.name)")
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: stagedItemsScrollHeight)
        }
        .padding(Spacing.md)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle.continuous(Radius.xl))
        .overlay {
            RoundedRectangle.continuous(Radius.xl)
                .strokeBorder(accentTheme.primary.opacity(0.14), lineWidth: 0.5)
        }
    }

    private var stagedItemsScrollHeight: CGFloat {
        let visibleItemCount = min(max(store.stagedItems.count, 1), 4)
        return min(CGFloat(visibleItemCount) * 72, stagedItemsMaxHeight)
    }

    private func flashDropZoneAccepted() {
        cancelDropZoneReset()
        dropZoneStateToken += 1
        let token = dropZoneStateToken
        dropZoneState = .accepted
        dropZoneResetTask = Task {
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if token == dropZoneStateToken, dropZoneState == .accepted {
                    dropZoneState = .idle
                }
                dropZoneResetTask = nil
            }
        }
    }

    private func cancelDropZoneReset() {
        dropZoneResetTask?.cancel()
        dropZoneResetTask = nil
    }

    private func sendModeResource(for mode: SendMode) -> LocalizedStringResource {
        switch mode {
        case .single:
            FeatureTransferLocalization.resource("send.mode.single")
        case .multiple:
            FeatureTransferLocalization.resource("send.mode.multiple")
        case .link:
            FeatureTransferLocalization.resource("send.mode.link")
        }
    }

    private func sendModeSymbol(for mode: SendMode) -> String {
        switch mode {
        case .single:
            "paperplane"
        case .multiple:
            "paperplane.circle"
        case .link:
            "link"
        }
    }
}

private struct SendModeHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(FeatureTransferLocalization.resource("send.mode.sheetTitle"))
                .appFont(.text(.title3, .bold))
            Text(FeatureTransferLocalization.resource("send.mode.singleDescription"))
                .fixedSize(horizontal: false, vertical: true)
            Text(FeatureTransferLocalization.resource("send.mode.multipleDescription"))
                .fixedSize(horizontal: false, vertical: true)
            Text(FeatureTransferLocalization.resource("send.mode.linkDescription"))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(FeatureTransferLocalization.resource("send.mode.close")) {
                    dismiss()
                }
            }
        }
        .padding(Spacing.lg)
        .frame(minWidth: 420)
    }
}

private struct SelectionTypeButton: View {
    let symbol: String
    let label: LocalizedStringResource
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accentTheme) private var accentTheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xs + Spacing.xxs) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(isSelected ? .white : accentTheme.primary)
                Text(label)
                    .appFont(.headline)
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.lg)
            .background(
                isSelected ? AnyShapeStyle(accentTheme.primary) : AnyShapeStyle(.background),
                in: RoundedRectangle.continuous(Radius.xl)
            )
            .overlay {
                RoundedRectangle.continuous(Radius.xl)
                    .strokeBorder(
                        isSelected || hovering ? accentTheme.primary.opacity(0.55) : Color(nsColor: .separatorColor),
                        lineWidth: isSelected || hovering ? 1 : 0.5
                    )
            }
            .scaleEffect(hovering && !isSelected ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct RefreshIcon: View {
    let isRefreshing: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        if isRefreshing, !reduceMotion {
            TimelineView(.animation) { context in
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 360))
            }
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }
}

private struct ScanIcon: View {
    let isScanning: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        ZStack {
            if isScanning, !reduceMotion {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<2, id: \.self) { index in
                            let offset = Double(index) * 0.35
                            let progress = phase.remainder(dividingBy: 0.9) / 0.9
                            let adjustedProgress = (progress + offset).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(SemanticColor.discovery.opacity(0.26 - (Double(index) * 0.06)), lineWidth: 1)
                                .frame(width: 16, height: 16)
                                .scaleEffect(1 + adjustedProgress * 0.7)
                                .opacity(0.75 - adjustedProgress * 0.55)
                        }
                    }
                }
                .frame(width: 20, height: 20)
            }
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(isScanning ? SemanticColor.discovery : .primary)
        }
    }
}

private struct NearbyDevicesEmptyState: View {
    let state: NearbyDevicesPresentationState

    var body: some View {
        HStack(spacing: Spacing.md) {
            icon

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(titleKey)
                    .appFont(.headline)
                    .foregroundStyle(.primary)
                Text(messageKey)
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle.continuous(Radius.xl))
        .overlay {
            RoundedRectangle.continuous(Radius.xl)
                .strokeBorder(SemanticColor.discovery.opacity(0.18), lineWidth: 0.5)
        }
    }

    @ViewBuilder private var icon: some View {
        ZStack {
            Circle()
                .fill(SemanticColor.discoverySubtleFill)
                .frame(width: 52, height: 52)

            if state.isShowingActivity {
                ActivityHalo(symbol: state == .emptyScanning ? "dot.radiowaves.left.and.right" : "arrow.clockwise")
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SemanticColor.discovery)
            }
        }
        .accessibilityHidden(true)
    }

    private var titleKey: LocalizedStringResource {
        switch state {
        case .emptyIdle:
            return FeatureTransferLocalization.resource("send.noDevices")
        case .emptyRefreshing:
            return FeatureTransferLocalization.resource("send.refreshingDevices")
        case .emptyScanning:
            return FeatureTransferLocalization.resource("send.scanningDevices")
        case .results:
            return FeatureTransferLocalization.resource("send.noDevices")
        }
    }

    private var messageKey: LocalizedStringResource {
        switch state {
        case .emptyIdle:
            return FeatureTransferLocalization.resource("send.noDevicesHelp")
        case .emptyRefreshing:
            return FeatureTransferLocalization.resource("send.refreshingDevicesHelp")
        case .emptyScanning:
            return FeatureTransferLocalization.resource("send.scanningDevicesHelp")
        case .results:
            return FeatureTransferLocalization.resource("send.noDevicesHelp")
        }
    }
}

private struct ActivityHalo: View {
    let symbol: String

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        ZStack {
            if reduceMotion == false {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.2) / 1.2
                    Circle()
                        .stroke(SemanticColor.discovery.opacity(0.28), lineWidth: 1)
                        .frame(width: 30, height: 30)
                        .scaleEffect(1 + phase * 0.65)
                        .opacity(0.8 - phase * 0.65)
                }
            }

            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(SemanticColor.discovery)
                .conditionalPulse(active: reduceMotion == false)
        }
    }
}

private extension View {
    @ViewBuilder func conditionalPulse(active: Bool) -> some View {
        if active {
            self.symbolEffect(.pulse, options: .repeating)
        } else {
            self
        }
    }
}

private struct StagedFileChip: View {
    let file: StagedTransferItem
    let onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    // Starts flashed so the accent tint is the first rendered frame, then
    // settles back to the resting fill once the chip appears.
    @State private var justStaged = true

    var body: some View {
        HStack(spacing: Spacing.sm) {
            RoundedRectangle.continuous(Radius.md)
                .fill(justStaged ? AnyShapeStyle(accentTheme.primary.opacity(0.22)) : AnyShapeStyle(.background))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: file.fileTypeSymbol)
                        .font(.system(size: 18))
                        .foregroundStyle(accentTheme.primary)
                }
                .overlay {
                    RoundedRectangle.continuous(Radius.md)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .onAppear {
                    guard !reduceMotion else {
                        justStaged = false
                        return
                    }
                    withAnimation(.easeOut(duration: 0.5).delay(0.08)) {
                        justStaged = false
                    }
                }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(file.name)
                    .appFont(.headline)
                    .foregroundStyle(.primary)
                Text(file.subtitle)
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(nsColor: .systemGray).opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(FeatureTransferLocalization.format("send.removeItem", file.name)))
        }
        .padding(.horizontal, Spacing.md - Spacing.xxs)
        .padding(.vertical, Spacing.sm)
        .background(accentTheme.primarySubtleFill, in: RoundedRectangle.continuous(Radius.xl))
        .overlay {
            RoundedRectangle.continuous(Radius.xl)
                .strokeBorder(accentTheme.primary.opacity(0.14), lineWidth: 0.5)
        }
    }
}
