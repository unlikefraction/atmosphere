import SwiftUI

/// What the sky is doing right now.
///
/// Atmosphere is named for the thin lit band around a world, and the panel
/// carries the matching hour: stars and a crescent at night, warm light at
/// dawn and dusk, open blue at midday.
enum SkyPhase: String, CaseIterable, Sendable {
    case night
    case dawn
    case day
    case dusk

    static func current(hour: Int) -> SkyPhase {
        switch hour {
        case 5..<8: return .dawn
        case 8..<17: return .day
        case 17..<20: return .dusk
        default: return .night
        }
    }

    static func now(_ date: Date = Date(), calendar: Calendar = .current) -> SkyPhase {
        #if DEBUG
        if let forced = forcedForPreviews { return forced }
        #endif
        return current(hour: calendar.component(.hour, from: date))
    }

    #if DEBUG
    /// Lets `--render-overlay-previews` capture every hour of the day without
    /// waiting for one.
    nonisolated(unsafe) static var forcedForPreviews: SkyPhase?
    #endif

    var glyph: String {
        switch self {
        case .night: return "moon.stars.fill"
        case .dawn: return "sunrise.fill"
        case .day: return "sun.max.fill"
        case .dusk: return "sunset.fill"
        }
    }

    var greeting: String {
        switch self {
        case .night: return "Good night"
        case .dawn: return "Good morning"
        case .day: return "Good afternoon"
        case .dusk: return "Good evening"
        }
    }

    var isDark: Bool { self == .night }

    /// One flat tint per hour. No ramp: a wash that shades from one colour to
    /// another starts to read as a lit surface, and this is not one.
    fileprivate func tint(dark: Bool) -> Color {
        switch (self, dark) {
        case (.night, true): return Color(red: 0.18, green: 0.21, blue: 0.44)
        case (.night, false): return Color(red: 0.42, green: 0.47, blue: 0.78)
        case (.dawn, true): return Color(red: 0.50, green: 0.28, blue: 0.44)
        case (.dawn, false): return Color(red: 1.00, green: 0.72, blue: 0.58)
        case (.day, true): return Color(red: 0.15, green: 0.30, blue: 0.54)
        case (.day, false): return Color(red: 0.52, green: 0.74, blue: 1.00)
        case (.dusk, true): return Color(red: 0.50, green: 0.22, blue: 0.36)
        case (.dusk, false): return Color(red: 1.00, green: 0.66, blue: 0.52)
        }
    }
}

/// A weather-thin wash across the top of the panel: gradient sky, a luminary,
/// and — at night — a handful of stars.
///
/// It is deliberately faint. This is the light in the room behind the glass,
/// not a picture; text contrast must not move because the hour changed.
struct SkyBackdrop: View {
    let phase: SkyPhase

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack(alignment: .topTrailing) {
                phase.tint(dark: isDark)
                    .opacity(isDark ? 0.26 : 0.22)

                if phase == .night {
                    StarField(width: width, height: height * 0.34, twinkles: !reduceMotion)
                        .opacity(isDark ? 0.6 : 0.35)
                }

            }
            .frame(width: width, height: height, alignment: .top)
            // Gone well before the text settles in, so nothing ever competes
            // with a line of an answer for contrast.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.4), location: 0.28),
                        .init(color: .clear, location: 0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
        }
    }
}

/// Fixed stars. Positions come from a small deterministic generator rather
/// than `random`, so the sky is identical every time the panel opens.
private struct StarField: View {
    let width: CGFloat
    let height: CGFloat
    let twinkles: Bool

    @State private var isTwinkling = false

    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        let opacity: Double
        let twinkles: Bool
    }

    private var stars: [Star] {
        var seed: UInt64 = 0x5EED_A751
        func next() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat((seed >> 33) % 10_000) / 10_000
        }

        return (0..<18).map { index in
            Star(
                x: next() * width,
                // Denser high in the frame, the way a sky reads.
                y: pow(next(), 1.35) * height,
                radius: (0.5 + next()).rounded(),
                opacity: 0.22 + Double(next()) * 0.42,
                twinkles: index % 7 == 0
            )
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(stars.enumerated()), id: \.offset) { index, star in
                // Square, not round: the marks are pixel art and the sky
                // behind them has to belong to the same grid.
                Rectangle()
                    .fill(.white)
                    .frame(width: star.radius * 2, height: star.radius * 2)
                    .opacity(
                        star.twinkles && twinkles && isTwinkling
                            ? star.opacity * 0.35
                            : star.opacity
                    )
                    .animation(
                        star.twinkles && twinkles
                            ? .easeInOut(duration: 2.2 + Double(index % 3) * 0.7)
                                .repeatForever(autoreverses: true)
                            : nil,
                        value: isTwinkling
                    )
                    .position(x: star.x, y: star.y)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onAppear { isTwinkling = twinkles }
    }
}
