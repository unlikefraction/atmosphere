import AppKit
import Foundation
import SwiftStreamingMarkdown
import SwiftUI

/// A current-value stream for a single assistant message. Every new consumer
/// immediately receives the latest full Markdown snapshot, so a LazyVStack row
/// can leave and re-enter the view hierarchy without becoming blank.
final class MarkdownSnapshotSource: ObservableObject, StreamedMarkdownSource {
    typealias Continuation = AsyncStream<String>.Continuation

    private let lock = NSLock()
    private var current: String
    private var isFinal: Bool
    private var continuations: [UUID: Continuation] = [:]

    init(initial: String, isFinal: Bool) {
        current = initial
        self.isFinal = isFinal
    }

    var text: AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            let id = UUID()
            lock.lock()
            if !isFinal {
                continuations[id] = continuation
            }
            // Yield while holding the lock so a concurrent publish cannot
            // overtake this initial current-value replay.
            if !current.isEmpty {
                continuation.yield(current)
            }
            if isFinal {
                continuation.finish()
            }
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    func publish(_ value: String, isFinal: Bool) {
        lock.lock()
        guard !self.isFinal else {
            lock.unlock()
            return
        }

        let changed = value != current
        current = value
        if isFinal {
            self.isFinal = true
        }
        let targets = Array(continuations.values)
        if isFinal {
            continuations.removeAll()
        }
        lock.unlock()

        if changed, !value.isEmpty {
            targets.forEach { $0.yield(value) }
        }
        if isFinal {
            targets.forEach { $0.finish() }
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

struct MarkdownMessageView: View {
    let messageID: UUID
    let source: String
    let isStreaming: Bool

    @StateObject private var feed: MarkdownSnapshotSource

    init(messageID: UUID, source: String, isStreaming: Bool) {
        self.messageID = messageID
        self.source = source
        self.isStreaming = isStreaming
        _feed = StateObject(
            wrappedValue: MarkdownSnapshotSource(
                initial: source,
                isFinal: !isStreaming
            )
        )
    }

    var body: some View {
        StreamedMarkdownView(source: feed, config: AtmosphereMarkdownTheme.config)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, safeOpenURLAction)
            .id(messageID)
            .onChange(of: source) { _, newValue in
                feed.publish(newValue, isFinal: !isStreaming)
            }
            .onChange(of: isStreaming) { _, newValue in
                feed.publish(source, isFinal: !newValue)
            }
    }

    private var safeOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                return .discarded
            }
            return NSWorkspace.shared.open(url) ? .handled : .discarded
        }
    }
}

private enum AtmosphereMarkdownTheme {
    private static let primary = Color(nsColor: .labelColor)
    private static let secondary = Color(nsColor: .secondaryLabelColor)
    private static let accent = Color(nsColor: .linkColor)
    private static let controlBackground = Color(nsColor: .controlBackgroundColor)
    private static let subtleBackground = Color(nsColor: .quaternarySystemFill)
    private static let separator = Color(nsColor: .separatorColor)

    private static let body = fonts(size: 13, lineHeight: 18)
    private static let caption = fonts(size: 11, lineHeight: 15)
    private static let code = monospacedFonts(size: 12, lineHeight: 17)
    private static let h1 = fonts(size: 18, weight: .semibold, lineHeight: 23)
    private static let h2 = fonts(size: 16, weight: .semibold, lineHeight: 21)
    private static let h3 = fonts(size: 14, weight: .semibold, lineHeight: 19)
    private static let h4 = fonts(size: 13, weight: .semibold, lineHeight: 18)

    static let config = MarkdownRenderConfig(
        shouldAnimateText: false,
        blockQuoteStyle: MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: body,
            textColor: secondary
        ),
        headingStyle: MarkdownRenderConfig.MarkdownHeadingTextStyle(
            h1Font: h1,
            h2Font: h2,
            h3Font: h3,
            h4Font: h4,
            h5Font: h4,
            h6Font: h4,
            textColor: primary
        ),
        orderedListStyle: MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: body,
            textColor: primary
        ),
        paragraphStyle: MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: body,
            textColor: primary
        ),
        tableStyle: MarkdownRenderConfig.MarkdownTableTextStyle(
            textFonts: caption,
            headerTextColor: primary,
            regularTextColor: primary,
            headerBackgroundColor: subtleBackground,
            borderColor: separator,
            actionButtonColor: accent
        ),
        inlineStyle: MarkdownRenderConfig.MarkdownInlineTextStyle(
            boldTextColor: primary,
            linkTextFont: body.normal,
            linkTextColor: accent,
            codeTextFont: code.normal,
            codeTextColor: primary,
            codeBackgroundColor: subtleBackground,
            codeUnderlineColor: .clear
        ),
        citationConfig: MarkdownRenderConfig.CitationConfig(
            isEnabled: false,
            font: caption.normal,
            textColor: primary,
            backgroundColor: subtleBackground
        ),
        codeBlockConfig: CodeBlockConfig(
            theme: .xcode,
            backgroundColor: controlBackground,
            foregroundColor: secondary
        ),
        blockSpacing: 10,
        textSelectionConfig: TextSelectionConfig(
            isEnabled: true,
            backgroundColor: Color(nsColor: .textBackgroundColor)
        ),
        thematicBreakColor: separator,
        imageConfig: .disabled
    )

    private static func fonts(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        lineHeight: CGFloat
    ) -> TextFonts {
        TextFonts(
            normal: systemFont(size: size, weight: weight),
            italic: systemFont(size: size, weight: weight, italic: true),
            bold: systemFont(size: size, weight: .semibold),
            boldItalic: systemFont(size: size, weight: .semibold, italic: true),
            preferredLetterSpacing: nil,
            preferredLineHeight: lineHeight
        )
    }

    private static func monospacedFonts(size: CGFloat, lineHeight: CGFloat) -> TextFonts {
        TextFonts(
            normal: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            italic: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            bold: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
            boldItalic: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
            preferredLetterSpacing: nil,
            preferredLineHeight: lineHeight
        )
    }

    private static func systemFont(
        size: CGFloat,
        weight: NSFont.Weight,
        italic: Bool = false
    ) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return base }
        let traits = base.fontDescriptor.symbolicTraits.union(.italic)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
