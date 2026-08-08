import SwiftUI

/// Atmosphere's mark: whatever is in the sky right now, drawn in pixels.
///
/// A crescent moon after dark, the sun in daylight, both on a 13×13 grid of
/// square cells. Flat colour, hard edges, no gradients and no glows — the
/// shapes are legible because of their silhouette, not because of shading.
/// While the model is working the moon's stars twinkle and the sun throws a
/// second ring of beams; when it stops, both animations are torn down rather
/// than left running.
struct AtmosphereMark: View {
    var size: CGFloat = 22
    var phase: SkyPhase = .now()
    /// True only while an answer is actually being produced.
    var isWorking = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if phase == .night {
                MoonMark(size: size, isWorking: isWorking && !reduceMotion)
            } else {
                SunMark(size: size, isWorking: isWorking && !reduceMotion)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Pixel grid

/// One cell of the grid the mark is drawn on.
struct PixelCell: Hashable {
    let x: Int
    let y: Int
}

/// Draws a set of grid cells as square pixels.
///
/// The cell size is floored to a whole point and the whole sprite is centred on
/// what is left over, so pixels land on point boundaries and stay square
/// instead of smearing across a half point.
struct PixelSprite: Shape {
    let cells: [PixelCell]
    let grid: Int

    func path(in rect: CGRect) -> Path {
        guard grid > 0 else { return Path() }
        let raw = min(rect.width, rect.height) / CGFloat(grid)
        let side = raw >= 2 ? raw.rounded(.down) : raw
        let originX = rect.midX - (side * CGFloat(grid) / 2)
        let originY = rect.midY - (side * CGFloat(grid) / 2)

        var path = Path()
        for cell in cells {
            path.addRect(
                CGRect(
                    x: originX + (side * CGFloat(cell.x)),
                    y: originY + (side * CGFloat(cell.y)),
                    width: side,
                    height: side
                )
            )
        }
        return path
    }
}

/// The sprites, generated from circle tests rather than hand-plotted, so a
/// tweak to a radius re-renders cleanly at every size.
enum PixelArt {
    static let grid = 13

    private static func cells(
        where isFilled: (CGFloat, CGFloat) -> Bool
    ) -> [PixelCell] {
        var result: [PixelCell] = []
        for y in 0..<grid {
            for x in 0..<grid where isFilled(CGFloat(x) + 0.5, CGFloat(y) + 0.5) {
                result.append(PixelCell(x: x, y: y))
            }
        }
        return result
    }

    private static func distance(
        _ x: CGFloat, _ y: CGFloat, _ cx: CGFloat, _ cy: CGFloat
    ) -> CGFloat {
        (((x - cx) * (x - cx)) + ((y - cy) * (y - cy))).squareRoot()
    }

    /// A disc with an offset disc taken out of it.
    static let moon: [PixelCell] = cells { x, y in
        distance(x, y, 6.5, 6.5) <= 5.8 && distance(x, y, 9.9, 6.5) > 5.6
    }

    static let sunCore: [PixelCell] = cells { x, y in
        distance(x, y, 6.5, 6.5) <= 2.7
    }

    /// Eight beams, one cell each, detached from the core.
    static let sunBeams: [PixelCell] = [
        PixelCell(x: 6, y: 2), PixelCell(x: 6, y: 10),
        PixelCell(x: 2, y: 6), PixelCell(x: 10, y: 6),
        PixelCell(x: 3, y: 3), PixelCell(x: 9, y: 3),
        PixelCell(x: 3, y: 9), PixelCell(x: 9, y: 9)
    ]

    /// The outer ring, lit only while the model is working.
    static let sunOuterBeams: [PixelCell] = [
        PixelCell(x: 6, y: 0), PixelCell(x: 6, y: 12),
        PixelCell(x: 0, y: 6), PixelCell(x: 12, y: 6),
        PixelCell(x: 2, y: 2), PixelCell(x: 10, y: 2),
        PixelCell(x: 2, y: 10), PixelCell(x: 10, y: 10)
    ]

    /// A five-cell plus — the smallest thing that still reads as a star.
    static let starGrid = 3
    static let star: [PixelCell] = [
        PixelCell(x: 1, y: 0),
        PixelCell(x: 0, y: 1), PixelCell(x: 1, y: 1), PixelCell(x: 2, y: 1),
        PixelCell(x: 1, y: 2)
    ]
}

// MARK: - Night

private struct MoonMark: View {
    let size: CGFloat
    let isWorking: Bool

    static let moonColor = Color(red: 0.96, green: 0.97, blue: 1.0)

    /// Three stars, placed once and never moved. A star that wanders is a bug,
    /// not a sky.
    private static let stars: [(x: CGFloat, y: CGFloat, scale: CGFloat, delay: Double)] = [
        (0.35, -0.32, 1.0, 0),
        (0.42, 0.15, 0.75, 0.4),
        (-0.35, 0.40, 0.62, 0.8)
    ]

    var body: some View {
        ZStack {
            PixelSprite(cells: PixelArt.moon, grid: PixelArt.grid)
                .fill(Self.moonColor)
                .frame(width: size * 0.82, height: size * 0.82)
                .offset(x: -size * 0.12, y: size * 0.02)

            ForEach(Array(Self.stars.enumerated()), id: \.offset) { _, star in
                PixelSprite(cells: PixelArt.star, grid: PixelArt.starGrid)
                    .fill(Self.moonColor)
                    .frame(width: size * 0.26 * star.scale, height: size * 0.26 * star.scale)
                    .offset(x: size * star.x, y: size * star.y)
                    .modifier(Twinkle(isActive: isWorking, delay: star.delay))
            }
        }
    }
}

/// Idle stars sit at a steady brightness; working stars breathe, each on its
/// own beat so the group never pulses in unison.
private struct Twinkle: ViewModifier {
    let isActive: Bool
    let delay: Double

    @State private var isBright = false

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? (isBright ? 1 : 0.2) : 0.85)
            .onAppear {
                guard isActive else { return }
                withAnimation(
                    .easeInOut(duration: 0.8)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                ) {
                    isBright = true
                }
            }
    }
}

