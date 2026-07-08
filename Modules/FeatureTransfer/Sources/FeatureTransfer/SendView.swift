import SwiftUI
import DesignSystem
import UniformTypeIdentifiers

struct SendView: View {
    @Bindable var store: TransferFeatureStore

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    @State private var dropZoneState: DropZoneInteractionState = .idle
    @State private var dropZoneResetTask: Task<Void, Never>?
    @State private var dropZoneStateToken = 0
    @State private var selectedSelectionType = "File"

    private let selectionTypes: [(symbol: String, label: String)] = [
        ("doc", "File"),
        ("folder", "Folder"),
        ("text.alignleft", "Text"),
        ("doc.on.clipboard", "Paste")
    ]

    private let columns = [GridItem(.flexible(), spacing: Spacing.sm), GridItem(.flexible(), spacing: Spacing.sm)]
    private let selectionColumns = Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Selection")

                LazyVGrid(columns: selectionColumns, spacing: Spacing.sm) {
                    ForEach(selectionTypes, id: \.label) { type in
                        SelectionTypeButton(
                            symbol: type.symbol,
                            label: type.label,
                            isSelected: selectedSelectionType == type.label
                        ) {
                            selectedSelectionType = type.label
                        }
                    }
                }
                .padding(.top, Spacing.sm)

                if let staged = store.stagedItems.first {
                    StagedFileChip(file: staged) { store.removeStagedItem(id: staged.id) }
                        .padding(.top, Spacing.sm + Spacing.xxs)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                }

                HStack {
                    Text("Nearby devices")
                        .font(Typography.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 0) {
                        Button { store.refreshNearbyPeers() } label: {
                            RefreshIcon(isRefreshing: store.isRefreshingDiscovery)
                        }
                        .help(store.isRefreshingDiscovery ? "Refreshing discovery" : "Refresh")
                        .disabled(store.isRefreshingDiscovery)
                        Button { store.scanNearbyPeers() } label: {
                            ScanIcon(isScanning: store.isScanningDiscovery)
                        }
                        .help(store.isScanningDiscovery ? "Scanning for nearby devices" : "Scan")
                        .disabled(store.isScanningDiscovery)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)
                }
                .padding(.top, Spacing.xl + Spacing.xxs)

                if store.nearbyPeers.isEmpty {
                    NearbyDevicesEmptyState()
                        .padding(.top, Spacing.sm)
                } else {
                    LazyVGrid(columns: columns, spacing: Spacing.sm) {
                        ForEach(store.nearbyPeers) { device in
                            DeviceCardView(device: device) {
                                store.send(to: device.id)
                            }
                        }
                    }
                    .padding(.top, Spacing.sm)
                }

                DropZoneView(
                    state: dropZoneState,
                    systemImage: "arrow.up.doc",
                    label: "Drag files or folders anywhere to send"
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
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Typography.headline)
            .foregroundStyle(.primary)
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
}

private struct SelectionTypeButton: View {
    let symbol: String
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xs + Spacing.xxs) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(isSelected ? .white : AccentColor.primary)
                Text(label)
                    .font(Typography.headline)
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.lg)
            .background(
                isSelected ? AnyShapeStyle(AccentColor.primary) : AnyShapeStyle(.background),
                in: RoundedRectangle.continuous(Radius.xl)
            )
            .overlay {
                RoundedRectangle.continuous(Radius.xl)
                    .strokeBorder(
                        isSelected || hovering ? AccentColor.primary.opacity(0.55) : Color(nsColor: .separatorColor),
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
                Circle()
                    .stroke(SemanticColor.discovery.opacity(0.3), lineWidth: 1)
                    .frame(width: 18, height: 18)
                    .scaleEffect(1.25)
                    .opacity(0.7)
            }
            Image(systemName: "dot.radiowaves.left.and.right")
        }
    }
}

private struct NearbyDevicesEmptyState: View {
    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(SemanticColor.discoverySubtleFill)
                    .frame(width: 52, height: 52)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SemanticColor.discovery)
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("No nearby devices")
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                Text("Refresh discovery or keep this screen open while another device starts LocalDrop.")
                    .font(Typography.callout)
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
}

private struct StagedFileChip: View {
    let file: StagedTransferItem
    let onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    // Starts flashed so the accent tint is the first rendered frame, then
    // settles back to the resting fill once the chip appears.
    @State private var justStaged = true

    var body: some View {
        HStack(spacing: Spacing.sm) {
            RoundedRectangle.continuous(Radius.md)
                .fill(justStaged ? AnyShapeStyle(AccentColor.primary.opacity(0.22)) : AnyShapeStyle(.background))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: file.fileTypeSymbol)
                        .font(.system(size: 18))
                        .foregroundStyle(AccentColor.primary)
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
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
                Text(file.subtitle)
                    .font(Typography.callout)
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
        }
        .padding(.horizontal, Spacing.md - Spacing.xxs)
        .padding(.vertical, Spacing.sm)
        .background(AccentColor.primarySubtleFill, in: RoundedRectangle.continuous(Radius.xl))
        .overlay {
            RoundedRectangle.continuous(Radius.xl)
                .strokeBorder(AccentColor.primary.opacity(0.14), lineWidth: 0.5)
        }
    }
}
