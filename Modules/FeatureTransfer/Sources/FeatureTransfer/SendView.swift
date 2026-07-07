import SwiftUI
import DesignSystem
import UniformTypeIdentifiers

struct SendView: View {
    @Bindable var store: TransferFeatureStore

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
                        SelectionTypeButton(symbol: type.symbol, label: type.label)
                    }
                }
                .padding(.top, Spacing.sm)

                if let staged = store.stagedItems.first {
                    StagedFileChip(file: staged) { store.removeStagedItem(id: staged.id) }
                        .padding(.top, Spacing.sm + Spacing.xxs)
                }

                HStack {
                    Text("Nearby devices")
                        .font(Typography.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 0) {
                        Button { store.refreshNearbyPeers() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh")
                        Button { store.refreshNearbyPeers() } label: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                        .help("Scan")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)
                }
                .padding(.top, Spacing.xl + Spacing.xxs)

                LazyVGrid(columns: columns, spacing: Spacing.sm) {
                    ForEach(store.nearbyPeers) { device in
                        DeviceCardView(device: device) {
                            store.send(to: device.id)
                        }
                    }
                }
                .padding(.top, Spacing.sm)

                DropZoneView(
                    isTargeted: false,
                    systemImage: "arrow.up.doc",
                    label: "Drag files or folders anywhere to send"
                )
                .frame(minHeight: 80)
                .padding(.top, Spacing.md)
                .dropDestination(for: URL.self) { urls, _ in
                    guard urls.isEmpty == false else { return false }
                    store.stageDroppedItems(urls)
                    return true
                } isTargeted: { _ in
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, Spacing.xl + Spacing.xxs)
            .padding(.bottom, Spacing.xxxl - Spacing.xs)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Typography.headline)
            .foregroundStyle(.primary)
    }
}

private struct SelectionTypeButton: View {
    let symbol: String
    let label: String
    @State private var hovering = false

    var body: some View {
        Button { } label: {
            VStack(spacing: Spacing.xs + Spacing.xxs) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(AccentColor.primary)
                Text(label)
                    .font(Typography.headline)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.lg)
            .background(.background, in: RoundedRectangle.continuous(Radius.xl))
            .overlay {
                RoundedRectangle.continuous(Radius.xl)
                    .strokeBorder(
                        hovering ? AccentColor.primary.opacity(0.4) : Color(nsColor: .separatorColor),
                        lineWidth: hovering ? 1 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct StagedFileChip: View {
    let file: StagedTransferItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            RoundedRectangle.continuous(Radius.md)
                .fill(.background)
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
