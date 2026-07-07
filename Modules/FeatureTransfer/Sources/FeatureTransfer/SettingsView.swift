import SwiftUI
import DesignSystem

struct SettingsView: View {
    @Bindable var store: TransferFeatureStore

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $store.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                LabeledContent("Accent color") {
                    AccentSwatchRow()
                }

                Picker("Language", selection: $store.language) {
                    ForEach(LanguageSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                Toggle("Minimize to menu bar on close", isOn: $store.minimizeToMenuBar)
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                Toggle("Reduce motion", isOn: $store.reduceMotion)
            }

            Section("Receiving") {
                LabeledContent {
                    Button("Choose…") { }
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Save location")
                        Text(store.saveLocation)
                            .font(Typography.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Require PIN for incoming", isOn: $store.requirePIN)
                Toggle("Auto-accept from favorites", isOn: $store.autoAcceptFavorites)
            }

            Section("Network") {
                LabeledContent("Device name", value: store.deviceName)
                LabeledContent("Port") {
                    Text(store.port)
                        .foregroundStyle(.secondary)
                        .monospacedStat()
                }
                Toggle("Allow downloads", isOn: $store.allowDownloads)
                Toggle("End-to-end encryption", isOn: $store.endToEndEncryption)
            }
        }
        .formStyle(.grouped)
        .tint(AccentColor.primary)
        .onChange(of: store.appearance) { _, _ in store.persistSettings() }
        .onChange(of: store.language) { _, _ in store.persistSettings() }
        .onChange(of: store.minimizeToMenuBar) { _, _ in store.persistSettings() }
        .onChange(of: store.launchAtLogin) { _, _ in store.persistSettings() }
        .onChange(of: store.reduceMotion) { _, _ in store.persistSettings() }
        .onChange(of: store.requirePIN) { _, _ in store.persistSettings() }
        .onChange(of: store.autoAcceptFavorites) { _, _ in store.persistSettings() }
        .onChange(of: store.allowDownloads) { _, _ in store.persistSettings() }
        .onChange(of: store.endToEndEncryption) { _, _ in store.persistSettings() }
    }
}

private struct AccentSwatchRow: View {
    private let swatches: [Color] = [
        AccentColor.primary,
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemOrange),
        Color(nsColor: .systemPurple)
    ]

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(swatches.indices, id: \.self) { index in
                Circle()
                    .fill(swatches[index])
                    .frame(width: 20, height: 20)
                    .overlay {
                        if index == 0 {
                            Circle()
                                .strokeBorder(AccentColor.primary, lineWidth: 1.5)
                                .padding(-3.5)
                        }
                    }
            }
        }
    }
}
