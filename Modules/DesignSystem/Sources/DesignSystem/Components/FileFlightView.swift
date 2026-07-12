import SwiftUI

/// An ambient, XP-copy-dialog-style loop of small file glyphs drifting between
/// two device badges. Purely decorative: it never reports progress (the sheet's
/// percent/throughput text is the accessible readout), so it is hidden from
/// assistive technologies and stays visually subordinate to the determinate bar.
///
/// Domain-model-free by design — callers pass plain SF Symbol names, so this can
/// live in DesignSystem without importing device/transfer types.
public struct FileFlightView: View {
    private let leadingSymbol: String
    private let trailingSymbol: String
    private let fileSymbol: String
    private let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReducesMotion) private var appReduceMotion
    @Environment(\.accentTheme) private var accentTheme
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private let badgeSize: CGFloat = 40
    private let trackWidth: CGFloat = 46
    private let fileCount = 3
    // Seconds for one glyph to cross from the leading badge to the trailing one.
    private let cycle: Double = 2.2

    public init(
        leadingSymbol: String,
        trailingSymbol: String,
        fileSymbol: String = "doc.fill",
        isActive: Bool
    ) {
        self.leadingSymbol = leadingSymbol
        self.trailingSymbol = trailingSymbol
        self.fileSymbol = fileSymbol
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: 0) {
            badge(symbol: leadingSymbol)
            flightTrack
                .frame(width: trackWidth, height: badgeSize)
            badge(symbol: trailingSymbol)
        }
        .accessibilityHidden(true)
    }

    private func badge(symbol: String) -> some View {
        RoundedRectangle.continuous(Radius.lg)
            .fill(accentTheme.primarySubtleFill)
            .frame(width: badgeSize, height: badgeSize)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(accentTheme.primary)
                    // Swap the glyph in place so a changing device kind doesn't
                    // re-create the view and restart the flight loop.
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
    }

    @ViewBuilder private var flightTrack: some View {
        if reduceMotion || !isActive {
            // Degrade to a single, static glyph frozen between the two badges.
            fileGlyph
                .opacity(isActive ? 0.6 : 0)
        } else {
            // Drive the loop off the timeline clock rather than a repeatForever
            // animation: repeatForever hitches/restarts under the frequent
            // re-renders from progress ticks; sampling `context.date` does not.
            TimelineView(.animation) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<fileCount, id: \.self) { index in
                        let phase = (now / cycle + Double(index) / Double(fileCount))
                            .truncatingRemainder(dividingBy: 1)
                        fileGlyph
                            .offset(x: (phase - 0.5) * trackWidth)
                            // Fade in leaving the source, out arriving at the dest.
                            .opacity(0.6 * sin(phase * .pi))
                    }
                }
            }
        }
    }

    private var fileGlyph: some View {
        Image(systemName: fileSymbol)
            .font(.system(size: 12))
            .foregroundStyle(accentTheme.primary)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
    }
}
