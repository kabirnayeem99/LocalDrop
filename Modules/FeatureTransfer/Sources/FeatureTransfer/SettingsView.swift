import SwiftUI
import DesignSystem
import AppKit

enum TransferSecurityCopy {
    static let httpsToggleTitle = "Use HTTPS for transfers"
    static let httpsToggleHelp = "Encrypt transfer traffic with HTTPS. Turn this off to use plain HTTP on the local network."
    static let httpsDisabledMessage = "Transfers on this device will use plain HTTP on the local network until HTTPS is turned back on."
}

enum DeviceNameCopy {
    static let fieldHint = "Choose the name other LocalSend devices will see."
    static let validationMessage = "Enter a device name to apply."
    static let useSystemName = "Use system name"
    static let generateRandomAlias = "Generate random alias"
}

struct SettingsView: View {
    @Bindable var store: TransferFeatureStore
    @State private var saveLocationPulse = false
    @State private var securityDialog: SecurityDialog?
    @State private var pinDraft = ""
    @State private var deviceNameDraft = ""
    @State private var showsIncomingPIN = false
    @State private var pinValidationMessage: String?
    @State private var deviceNameValidationMessage: String?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        Form {
            Section(FeatureTransferLocalization.string(forKey: "settings.section.general")) {
                Picker(FeatureTransferLocalization.string(forKey: "settings.appearance"), selection: $store.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                LabeledContent(FeatureTransferLocalization.string(forKey: "settings.accentColor")) {
                    AccentSwatchRow(selection: $store.accentColor)
                }

                Picker(FeatureTransferLocalization.string(forKey: "settings.language"), selection: $store.language) {
                    ForEach(LanguageSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                Toggle(FeatureTransferLocalization.resource("settings.minimizeToMenuBar"), isOn: $store.minimizeToMenuBar)
                Toggle(FeatureTransferLocalization.resource("settings.launchAtLogin"), isOn: $store.launchAtLogin)
                Toggle(FeatureTransferLocalization.resource("settings.reduceMotion"), isOn: $store.reduceMotion)
            }

            Section(FeatureTransferLocalization.string(forKey: "settings.section.receiving")) {
                LabeledContent {
                    Button(FeatureTransferLocalization.resource("settings.chooseSaveLocation")) { chooseSaveLocation() }
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(FeatureTransferLocalization.resource("settings.saveLocation"))
                        Text(store.saveLocation)
                            .appFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, saveLocationPulse ? 2 : 0)
                            .background(
                                saveLocationPulse ? SemanticColor.successSubtleFill : .clear,
                                in: RoundedRectangle.continuous(Radius.sm)
                            )
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: saveLocationPulse)
                    }
                }

                Toggle(FeatureTransferLocalization.resource("settings.requirePIN"), isOn: $store.requirePIN)
                    .accessibilityIdentifier("settings-require-pin-toggle")
                    .help(Text(FeatureTransferLocalization.resource("settings.requirePINHelp")))
                LabeledContent(FeatureTransferLocalization.string(forKey: "settings.incomingPIN")) {
                    VStack(alignment: .trailing, spacing: Spacing.xs) {
                        HStack(alignment: .center, spacing: Spacing.xs) {
                            incomingPINField

                            Button(FeatureTransferLocalization.resource(showsIncomingPIN ? "settings.hide" : "settings.show")) {
                                showsIncomingPIN.toggle()
                            }
                            .disabled(store.requirePIN == false)
                            .controlSize(.regular)
                            .accessibilityIdentifier("settings-incoming-pin-visibility")
                        }

                        HStack(spacing: Spacing.xs) {
                            Button(FeatureTransferLocalization.resource("settings.apply")) {
                                applyIncomingPIN()
                            }
                            .disabled(canApplyIncomingPIN == false)
                            .controlSize(.regular)
                            .accessibilityIdentifier("settings-incoming-pin-apply")

                            Button(FeatureTransferLocalization.resource("settings.regenerate")) {
                                store.regenerateIncomingPIN()
                                pinDraft = store.incomingPIN
                                pinValidationMessage = nil
                            }
                            .disabled(store.requirePIN == false)
                            .controlSize(.regular)
                            .accessibilityIdentifier("settings-incoming-pin-regenerate")
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(FeatureTransferLocalization.string(forKey: "settings.incomingPIN"))
                        if let pinValidationMessage {
                            Text(pinValidationMessage)
                                .appFont(.caption1)
                                .foregroundStyle(SemanticColor.pending)
                        } else {
                            Text(FeatureTransferLocalization.resource("settings.incomingPINHint"))
                                .appFont(.caption1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle(FeatureTransferLocalization.resource("settings.autoAcceptFavorites"), isOn: $store.autoAcceptFavorites)
                    .help(Text(FeatureTransferLocalization.resource("settings.autoAcceptFavoritesHelp")))
            }

            Section(FeatureTransferLocalization.string(forKey: "settings.section.network")) {
                LabeledContent(FeatureTransferLocalization.string(forKey: "settings.deviceName")) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(alignment: .top, spacing: Spacing.xs) {
                            TextField(
                                FeatureTransferLocalization.string(forKey: "settings.deviceName"),
                                text: $deviceNameDraft
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .accessibilityIdentifier("settings-device-name-field")
                            .onSubmit { applyDeviceName() }

                            Button(FeatureTransferLocalization.resource("settings.apply")) {
                                applyDeviceName()
                            }
                            .disabled(canApplyDeviceName == false)
                            .accessibilityIdentifier("settings-device-name-apply")

                            Button {
                                applySystemDeviceName()
                            } label: {
                                Image(systemName: "desktopcomputer")
                            }
                            .help(Text(DeviceNameCopy.useSystemName))
                            .accessibilityIdentifier("settings-device-name-system")

                            Button {
                                generateRandomAlias()
                            } label: {
                                Image(systemName: "dice")
                            }
                            .help(Text(DeviceNameCopy.generateRandomAlias))
                            .accessibilityIdentifier("settings-device-name-random")
                        }

                        if let deviceNameValidationMessage {
                            Text(deviceNameValidationMessage)
                                .appFont(.caption1)
                                .foregroundStyle(SemanticColor.pending)
                        } else {
                            Text(DeviceNameCopy.fieldHint)
                                .appFont(.caption1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent(FeatureTransferLocalization.string(forKey: "settings.port")) {
                    Text(store.port)
                        .foregroundStyle(.secondary)
                        .monospacedStat()
                }
                Toggle(FeatureTransferLocalization.resource("settings.allowDownloads"), isOn: $store.allowDownloads)
                    .help(Text(FeatureTransferLocalization.resource("settings.allowDownloadsHelp")))
                Toggle(FeatureTransferLocalization.resource("settings.useHTTPS"), isOn: $store.useHTTPS)
                    .help(Text(FeatureTransferLocalization.resource("settings.useHTTPSHelp")))
            }

        }
        .formStyle(.grouped)
        .tint(accentTheme.primary)
        .onAppear {
            pinDraft = store.incomingPIN
            deviceNameDraft = store.deviceName
        }
        .alert(item: $securityDialog) { dialog in
            Alert(
                title: Text(FeatureTransferLocalization.resource("settings.securityChanged")),
                message: Text(dialog.message),
                dismissButton: .default(Text(FeatureTransferLocalization.resource("settings.ok")))
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
        .onChange(of: store.deviceName) { _, newValue in
            deviceNameDraft = newValue
            deviceNameValidationMessage = nil
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
            TextField(FeatureTransferLocalization.string(forKey: "settings.incomingPINPlaceholder"), text: $pinDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .monospaced()
                .disabled(store.requirePIN == false)
                .accessibilityIdentifier("settings-incoming-pin-field")
                .environment(\.layoutDirection, .leftToRight)
                .onSubmit { applyIncomingPIN() }
        } else {
            SecureField(FeatureTransferLocalization.string(forKey: "settings.incomingPINPlaceholder"), text: $pinDraft)
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

    private var canApplyDeviceName: Bool {
        guard let normalized = LocalDeviceIdentity.normalizedCustomName(deviceNameDraft) else { return false }
        return normalized != store.deviceName
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
            pinValidationMessage = FeatureTransferLocalization.format(
                "settings.incomingPINValidation",
                TransferProtocolSettings.incomingPINLength
            )
            return
        }
        if store.updateIncomingPIN(normalized) {
            pinDraft = store.incomingPIN
            pinValidationMessage = nil
        }
    }

    private func applyDeviceName() {
        guard store.updateDeviceName(deviceNameDraft) else {
            deviceNameValidationMessage = DeviceNameCopy.validationMessage
            return
        }
        deviceNameDraft = store.deviceName
        deviceNameValidationMessage = nil
    }

    private func applySystemDeviceName() {
        deviceNameDraft = store.useSystemDeviceName()
        deviceNameValidationMessage = nil
    }

    private func generateRandomAlias() {
        deviceNameDraft = store.generateRandomDeviceNameAlias()
        deviceNameValidationMessage = nil
    }
}

private struct AccentSwatchRow: View {
    @Binding var selection: AccentColorChoice
    @State private var hovering: AccentColorChoice?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(AccentColorChoice.selectableCases) { accent in
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
