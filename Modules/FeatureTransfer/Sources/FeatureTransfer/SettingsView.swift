import SwiftUI
import DesignSystem
import AppKit

enum TransferSecurityCopy {
    static let httpsToggleTitle = "Use HTTPS for transfers"
    static let httpsToggleHelp = "Encrypt transfer traffic with HTTPS. Turn this off to use plain HTTP on the local network."
    static let httpsDisabledMessage = "Transfers on this device will use plain HTTP on the local network until HTTPS is turned back on."
}

struct SettingsView: View {
    @Bindable var store: TransferFeatureStore
    @State private var saveLocationPulse = false
    @State private var securityDialog: SecurityDialog?
    @State private var pinDraft = ""
    @State private var showsIncomingPIN = false
    @State private var pinValidationMessage: String?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        Form {
            Section("settings.section.general") {
                Picker("settings.appearance", selection: $store.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                LabeledContent("settings.accentColor") {
                    AccentSwatchRow(selection: $store.accentColor)
                }

                Picker("settings.language", selection: $store.language) {
                    ForEach(LanguageSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                Toggle("settings.minimizeToMenuBar", isOn: $store.minimizeToMenuBar)
                Toggle("settings.launchAtLogin", isOn: $store.launchAtLogin)
                Toggle("settings.reduceMotion", isOn: $store.reduceMotion)
            }

            Section("settings.section.receiving") {
                LabeledContent {
                    Button("settings.chooseSaveLocation") { chooseSaveLocation() }
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("settings.saveLocation")
                        Text(store.saveLocation)
                            .font(Typography.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, saveLocationPulse ? 2 : 0)
                            .background(
                                saveLocationPulse ? SemanticColor.successSubtleFill : .clear,
                                in: RoundedRectangle.continuous(Radius.sm)
                            )
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: saveLocationPulse)
                    }
                }

                Toggle("settings.requirePIN", isOn: $store.requirePIN)
                    .accessibilityIdentifier("settings-require-pin-toggle")
                    .help("settings.requirePINHelp")
                LabeledContent("settings.incomingPIN") {
                    VStack(alignment: .trailing, spacing: Spacing.xxs) {
                        HStack(spacing: Spacing.xs) {
                            incomingPINField

                            Button(showsIncomingPIN ? "settings.hide" : "settings.show") {
                                showsIncomingPIN.toggle()
                            }
                            .disabled(store.requirePIN == false)
                            .accessibilityIdentifier("settings-incoming-pin-visibility")

                            Button("settings.apply") {
                                applyIncomingPIN()
                            }
                            .disabled(canApplyIncomingPIN == false)
                            .accessibilityIdentifier("settings-incoming-pin-apply")

                            Button("settings.regenerate") {
                                store.regenerateIncomingPIN()
                                pinDraft = store.incomingPIN
                                pinValidationMessage = nil
                            }
                            .disabled(store.requirePIN == false)
                            .accessibilityIdentifier("settings-incoming-pin-regenerate")
                        }

                        Text(pinValidationMessage ?? String(localized: .init("settings.incomingPINHint"), bundle: .module))
                            .font(Typography.caption1)
                            .foregroundStyle(pinValidationMessage == nil ? .secondary : SemanticColor.pending)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Toggle("settings.autoAcceptFavorites", isOn: $store.autoAcceptFavorites)
                    .help("settings.autoAcceptFavoritesHelp")
            }

            Section("settings.section.network") {
                LabeledContent("settings.deviceName", value: store.deviceName)
                LabeledContent("settings.port") {
                    Text(store.port)
                        .foregroundStyle(.secondary)
                        .monospacedStat()
                }
                Toggle("settings.allowDownloads", isOn: $store.allowDownloads)
                    .help("settings.allowDownloadsHelp")
                Toggle("settings.useHTTPS", isOn: $store.useHTTPS)
                    .help("settings.useHTTPSHelp")
            }
        }
        .formStyle(.grouped)
        .tint(accentTheme.primary)
        .onAppear {
            pinDraft = store.incomingPIN
        }
        .alert(item: $securityDialog) { dialog in
            Alert(
                title: Text("settings.securityChanged"),
                message: Text(dialog.message),
                dismissButton: .default(Text("settings.ok"))
            )
        }
        .onChange(of: store.appearance) { _, _ in store.persistSettings() }
        .onChange(of: store.accentColor) { _, _ in store.persistSettings() }
        .onChange(of: store.language) { _, _ in store.persistSettings() }
        .onChange(of: store.minimizeToMenuBar) { _, _ in store.persistSettings() }
        .onChange(of: store.launchAtLogin) { _, _ in store.applyLaunchAtLogin() }
        .onChange(of: store.reduceMotion) { _, _ in store.persistSettings() }
        .onChange(of: store.requirePIN) { _, newValue in
            if newValue {
                store.ensureIncomingPIN()
                pinDraft = store.incomingPIN
            }
            store.persistSettings()
            pinValidationMessage = nil
            if newValue {
                securityDialog = .requirePIN
            }
        }
        .onChange(of: store.incomingPIN) { _, newValue in
            pinDraft = newValue
        }
        .onChange(of: store.autoAcceptFavorites) { _, _ in store.persistSettings() }
        .onChange(of: store.allowDownloads) { _, newValue in
            store.persistSettings()
            if newValue {
                securityDialog = .allowDownloads
            }
        }
        .onChange(of: store.useHTTPS) { _, newValue in
            store.persistSettings()
            if !newValue {
                securityDialog = .httpsDisabled
            }
        }
    }

    @ViewBuilder private var incomingPINField: some View {
        if showsIncomingPIN {
            TextField("settings.incomingPINPlaceholder", text: $pinDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .monospaced()
                .disabled(store.requirePIN == false)
                .accessibilityIdentifier("settings-incoming-pin-field")
                .environment(\.layoutDirection, .leftToRight)
                .onSubmit { applyIncomingPIN() }
        } else {
            SecureField("settings.incomingPINPlaceholder", text: $pinDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .monospaced()
                .disabled(store.requirePIN == false)
                .accessibilityIdentifier("settings-incoming-pin-field")
                .environment(\.layoutDirection, .leftToRight)
                .onSubmit { applyIncomingPIN() }
        }
    }

    private var canApplyIncomingPIN: Bool {
        guard store.requirePIN else { return false }
        guard let normalized = normalizedPinDraft else { return false }
        return normalized != store.incomingPIN
    }

    private var normalizedPinDraft: String? {
        TransferProtocolSettings.normalizedIncomingPIN(from: pinDraft)
    }

    private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: store.saveLocation)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.updateSaveLocation(url)
        saveLocationPulse = true
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                saveLocationPulse = false
            }
        }
    }

