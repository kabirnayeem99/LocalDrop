import SwiftUI
import DesignSystem

public struct RootView: View {
    @State private var state = TransferViewState()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { toolbar }
                .navigationTitle(state.screen.title)
        }
        .environment(\.appReducesMotion, state.reduceMotion)
        .preferredColorScheme(state.appearance.colorScheme)
        .sheet(item: $state.activeSheet) { sheet in
            switch sheet {
            case .incoming:
                IncomingRequestSheet(
                    request: .sample,
                    onDecline: { state.activeSheet = nil },
                    onAccept: {
                        state.transferProgress = 0.06
                        state.activeSheet = .progress
                    }
                )
            case .progress:
                TransferProgressSheet(state: state) { state.activeSheet = nil }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $state.screen) {
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
            ThisDeviceChip(deviceName: state.deviceName)
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
        switch state.screen {
        case .receive: ReceiveView(state: state)
        case .send: SendView(state: state)
        case .history: HistoryView()
        case .settings: SettingsView(state: state)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.activeSheet = .incoming
            } label: {
                Label("Simulate request", systemImage: "arrow.down.circle")
            }

            Button {
                state.screen = .history
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

            Button {
                state.screen = .settings
            } label: {
                Label("Info", systemImage: "info.circle")
            }
        }
    }
}

private struct ThisDeviceChip: View {
    let deviceName: String

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
                    Text("Discoverable")
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
