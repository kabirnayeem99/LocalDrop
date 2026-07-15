import SwiftUI
import DesignSystem
import AppKit

struct SettingsView: View {
    @Bindable var store: TransferFeatureStore
    @State private var saveLocationPulse = false
    @State private var securityDialog: SecurityDialog?
    @State private var hideIncomingPINTask: Task<Void, Never>?
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
            Section {
                Picker(selection: $store.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text(FeatureTransferLocalization.resource("settings.appearance"))
                }
                .pickerStyle(.menu)

                LabeledContent {
                    AccentSwatchRow(selection: $store.accentColor)
                } label: {
                    Text(FeatureTransferLocalization.resource("settings.accentColor"))
                }

                Picker(selection: $store.language) {
                    ForEach(LanguageSetting.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text(FeatureTransferLocalization.resource("settings.language"))
                }
                .pickerStyle(.menu)

                Toggle(FeatureTransferLocalization.resource("settings.minimizeToMenuBar"), isOn: $store.minimizeToMenuBar)
                Toggle(FeatureTransferLocalization.resource("settings.launchAtLogin"), isOn: $store.launchAtLogin)
                Toggle(FeatureTransferLocalization.resource("settings.reduceMotion"), isOn: $store.reduceMotion)
            } header: {
                Text(FeatureTransferLocalization.resource("settings.section.general"))
            }

            Section {
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
                LabeledContent {
                    incomingPINControls
                } label: {
                    incomingPINLabel
                }
                Toggle(FeatureTransferLocalization.resource("settings.autoAcceptFavorites"), isOn: $store.autoAcceptFavorites)
                    .help(Text(FeatureTransferLocalization.resource("settings.autoAcceptFavoritesHelp")))
            } header: {
                Text(FeatureTransferLocalization.resource("settings.section.receiving"))
            }

            Section(FeatureTransferLocalization.resource("settings.section.sending")) {
                Toggle(FeatureTransferLocalization.resource("settings.shareViaLinkAutoAccept"), isOn: $store.shareViaLinkAutoAccept)
                    .help(Text(FeatureTransferLocalization.resource("settings.shareViaLinkAutoAcceptHelp")))
            }

            Section {
                LabeledContent {
                    deviceNameControls
                } label: {
                    deviceNameLabel
                }
                LabeledContent {
                    Text(store.port)
                        .foregroundStyle(.secondary)
                        .monospacedStat()
                } label: {
                    Text(FeatureTransferLocalization.resource("settings.port"))
                }
                Toggle(FeatureTransferLocalization.resource("settings.allowDownloads"), isOn: $store.allowDownloads)
                    .help(Text(FeatureTransferLocalization.resource("settings.allowDownloadsHelp")))
                Toggle(FeatureTransferLocalization.resource("settings.useHTTPS"), isOn: $store.useHTTPS)
                    .help(Text(FeatureTransferLocalization.resource("settings.useHTTPSHelp")))
            } header: {
                Text(FeatureTransferLocalization.resource("settings.section.network"))
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
                message: Text(dialog.messageResource),
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
            sanitizeIncomingPINDraft()
        }
        .onChange(of: store.deviceName) { _, newValue in
            deviceNameDraft = newValue
            deviceNameValidationMessage = nil
        }
        .onChange(of: store.autoAcceptFavorites) { _, _ in store.persistSettings() }
        .onChange(of: store.shareViaLinkAutoAccept) { _, _ in store.persistSettings() }
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
        .onChange(of: pinDraft) { _, _ in
            sanitizeIncomingPINDraft()
        }
        .onDisappear {
            hideIncomingPINTask?.cancel()
            hideIncomingPINTask = nil
        }
    }

    @ViewBuilder private var incomingPINField: some View {
        if showsIncomingPIN {
            TextField("", text: $pinDraft, prompt: Text(FeatureTransferLocalization.resource("settings.incomingPINPlaceholder")))
                .textFieldStyle(.roundedBorder)
                .frame(width: 156)
                .monospaced()
                .disabled(store.requirePIN == false)
                .accessibilityIdentifier("settings-incoming-pin-field")
                .environment(\.layoutDirection, .leftToRight)
                .onSubmit { applyIncomingPIN() }
        } else {
            SecureField("", text: $pinDraft, prompt: Text(FeatureTransferLocalization.resource("settings.incomingPINPlaceholder")))
                .textFieldStyle(.roundedBorder)
                .frame(width: 156)
                .monospaced()
                .disabled(store.requirePIN == false)
                .accessibilityIdentifier("settings-incoming-pin-field")
                .environment(\.layoutDirection, .leftToRight)
                .onSubmit { applyIncomingPIN() }
        }
    }

