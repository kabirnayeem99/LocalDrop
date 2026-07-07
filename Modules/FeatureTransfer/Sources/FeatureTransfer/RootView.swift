import SwiftUI
import DesignSystem

struct RootView: View {
    @Bindable private var store: TransferFeatureStore

    init(store: TransferFeatureStore) {
        self._store = Bindable(store)
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
        .sheet(item: presentedSheet) { sheet in
            switch sheet {
            case .incoming(let request):
                IncomingRequestSheet(
                    request: request,
                    onDecline: { store.declineIncomingRequest() },
                    onAccept: { store.acceptIncomingRequest() }
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
                    Label(screen.title, systemImage: screen.symbol)
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
            ThisDeviceChip(deviceName: store.deviceName, statusText: store.runtimeStatusText)
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
        case .send:
            SendView(store: store)
        case .history:
            HistoryView(store: store)
        case .settings:
            SettingsView(store: store)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.refreshNearbyPeers()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
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
                    Circle()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: 6, height: 6)
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
    }
}