// MARK: - Day

private struct SunMark: View {
    let size: CGFloat
    let isWorking: Bool

    @State private var isShining = false

    static let sunColor = Color(red: 1.0, green: 0.72, blue: 0.25)

    var body: some View {
        ZStack {
            PixelSprite(
                cells: PixelArt.sunCore + PixelArt.sunBeams,
                grid: PixelArt.grid
            )
            .fill(Self.sunColor)

            // The far ring only appears while the model is working, so a still
            // sun and a thinking sun are never the same picture.
            if isWorking {
                PixelSprite(cells: PixelArt.sunOuterBeams, grid: PixelArt.grid)
                    .fill(Self.sunColor)
                    .opacity(isShining ? 1 : 0.15)
                    .onAppear {
                        withAnimation(
                            .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
                        ) {
                            isShining = true
                        }
                    }
                    .onDisappear { isShining = false }
            }
        }
        .frame(width: size, height: size)
    }
}

/// The mark plus wordmark, as used in the shortcut sheet.
struct AtmosphereLockup: View {
    var markSize: CGFloat = 15
    var phase: SkyPhase = .now()

    var body: some View {
        HStack(spacing: 6) {
            AtmosphereMark(size: markSize, phase: phase)
            Text("Atmosphere")
                .font(Atmo.Font.micro)
                .tracking(0.2)
                .foregroundStyle(Atmo.Palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Atmosphere")
    }
}

#Preview {
    HStack(spacing: 24) {
        AtmosphereMark(size: 16, phase: .night)
        AtmosphereMark(size: 32, phase: .night, isWorking: true)
        AtmosphereMark(size: 16, phase: .day)
        AtmosphereMark(size: 32, phase: .day, isWorking: true)
        AtmosphereMark(size: 96, phase: .night)
        AtmosphereMark(size: 96, phase: .day)
    }
    .padding(40)
}
