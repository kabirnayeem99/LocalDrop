import SwiftUI
import DesignSystem

struct IncomingRequestSheet: View {
    let request: IncomingTransferRequest
    let onDecline: () -> Void
    let onAcceptAll: () -> Void
    let onAcceptSelection: (Set<String>, [String: String]) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    @State private var selectedFileIDs: Set<String> = []
    /// fileID -> the text currently in that row's rename field. Only rows the user actually opened
    /// have an entry; the map is filtered down to *real* renames by `desiredNames`.
    @State private var editedNames: [String: String] = [:]
    /// The one row whose name is currently an editable field. Renaming is deliberately opt-in per
    /// row: the common case is accepting unchanged, so a plain Accept must stay a single click.
    @State private var editingFileID: String?
    @FocusState private var focusedFileID: String?
    @State private var appeared = false
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    private var selectionState: IncomingRequestSelectionState {
        IncomingRequestSelectionState(selectedCount: selectedFileIDs.count, totalCount: request.files.count)
    }

    /// fileID -> receiver-chosen name, for accepted rows only, excluding no-op edits and
    /// blank/whitespace-only text (which means "keep the sender's name", and which `LocalSendKit`
    /// would fall back on anyway).
    private var desiredNames: [String: String] {
        var names: [String: String] = [:]
        for file in request.files where selectedFileIDs.contains(file.id) {
            guard let edited = editedNames[file.id] else { continue }
            let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, trimmed != file.name else { continue }
            names[file.id] = trimmed
        }
        return names
    }

