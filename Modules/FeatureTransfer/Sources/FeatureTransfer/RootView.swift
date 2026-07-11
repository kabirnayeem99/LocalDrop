import SwiftUI
import DesignSystem

struct RootView: View {
    @Bindable private var store: TransferFeatureStore
    private let sendEntryActions: SendEntryActions

    init(store: TransferFeatureStore, sendEntryActions: SendEntryActions = .noop) {
        self._store = Bindable(store)
        self.sendEntryActions = sendEntryActions
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { toolbar }
                .navigationTitle(store.screen.title)
        }
        .environment(\.appReducesMotion, store.reduceMotion)
        .preferredColorScheme(store.appearance.colorScheme)
        .overlay(alignment: .top) {
            if let feedback = store.feedback {
                FeedbackBanner(feedback: feedback)
                    .padding(.top, Spacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(store.reduceMotion ? nil : .easeOut(duration: 0.18), value: store.feedback)
        .sheet(item: presentedSheet) { sheet in
            switch sheet {
            case .incoming(let request):
                IncomingRequestSheet(
                    request: request,
                    onDecline: { store.declineIncomingRequest() },
                    onAcceptAll: { store.acceptIncomingRequest() },
                    onAcceptSelection: { store.acceptIncomingRequest(fileIDs: $0) }
                )
            case .progress(let progress):
                TransferProgressSheet(progress: progress) {
                    store.cancelActiveTransfer()
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $store.screen) {
            Section("Transfer") {
                ForEach(Screen.allCases) { screen in
                    SidebarRow(screen: screen, badgeCount: badgeCount(for: screen))
                        .tag(screen)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(232)
        .safeAreaInset(edge: .top, spacing: 0) {
            sidebarHeader
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ThisDeviceChip(
                deviceName: store.deviceName,
                statusText: store.runtimeStatusText,
                isAvailable: store.isRuntimeAvailable
            )
                .padding(Spacing.sm)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: Spacing.sm - 1) {
            RoundedRectangle.continuous(Radius.md)
                .fill(AccentColor.primary)
                .frame(width: 30, height: 30)
                .overlay {
                    BrandMark(variant: .monoLight)
                        .frame(width: 17, height: 17)
                }
            Text("LocalDrop")
                .font(Typography.title3.weight(.bold))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    @ViewBuilder private var detail: some View {
        switch store.screen {
        case .receive:
            ReceiveView(store: store)
                .accessibilityIdentifier("screen-receive")
        case .send:
            SendView(store: store, actions: sendEntryActions)
                .accessibilityIdentifier("screen-send")
        case .history:
            HistoryView(store: store)
                .accessibilityIdentifier("screen-history")
        case .settings:
            SettingsView(store: store)
                .accessibilityIdentifier("screen-settings")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            RefreshToolbarButton(isRefreshing: store.isRefreshingDiscovery) {
                store.refreshNearbyPeers()
            }

            Button {
                store.screen = .history
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

            Button {
                store.screen = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private func badgeCount(for screen: Screen) -> Int {
        switch screen {
        case .receive:
            return store.incomingRequest == nil ? 0 : 1
        case .send:
            return store.activeTransfer == nil ? 0 : 1
        case .history, .settings:
            return 0
        }
    }

    private var presentedSheet: Binding<PresentedSheet?> {
        Binding(
            get: {
                if let request = store.incomingRequest {
                    return .incoming(request)
                }
                if let progress = store.activeTransfer {
                    return .progress(progress)
                }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if store.incomingRequest != nil {
                    store.declineIncomingRequest()
                }
                if store.activeTransfer != nil {
                    store.dismissProgress()
                }
            }
        )
    }
}

private struct SidebarRow: View {
    let screen: Screen
    let badgeCount: Int

    var body: some View {
        Label {
            HStack(spacing: Spacing.xs) {
                Text(screen.title)
                Spacer(minLength: 0)
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(Typography.caption1.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(SemanticColor.pending, in: Capsule())
                        .accessibilityLabel("\(badgeCount) active item")
                }
            }
        } icon: {
            Image(systemName: screen.symbol)
        }
    }
}

private struct RefreshToolbarButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        Button(action: action) {
            Label {
                Text("Refresh")
            } icon: {
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
        .help(isRefreshing ? "Refreshing discovery" : "Refresh discovery")
        .disabled(isRefreshing)
    }
}

private enum PresentedSheet: Identifiable {
    case incoming(IncomingTransferRequest)
    case progress(ActiveTransferProgress)

    var id: String {
        switch self {
        case .incoming(let request):
            return "incoming-\(request.id)"
        case .progress(let progress):
            return "progress-\(progress.id)"
        }
    }
}

private struct ThisDeviceChip: View {
    let deviceName: String
    let statusText: String
    let isAvailable: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        HStack(spacing: Spacing.xs + Spacing.xxs) {
            RoundedRectangle.continuous(Radius.md)
                .fill(.background)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 17))
                        .foregroundStyle(AccentColor.primary)
                }
                .overlay {
                    RoundedRectangle.continuous(Radius.md)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(deviceName)
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: Spacing.xxs + 1) {
                    RuntimeStatusDot(isAvailable: isAvailable, reduceMotion: reduceMotion)
                    Text(statusText)
                        .font(Typography.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xs + Spacing.xxs)
        .padding(.vertical, Spacing.xs)
        .background(AccentColor.primarySubtleFill.opacity(0.6), in: RoundedRectangle.continuous(Radius.lg))
        .overlay {
            RoundedRectangle.continuous(Radius.lg)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .help("Runtime status: \(statusText)")
    }
}

private struct RuntimeStatusDot: View {
    let isAvailable: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if isAvailable, !reduceMotion {
                Circle()
                    .stroke(SemanticColor.success.opacity(0.28), lineWidth: 1)
                    .frame(width: 12, height: 12)
                    .symbolEffect(.pulse)
            }
            Circle()
                .fill(isAvailable ? SemanticColor.success : SemanticColor.pending)
                .frame(width: 6, height: 6)
        }
        .accessibilityLabel(isAvailable ? "Runtime available" : "Runtime unavailable")
    }
}

private struct FeedbackBanner: View {
    let feedback: TransferFeedback

    var body: some View {
        Label(feedback.message, systemImage: feedback.symbol)
            .font(Typography.callout.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + 2)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .accessibilityAddTraits(.isStaticText)
    }

    private var tint: Color {
        switch feedback.tone {
        case .neutral:
            return SemanticColor.discovery
        case .success:
            return SemanticColor.success
        case .pending:
            return SemanticColor.pending
        case .destructive:
            return SemanticColor.destructive
        }
    }
}
