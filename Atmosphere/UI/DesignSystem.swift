import AppKit
import SwiftUI

/// Shared visual language for Atmosphere.
///
/// Every measurement the overlay depends on lives here so the panel can size
/// itself arithmetically instead of waiting for a layout pass. That is what
/// keeps show, grow, and collapse frame-perfect on the first frame.
enum Atmo {
    enum Radius {
        static let panel: CGFloat = 18
        static let bubble: CGFloat = 14
        static let thumbnail: CGFloat = 9
    }

    enum Metric {
        static let panelWidth: CGFloat = 720
        /// The tallest the transcript may grow before it starts scrolling.
        static let conversationHeight: CGFloat = 470
        static let conversationMinimum: CGFloat = 96
        static let authenticationHeight: CGFloat = 292
        static let noticeHeight: CGFloat = 128
        static let shortcutsHeight: CGFloat = 372

        static let barVerticalPadding: CGFloat = 13
        static let barMinimumHeight: CGFloat = 56
        static let footerHeight: CGFloat = 30
        static let attachmentStripHeight: CGFloat = 74
        static let statusLineHeight: CGFloat = 26
        static let hairline: CGFloat = 1

        static let gutter: CGFloat = 14
        static let controlSide: CGFloat = 28
        /// Where the prompt's text starts: gutter, mark, and the gap after it.
        /// Accessory rows align to this column, not to the panel edge.
        static let promptColumn: CGFloat = 48
    }

    enum Motion {
        /// Content growth and collapse. Fast enough to feel instant, damped
        /// enough that it never overshoots into a wobble.
        static let content = Animation.spring(response: 0.26, dampingFraction: 0.9)
        static let quick = Animation.easeOut(duration: 0.14)
        static let hover = Animation.easeOut(duration: 0.12)

        static let panelPresentDuration: TimeInterval = 0.16
        static let panelDismissDuration: TimeInterval = 0.11

        static func maybe(_ animation: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }
    }

    enum Palette {
        static let accent = Color(nsColor: .controlAccentColor)
        static let label = Color(nsColor: .labelColor)
        static let secondary = Color(nsColor: .secondaryLabelColor)
        static let tertiary = Color(nsColor: .tertiaryLabelColor)
        static let danger = Color(nsColor: .systemRed)
        static let caution = Color(nsColor: .systemOrange)
        static let ready = Color(nsColor: .systemGreen)

        /// The faint inner light along the top edge of a glass surface.
        static let glassRim = LinearGradient(
            colors: [
                Color.white.opacity(0.34),
                Color.white.opacity(0.06),
                Color.white.opacity(0.02)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    enum Font {
        /// The prompt field. Large enough to read at a glance from across the
        /// desk, small enough that two lines still fit the compact bar.
        static let promptSize: CGFloat = 16
        static let prompt = NSFont.systemFont(ofSize: promptSize, weight: .regular)

        /// New York, the system serif. Reserved for the two display moments —
        /// the connect screen and the shortcut sheet — where a little
        /// editorial weight is worth more than another line of SF.
        static func display(size: CGFloat, weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .serif)
        }

        static let message = SwiftUI.Font.system(size: 13.5)
        static let footnote = SwiftUI.Font.system(size: 11, weight: .medium)
        static let micro = SwiftUI.Font.system(size: 10.5, weight: .medium)
    }
}

extension Bundle {
    var shortVersionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Version \($0)" } ?? ""
    }
}

// MARK: - Surfaces

extension View {
    /// A hairline that reads as a lit glass edge rather than a drawn border.
    func rimStroke<S: InsettableShape>(_ shape: S, opacity: Double = 1) -> some View {
        overlay {
            shape
                .strokeBorder(Atmo.Palette.glassRim, lineWidth: 1)
                .opacity(opacity)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .overlay {
            shape
                .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Controls

/// The quiet, circular control used across the bar and header: invisible until
/// pointed at, then a soft glass pill. Matches how Apple treats secondary
/// affordances inside search fields.
struct AtmoIconButtonStyle: ButtonStyle {
    var side: CGFloat = Atmo.Metric.controlSide
    var tint: Color?
    var prominent = false

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground(pressed: configuration.isPressed))
            .frame(width: side, height: side)
            .background {
                if prominent, isEnabled {
                    Circle().fill(Atmo.Palette.accent)
                } else if prominent {
                    Circle().fill(Color.primary.opacity(0.08))
                } else if let tint {
                    Circle().fill(tint.opacity(configuration.isPressed ? 0.28 : 0.16))
                } else if isHovering || configuration.isPressed {
                    Circle()
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .contentShape(Circle())
            .animation(Atmo.Motion.maybe(Atmo.Motion.hover, reduceMotion: reduceMotion), value: isHovering)
            .animation(Atmo.Motion.maybe(Atmo.Motion.hover, reduceMotion: reduceMotion), value: configuration.isPressed)
            .onHover { isHovering = $0 && isEnabled }
            .opacity(isEnabled ? 1 : 0.4)
    }

    private func foreground(pressed: Bool) -> Color {
        if prominent { return isEnabled ? .white : Atmo.Palette.tertiary }
        if let tint { return tint }
        return isHovering ? Atmo.Palette.label : Atmo.Palette.secondary
    }
}

/// Footer-scale control: text-first, underlined by a hover wash. Deliberately
/// recessive so the prompt stays the loudest thing in the panel.
struct AtmoFooterButtonStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Atmo.Font.micro)
            .foregroundStyle(isHovering ? Atmo.Palette.label : Atmo.Palette.secondary)
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background {
                if isHovering || configuration.isPressed {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
                }
            }
            .contentShape(Rectangle())
            .animation(Atmo.Motion.maybe(Atmo.Motion.hover, reduceMotion: reduceMotion), value: isHovering)
            .onHover { isHovering = $0 && isEnabled }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A single physical key, drawn the way Apple draws keys in Help articles.
struct KeyCap: View {
    let text: String
    var emphasized = false

    init(_ text: String, emphasized: Bool = false) {
        self.text = text
        self.emphasized = emphasized
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(emphasized ? Atmo.Palette.label : Atmo.Palette.secondary)
            .frame(minWidth: 17, minHeight: 16)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            )
            .accessibilityLabel(Self.spokenName(for: text))
    }

    static func spokenName(for text: String) -> String {
        switch text {
        case "⌘": return "Command"
        case "⇧": return "Shift"
        case "⌥": return "Option"
        case "⏎", "↩": return "Return"
        case "⎋": return "Escape"
        case "⌫": return "Delete"
        case "\\": return "Backslash"
        case "`": return "Backtick"
        default: return text
        }
    }
}

/// Keys plus a caption, the unit the footer and the shortcut sheet share.
struct ShortcutHint: View {
    let keys: [String]
    let caption: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCap(key)
            }
            Text(caption)
                .font(Atmo.Font.micro)
                .foregroundStyle(Atmo.Palette.tertiary)
                .padding(.leading, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption), \(keys.map(KeyCap.spokenName(for:)).joined(separator: " "))")
    }
}
