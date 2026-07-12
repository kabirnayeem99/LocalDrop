import SwiftUI
import DesignSystem

struct IncomingRequestSheet: View {
    let request: IncomingTransferRequest
    let onDecline: () -> Void
    let onAcceptAll: () -> Void
    let onAcceptSelection: (Set<String>) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    @State private var selectedFileIDs: Set<String> = []
    @State private var appeared = false
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    private var selectionState: IncomingRequestSelectionState {
        IncomingRequestSelectionState(selectedCount: selectedFileIDs.count, totalCount: request.files.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.xs) {
                    SelectionSummaryBadge(selectionState: selectionState)
                    Spacer(minLength: 0)
                    Button(selectionToggleTitle, action: toggleSelectAll)
                        .buttonStyle(.plain)
                        .font(Typography.callout.weight(.semibold))
                        .foregroundStyle(accentTheme.primary)
                        .disabled(request.files.isEmpty)
                }

                VStack(spacing: 0) {
                ForEach(Array(request.files.enumerated()), id: \.element.id) { index, file in
                    Button {
                        toggleSelection(file.id)
                    } label: {
                        HStack(spacing: Spacing.xs + Spacing.xxs) {
                            Image(systemName: selectedFileIDs.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(selectedFileIDs.contains(file.id) ? accentTheme.primary : .secondary)
                                .frame(width: 20)
                            Image(systemName: file.symbol)
                                .font(.system(size: 15))
                                .foregroundStyle(selectedFileIDs.contains(file.id) ? accentTheme.primary : .secondary)
                                .frame(width: 20)
                            Text(file.name)
                                .font(Typography.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(file.size)
                                .font(Typography.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs + 2)
                        .background(
                            selectedFileIDs.contains(file.id) ? accentTheme.primarySubtleFill : Color.clear,
                            in: RoundedRectangle.continuous(Radius.md)
                        )
                        .overlay {
                            RoundedRectangle.continuous(Radius.md)
                                .strokeBorder(
                                    selectedFileIDs.contains(file.id)
                                        ? accentTheme.primary.opacity(0.18)
                                        : Color.clear,
                                    lineWidth: 0.5
                                )
                        }
                        .contentShape(RoundedRectangle.continuous(Radius.md))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(file.name))
                    .accessibilityValue(Text(selectedFileIDs.contains(file.id) ? "Selected" : "Not selected"))
                    .accessibilityHint(Text("incomingRequest.fileSelectionHint"))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: reduceMotion || appeared ? 0 : 8)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.2).delay(Double(index) * 0.04),
                        value: appeared
                    )
                    .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.84), value: selectedFileIDs)

                    if index < request.files.count - 1 {
                        Divider()
                    }
                }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle.continuous(Radius.lg))
                .overlay {
                    RoundedRectangle.continuous(Radius.lg)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
            }
            .padding(.top, Spacing.md + 2)

            HStack(spacing: Spacing.xs + Spacing.xxs) {
                Button(action: onDecline) {
                    Text("incomingRequest.decline").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(action: acceptSelectedFiles) {
                    Text(acceptTitle).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(accentTheme.primary)
                .disabled(request.files.isEmpty == false && selectedFileIDs.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Spacing.md + 2)
        }
        .padding(Spacing.xl)
        .frame(width: 400)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.98)
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appeared)
        .onAppear {
            selectedFileIDs = Set(request.files.map(\.id))
            appeared = true
        }
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            RoundedRectangle.continuous(Radius.xxl)
                .fill(accentTheme.primarySubtleFill)
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: request.sourceKind.symbol)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(accentTheme.primary)
                }
                .scaleEffect(appeared && !reduceMotion ? 1.04 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: appeared)

            VStack(spacing: Spacing.xxs) {
                Text(String(format: String(localized: .init("incomingRequest.titleFormat"), bundle: .module), request.deviceName))
                    .font(Typography.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(request.subtitle)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Spacing.sm) {
                Label("incomingRequest.fromDevice", systemImage: request.sourceKind.symbol)
                    .font(Typography.subheadline.weight(.semibold))
                    .foregroundStyle(accentTheme.primary)
                Spacer(minLength: 0)
                Text(request.deviceName)
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(accentTheme.primarySubtleFill, in: RoundedRectangle.continuous(Radius.lg))
            .overlay {
                RoundedRectangle.continuous(Radius.lg)
                    .strokeBorder(accentTheme.primary.opacity(0.14), lineWidth: 0.5)
            }
        }
    }

    private var acceptTitle: String {
        guard request.files.isEmpty == false else { return String(localized: .init("incomingRequest.accept"), bundle: .module) }
        return selectionState.acceptsAll
            ? String(localized: .init("incomingRequest.accept"), bundle: .module)
            : String(localized: .init("incomingRequest.acceptSelected"), bundle: .module)
    }

    private var selectionToggleTitle: LocalizedStringKey {
        switch selectionState {
        case .all:
            return "incomingRequest.clearSelection"
        case .none, .partial:
            return "incomingRequest.selectAll"
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }

    private func toggleSelectAll() {
        switch selectionState {
        case .all:
            selectedFileIDs.removeAll()
        case .none, .partial:
            selectedFileIDs = Set(request.files.map(\.id))
        }
    }

    private func acceptSelectedFiles() {
        if selectionState.acceptsAll {
            onAcceptAll()
        } else {
            onAcceptSelection(selectedFileIDs)
        }
    }
}

private struct SelectionSummaryBadge: View {
    let selectionState: IncomingRequestSelectionState

    @Environment(\.accentTheme) private var accentTheme

    var body: some View {
        Text(label)
            .font(Typography.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs + 1)
            .background(fill, in: Capsule())
    }

    private var label: String {
        switch selectionState {
        case .all(let totalCount):
            return String(format: String(localized: .init("incomingRequest.selectionAll"), bundle: .module), totalCount)
        case .partial(let selectedCount, let totalCount):
            return String(
                format: String(localized: .init("incomingRequest.selectionPartial"), bundle: .module),
                selectedCount,
                totalCount
            )
        case .none:
            return String(localized: .init("incomingRequest.selectionNone"), bundle: .module)
        }
    }

    private var tint: Color {
        switch selectionState {
        case .all:
            return accentTheme.primary
        case .partial:
            return SemanticColor.pending
        case .none:
            return SemanticColor.destructive
        }
    }

    private var fill: Color {
        switch selectionState {
        case .all:
            return accentTheme.primarySubtleFill
        case .partial:
            return SemanticColor.pendingSubtleFill
        case .none:
            return SemanticColor.destructiveSubtleFill
        }
    }
}