    private func applyIncomingPIN() {
        guard store.requirePIN else { return }
        guard let normalized = normalizedPinDraft else {
            pinValidationMessage = String(
                format: String(localized: .init("settings.incomingPINValidation"), bundle: .module),
                TransferProtocolSettings.incomingPINLength
            )
            return
        }
        if store.updateIncomingPIN(normalized) {
            pinDraft = store.incomingPIN
            pinValidationMessage = nil
        }
    }
}

private struct AccentSwatchRow: View {
    @Binding var selection: AccentColorChoice
    @State private var hovering: AccentColorChoice?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(AccentColorChoice.allCases) { accent in
                Button {
                    selection = accent
                } label: {
                    Circle()
                        .fill(accent.theme.primary)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if selection == accent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    selection == accent || hovering == accent ? accent.theme.primary : Color(nsColor: .separatorColor),
                                    lineWidth: selection == accent ? 2 : 1
                                )
                                .padding(selection == accent ? -4 : -2)
                        }
                }
                .buttonStyle(.plain)
                .help(accent.label)
                .onHover { hovering = $0 ? accent : nil }
            }
        }
    }
}

private enum SecurityDialog: Identifiable {
    case requirePIN
    case allowDownloads
    case httpsDisabled

    var id: String {
        switch self {
        case .requirePIN: "requirePIN"
        case .allowDownloads: "allowDownloads"
        case .httpsDisabled: "httpsDisabled"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .requirePIN:
            return "settings.requirePINMessage"
        case .allowDownloads:
            return "settings.allowDownloadsMessage"
        case .httpsDisabled:
            return "settings.httpsDisabledMessage"
        }
    }
}

