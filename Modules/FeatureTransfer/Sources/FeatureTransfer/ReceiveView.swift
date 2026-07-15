import AppKit
import SwiftUI
import DesignSystem

struct ReceiveView: View {
    @Bindable var store: TransferFeatureStore
    @Environment(\.accentTheme) private var accentTheme

    var body: some View {
        VStack(spacing: 0) {
            ReceiveHero()
                .frame(width: 220, height: 220)

            Text(store.deviceName)
                .appFont(.fixed(30, .bold))
                .foregroundStyle(.primary)
                .padding(.top, Spacing.xl + Spacing.xxs)

            (Text(FeatureTransferLocalization.resource("receive.waiting"))
                .foregroundStyle(.secondary)
             + Text(verbatim: "#\(store.waitingIdentifier)")
                .foregroundStyle(accentTheme.primary))
                .appFont(.text(.body, .medium))
                .padding(.top, Spacing.xxs)

            VStack(spacing: Spacing.sm) {
                Text(FeatureTransferLocalization.resource("receive.quickSave"))
                    .appFont(.text(.caption, .semibold))
                    .textCase(.uppercase)
                    .kerning(0.3)
                    .foregroundStyle(.secondary)

                Picker(FeatureTransferLocalization.string(forKey: "receive.quickSave"), selection: $store.quickSave) {
                    ForEach(QuickSaveMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .tint(accentTheme.primary)
            }
            .padding(.top, Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
        .onChange(of: store.quickSave) { _, _ in
            store.persistSettings()
        }
    }
}

private struct ReceiveHero: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        Group {
            if reduceMotion {
                hero(at: Date(timeIntervalSinceReferenceDate: 0), animated: false)
            } else {
                TimelineView(.animation) { context in
                    hero(at: context.date, animated: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FeatureTransferLocalization.resource("receive.discoverable")))
    }

    private func hero(at date: Date, animated: Bool) -> some View {
        let time = animated ? date.timeIntervalSinceReferenceDate : 0

        return ZStack {
            PulseRingView(ringCount: 3, color: accentTheme.primary.opacity(0.48), lineWidth: 1.5, duration: 3.2)
                .frame(width: 154, height: 154)
                .opacity(animated ? 1 : 0.72)

            ScanSweep(progress: time.truncatingRemainder(dividingBy: 4.8) / 4.8)
                .frame(width: 176, height: 176)
                .opacity(animated ? 0.75 : 0.28)

            RotatingDashedRing()
                .frame(width: 190, height: 190)

            ForEach(OrbitingDevice.devices) { device in
                OrbitingDeviceView(device: device, time: time, animated: animated)
            }

            ForEach(0..<4, id: \.self) { index in
                SignalSpark(index: index, time: time, animated: animated)
            }

            BrandBadge(time: time, animated: animated)
        }
    }
}

private struct BrandBadge: View {
    let time: TimeInterval
    let animated: Bool
    @Environment(\.accentTheme) private var accentTheme

    private var scale: CGFloat {
        guard animated else { return 1 }
        return 1 + CGFloat((sin(time * 1.4) + 1) * 0.012)
    }

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 128, height: 128)
            .scaleEffect(scale)
            .shadow(color: accentTheme.primary.opacity(0.4), radius: animated ? 22 : 16, y: 12)
    }
}

private struct OrbitingDevice: Identifiable {
    let id: Int
    let symbol: String
    let radius: CGFloat
    let phase: Double
    let duration: Double

    static let devices = [
        OrbitingDevice(id: 0, symbol: "iphone", radius: 95, phase: 0.0, duration: 18),
        OrbitingDevice(id: 1, symbol: "ipad", radius: 92, phase: 0.34, duration: 22),
        OrbitingDevice(id: 2, symbol: "desktopcomputer", radius: 98, phase: 0.68, duration: 26)
    ]
}

private struct OrbitingDeviceView: View {
    let device: OrbitingDevice
    let time: TimeInterval
    let animated: Bool
    @Environment(\.accentTheme) private var accentTheme

    var body: some View {
        let progress = animated ? (time.truncatingRemainder(dividingBy: device.duration) / device.duration) : device.phase
        let angle = (progress + device.phase) * .pi * 2
        let point = CGPoint(
            x: CGFloat(cos(angle)) * device.radius,
            y: CGFloat(sin(angle)) * device.radius
        )

        Image(systemName: device.symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(accentTheme.primary)
            .frame(width: 30, height: 30)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle().strokeBorder(accentTheme.primary.opacity(0.22), lineWidth: 0.5)
            }
            .offset(x: point.x, y: point.y)
            .opacity(animated ? 0.92 : 0.8)
    }
}

private struct ScanSweep: View {
    let progress: Double

    var body: some View {
        Circle()
            .trim(from: progress, to: min(progress + 0.16, 1))
            .stroke(
                AngularGradient(
                    colors: [.clear, SemanticColor.discovery.opacity(0.65), .clear],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 28, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .blur(radius: 2)
    }
}

private struct SignalSpark: View {
    let index: Int
    let time: TimeInterval
    let animated: Bool

    var body: some View {
        let base = Double(index) * 0.24
        let progress = animated ? (time * 0.35 + base).truncatingRemainder(dividingBy: 1) : base
        let angle = progress * .pi * 2
        let radius: CGFloat = 101
        let opacity = animated ? max(0.18, 1 - abs(progress - 0.5) * 1.8) : 0.25

        Circle()
            .fill(SemanticColor.discovery)
            .frame(width: 4, height: 4)
            .shadow(color: SemanticColor.discovery.opacity(0.55), radius: 4)
            .offset(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius)
            .opacity(opacity)
    }
}

private struct RotatingDashedRing: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        if reduceMotion {
            ring
        } else {
            TimelineView(.animation) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 26) / 26 * 360
                ring.rotationEffect(.degrees(angle))
            }
        }
    }

    private var ring: some View {
        Circle()
            .strokeBorder(
                accentTheme.primary.opacity(0.28),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 6])
            )
    }
}
