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

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.xxs) {
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
                    .padding(.bottom, Spacing.sm - Spacing.xxs)

                Text(String(format: String(localized: .init("incomingRequest.titleFormat"), bundle: .module), request.deviceName))
                    .font(Typography.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(request.subtitle)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
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
                                .foregroundStyle(accentTheme.primary)
                                .frame(width: 20)
                            Text(file.name)
                                .font(Typography.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(file.size)
                                .font(Typography.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs + 2)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: reduceMotion || appeared ? 0 : 8)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.2).delay(Double(index) * 0.04),
                        value: appeared
                    )

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
            .padding(.top, Spacing.md + 2)

            HStack(spacing: Spacing.xs + Spacing.xxs) {
                Button(action: onDecline) {
                    Text("incomingRequest.decline").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)

                Button(action: acceptSelectedFiles) {
                    Text(acceptTitle).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(accentTheme.primary)
                .disabled(request.files.isEmpty == false && selectedFileIDs.isEmpty)
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

    private var acceptTitle: String {
        guard request.files.isEmpty == false else { return String(localized: .init("incomingRequest.accept"), bundle: .module) }
        return selectedFileIDs.count == request.files.count
            ? String(localized: .init("incomingRequest.accept"), bundle: .module)
            : String(localized: .init("incomingRequest.acceptSelected"), bundle: .module)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }

    private func acceptSelectedFiles() {
        if selectedFileIDs.count == request.files.count {
            onAcceptAll()
        } else {
            onAcceptSelection(selectedFileIDs)
        }
    }
}