    /// A typed name that `LocalSendKit`'s traversal guard would refuse. Such a name makes
    /// destination resolution return nil and the file is dropped from the batch entirely — the user
    /// hits Accept and the file simply never arrives, with no error and no row. So the sheet
    /// refuses it up front instead.
    ///
    /// A blank field is valid: it means "keep the sender's name", which is what `desiredNames`
    /// already does with it.
    static func isAcceptableDesiredName(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return true }
        guard trimmed.contains("/") == false, trimmed.contains("\\") == false else { return false }
        // Covers ".." as well as any other dotfile-shaped name.
        return trimmed.hasPrefix(".") == false
    }

    private func hasInvalidName(_ file: IncomingTransferFile) -> Bool {
        guard let edited = editedNames[file.id] else { return false }
        return Self.isAcceptableDesiredName(edited) == false
    }

    /// Only *selected* rows can block Accept: a deselected row's name never leaves the sheet.
    private var hasBlockingInvalidName: Bool {
        request.files.contains { selectedFileIDs.contains($0.id) && hasInvalidName($0) }
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
                        .appFont(.text(.callout, .semibold))
                        .foregroundStyle(accentTheme.primary)
                        .disabled(request.files.isEmpty)
                }

                VStack(spacing: 0) {
                ForEach(Array(request.files.enumerated()), id: \.element.id) { index, file in
                    fileRow(file)
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
                    Text(FeatureTransferLocalization.resource("incomingRequest.decline")).frame(maxWidth: .infinity)
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
                .disabled(request.files.isEmpty == false && (selectedFileIDs.isEmpty || hasBlockingInvalidName))
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

    /// One file row.
    ///
    /// The rename field cannot live inside the selection `Button`'s label — a nested control there
    /// never sees the click — so the row swaps between two layouts instead: the normal one (the
    /// whole row is the selection button, plus a trailing rename affordance) and the editing one
    /// (static indicators, a field, and a commit button). The padding/background/border are applied
    /// once, outside the swap, so both look identical.
    @ViewBuilder
    private func fileRow(_ file: IncomingTransferFile) -> some View {
        let isSelected = selectedFileIDs.contains(file.id)
        let isNameInvalid = hasInvalidName(file)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs + Spacing.xxs) {
                if editingFileID == file.id {
                    rowIndicators(file, isSelected: isSelected)
                    // The `String` overload, not the `LocalizedStringResource` one (macOS 26+): the
                    // string is already resolved by `FeatureTransferLocalization`.
                    TextField(
                        FeatureTransferLocalization.string(forKey: "incomingRequest.rename"),
                        text: renameBinding(for: file)
                    )
                    .textFieldStyle(.roundedBorder)
                    .appFont(.body)
                    .focused($focusedFileID, equals: file.id)
                    .onSubmit { endRenaming() }
                    .accessibilityLabel(Text(FeatureTransferLocalization.resource("incomingRequest.rename")))

                    Button(action: endRenaming) {
                        Text(FeatureTransferLocalization.resource("transfer.progress.done"))
                    }
                    .buttonStyle(.plain)
                    .appFont(.text(.callout, .semibold))
                    .foregroundStyle(accentTheme.primary)
                } else {
                    Button {
                        toggleSelection(file.id)
                    } label: {
                        HStack(spacing: Spacing.xs + Spacing.xxs) {
                            rowIndicators(file, isSelected: isSelected)
                            Text(displayName(for: file))
                                .appFont(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(file.size)
                                .appFont(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(displayName(for: file)))
                    .accessibilityValue(Text(isSelected
                        ? FeatureTransferLocalization.resource("incomingRequest.fileSelected")
                        : FeatureTransferLocalization.resource("incomingRequest.fileNotSelected")))
                    .accessibilityHint(Text(FeatureTransferLocalization.resource("incomingRequest.fileSelectionHint")))

                    Button {
                        beginRenaming(file)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(FeatureTransferLocalization.resource("incomingRequest.rename")))
                    .accessibilityLabel(Text(FeatureTransferLocalization.resource("incomingRequest.rename")))
                }
            }

            if isNameInvalid {
                Label(
                    FeatureTransferLocalization.resource("incomingRequest.invalidName"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .appFont(.text(.caption, .semibold))
                .foregroundStyle(SemanticColor.destructive)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 40)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs + 2)
        .background(
            isSelected ? accentTheme.primarySubtleFill : Color.clear,
            in: RoundedRectangle.continuous(Radius.md)
        )
        .overlay {
            RoundedRectangle.continuous(Radius.md)
                .strokeBorder(
                    isSelected ? accentTheme.primary.opacity(0.18) : Color.clear,
                    lineWidth: 0.5
                )
        }
    }

    private func rowIndicators(_ file: IncomingTransferFile, isSelected: Bool) -> some View {
        Group {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? accentTheme.primary : .secondary)
                .frame(width: 20)
            Image(systemName: file.symbol)
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? accentTheme.primary : .secondary)
                .frame(width: 20)
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
                Text(FeatureTransferLocalization.format("incomingRequest.titleFormat", request.deviceName))
                    .appFont(.text(.title3, .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(request.subtitle)
                    .appFont(.body)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Spacing.sm) {
                Label(FeatureTransferLocalization.resource("incomingRequest.fromDevice"), systemImage: request.sourceKind.symbol)
                    .appFont(.text(.subheadline, .semibold))
                    .foregroundStyle(accentTheme.primary)
                Spacer(minLength: 0)
                Text(request.deviceName)
                    .appFont(.text(.callout, .semibold))
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
        guard request.files.isEmpty == false else { return FeatureTransferLocalization.string(forKey: "incomingRequest.accept") }
        return selectionState.acceptsAll
            ? FeatureTransferLocalization.string(forKey: "incomingRequest.accept")
            : FeatureTransferLocalization.string(forKey: "incomingRequest.acceptSelected")
    }

    private var selectionToggleTitle: LocalizedStringResource {
        switch selectionState {
        case .all:
            return FeatureTransferLocalization.resource("incomingRequest.clearSelection")
        case .none, .partial:
            return FeatureTransferLocalization.resource("incomingRequest.selectAll")
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

    /// The name shown on the row: what the user typed, or the sender's name while the edit is blank
    /// (so a cleared field reads as "unchanged", which is exactly what it means downstream).
    private func displayName(for file: IncomingTransferFile) -> String {
        guard let edited = editedNames[file.id],
              edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return file.name
        }
        return edited
    }

    private func renameBinding(for file: IncomingTransferFile) -> Binding<String> {
        Binding(
            get: { editedNames[file.id] ?? file.name },
            set: { editedNames[file.id] = $0 }
        )
    }

    /// Renaming a row implies wanting it: a user who renames a deselected file and then hits Accept
    /// would otherwise watch their edit silently evaporate.
    private func beginRenaming(_ file: IncomingTransferFile) {
        selectedFileIDs.insert(file.id)
        if editedNames[file.id] == nil {
            editedNames[file.id] = file.name
        }
        editingFileID = file.id
        focusedFileID = file.id
    }

    private func endRenaming() {
        editingFileID = nil
        focusedFileID = nil
    }

    private func acceptSelectedFiles() {
        let names = desiredNames
        // `acceptAll` carries no rename map, so an all-selected accept that *does* carry renames has
        // to go out as a subset of everything. The store logs and reports it as a full accept
        // anyway, since the accepted count still equals the offered count.
        if selectionState.acceptsAll, names.isEmpty {
            onAcceptAll()
        } else {
            onAcceptSelection(selectedFileIDs, names)
        }
    }
}

private struct SelectionSummaryBadge: View {
    let selectionState: IncomingRequestSelectionState

    @Environment(\.accentTheme) private var accentTheme

    var body: some View {
        Text(label)
            .appFont(.text(.subheadline, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs + 1)
            .background(fill, in: Capsule())
    }

    private var label: String {
        switch selectionState {
        case .all(let totalCount):
            return FeatureTransferLocalization.format("incomingRequest.selectionAll", totalCount)
        case .partial(let selectedCount, let totalCount):
            return FeatureTransferLocalization.format("incomingRequest.selectionPartial", selectedCount, totalCount)
        case .none:
            return FeatureTransferLocalization.string(forKey: "incomingRequest.selectionNone")
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
