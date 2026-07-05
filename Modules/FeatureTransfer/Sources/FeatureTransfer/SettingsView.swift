import SwiftUI
import DesignSystem

struct SettingsView: View {
    @Bindable var state: TransferViewState

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $state.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                LabeledContent("Accent color") {
                    AccentSwatchRow()
                }

                Picker("Language", selection: $state.language) {
                    ForEach(LanguageSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                Toggle("Minimize to menu bar on close", isOn: $state.minimizeToMenuBar)
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                Toggle("Reduce motion", isOn: $state.reduceMotion)
            }

            Section("Receiving") {
                LabeledContent {
                    Button("Choose…") { }
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Save location")
                        Text(state.saveLocation)
                            .font(Typography.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Require PIN for incoming", isOn: $state.requirePIN)
                Toggle("Auto-accept from favorites", isOn: $state.autoAcceptFavorites)
            }

            Section("Network") {
                LabeledContent("Device name", value: state.deviceName)
                LabeledContent("Port") {
                    Text(state.port)
                        .foregroundStyle(.secondary)
                        .monospacedStat()
                }
                Toggle("End-to-end encryption", isOn: $state.endToEndEncryption)
            }
        }
        .formStyle(.grouped)
        .tint(AccentColor.primary)
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