    private var incomingPINControls: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.xs) {
                incomingPINField
                incomingPINVisibilityButton
            }

            HStack(spacing: Spacing.xs) {
                incomingPINApplyButton
                incomingPINRegenerateButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var incomingPINLabel: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(FeatureTransferLocalization.resource("settings.incomingPIN"))
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

    private var incomingPINVisibilityButton: some View {
        Button {
            toggleIncomingPINVisibility()
        } label: {
            Image(systemName: showsIncomingPIN ? "eye.slash" : "eye")
        }
        .disabled(store.requirePIN == false)
        .controlSize(.regular)
        .labelStyle(.iconOnly)
        .help(Text(FeatureTransferLocalization.resource(showsIncomingPIN ? "settings.hide" : "settings.show")))
        .accessibilityLabel(Text(FeatureTransferLocalization.resource(showsIncomingPIN ? "settings.hide" : "settings.show")))
        .accessibilityIdentifier("settings-incoming-pin-visibility")
    }

    private var incomingPINApplyButton: some View {
        Button {
            applyIncomingPIN()
        } label: {
            Image(systemName: "checkmark")
        }
        .disabled(canApplyIncomingPIN == false)
        .controlSize(.regular)
        .labelStyle(.iconOnly)
        .help(Text(FeatureTransferLocalization.resource("settings.apply")))
        .accessibilityLabel(Text(FeatureTransferLocalization.resource("settings.apply")))
        .accessibilityIdentifier("settings-incoming-pin-apply")
    }

    private var incomingPINRegenerateButton: some View {
        Button {
            store.regenerateIncomingPIN()
            pinDraft = store.incomingPIN
            pinValidationMessage = nil
            sanitizeIncomingPINDraft()
        } label: {
            Image(systemName: "dice")
        }
        .disabled(store.requirePIN == false)
        .controlSize(.regular)
        .labelStyle(.iconOnly)
        .help(Text(FeatureTransferLocalization.resource("settings.regenerate")))
        .accessibilityLabel(Text(FeatureTransferLocalization.resource("settings.regenerate")))
        .accessibilityIdentifier("settings-incoming-pin-regenerate")
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

    private var deviceNameControls: some View {
        HStack(spacing: Spacing.xs) {
            TextField(
                "",
                text: $deviceNameDraft,
                prompt: Text(FeatureTransferLocalization.resource("settings.deviceName"))
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
            .help(Text(FeatureTransferLocalization.string(forKey: "settings.deviceNameUseSystem")))
            .accessibilityIdentifier("settings-device-name-system")

            Button {
                generateRandomAlias()
            } label: {
                Image(systemName: "dice")
            }
            .help(Text(FeatureTransferLocalization.string(forKey: "settings.deviceNameRandomAlias")))
            .accessibilityIdentifier("settings-device-name-random")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var deviceNameLabel: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(FeatureTransferLocalization.resource("settings.deviceName"))
            if let deviceNameValidationMessage {
                Text(deviceNameValidationMessage)
                    .appFont(.caption1)
                    .foregroundStyle(SemanticColor.pending)
            } else {
                Text(FeatureTransferLocalization.string(forKey: "settings.deviceNameHint"))
                    .appFont(.caption1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sanitizeIncomingPINDraft() {
        let digitsOnly = pinDraft.filter(\.isNumber)
        let capped = String(digitsOnly.prefix(TransferProtocolSettings.incomingPINLength))
        if pinDraft != capped {
            pinDraft = capped
        }
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
        sanitizeIncomingPINDraft()
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

    private func toggleIncomingPINVisibility() {
        showsIncomingPIN.toggle()
        scheduleIncomingPINAutoHideIfNeeded()
    }

    private func scheduleIncomingPINAutoHideIfNeeded() {
        hideIncomingPINTask?.cancel()
        hideIncomingPINTask = nil

        guard showsIncomingPIN else { return }

        hideIncomingPINTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                showsIncomingPIN = false
                hideIncomingPINTask = nil
            }
        }
    }

    private func applyDeviceName() {
        guard store.updateDeviceName(deviceNameDraft) else {
            deviceNameValidationMessage = FeatureTransferLocalization.string(forKey: "settings.deviceNameValidation")
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

enum SecurityDialog: Identifiable {
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

    var messageKey: String {
        switch self {
        case .requirePIN:
            return "settings.requirePINMessage"
        case .allowDownloads:
            return "settings.allowDownloadsMessage"
        case .httpsDisabled:
            return "settings.httpsDisabledMessage"
        }
    }

    var messageResource: LocalizedStringResource {
        FeatureTransferLocalization.resource(.init(messageKey))
    }
}
