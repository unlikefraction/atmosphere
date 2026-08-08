import AppKit
import SwiftUI

enum ComposerKeyAction: Equatable {
    case submit
    case insertNewline
    case consume
    case deferToTextSystem
}

enum ComposerKeyPolicy {
    static func action(
        for commandSelector: Selector,
        modifiers: NSEvent.ModifierFlags,
        hasMarkedText: Bool,
        isRepeat: Bool
    ) -> ComposerKeyAction {
        guard !hasMarkedText else { return .deferToTextSystem }

        let isReturn = commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        guard isReturn else { return .deferToTextSystem }

        let actionModifiers = modifiers.intersection([
            .command,
            .control,
            .option,
            .shift
        ])

        if actionModifiers.contains(.shift) {
            return .insertNewline
        }

        guard actionModifiers.isEmpty || actionModifiers == [.command] else {
            return .deferToTextSystem
        }

        return isRepeat ? .consume : .submit
    }
}

enum ComposerFocusPolicy {
    static func shouldFocus(
        isRequested: Bool,
        isEnabled: Bool,
        isWindowVisible: Bool,
        hasAttachedSheet: Bool
    ) -> Bool {
        isRequested && isEnabled && isWindowVisible && !hasAttachedSheet
    }
}

/// Native multiline composer behavior that SwiftUI's vertical `TextField`
/// cannot express: Return submits while Shift-Return inserts a line break.
/// Keeping the actual NSTextView inside a scroll view also lets AppKit keep the
/// insertion point visible after a large paste.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    /// Bumped by the caller to request "focus and select everything", the
    /// behavior a location bar gives you for free.
    var selectAllGeneration: UInt = 0
    let isEnabled: Bool
    var font: NSFont = Atmo.Font.prompt
    let placeholder: String
    let onSubmit: () -> Void
    /// Fired when the user, not the app, changed the text.
    var onEdit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ComposerTextScrollView {
        let scrollView = ComposerTextScrollView()
        scrollView.textView.delegate = context.coordinator
        configureHeightReporting(for: scrollView, coordinator: context.coordinator)
        scrollView.apply(font: font)
        scrollView.textView.placeholder = placeholder
        scrollView.textView.setAccessibilityLabel(placeholder)
        scrollView.textView.string = text
        context.coordinator.lastSelectAllGeneration = selectAllGeneration
        scrollView.refreshLayout(scrollToSelection: true)
        return scrollView
    }

    func updateNSView(_ scrollView: ComposerTextScrollView, context: Context) {
        context.coordinator.parent = self
        configureHeightReporting(for: scrollView, coordinator: context.coordinator)

        let textView = scrollView.textView
        scrollView.apply(font: font)
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            scrollView.refreshLayout(scrollToSelection: true)
        }

        if context.coordinator.lastSelectAllGeneration != selectAllGeneration {
            context.coordinator.lastSelectAllGeneration = selectAllGeneration
            textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        }

        DispatchQueue.main.async { [weak scrollView] in
            guard let scrollView, let window = scrollView.window else { return }
            let textView = scrollView.textView
            if isFocused, isEnabled {
                guard ComposerFocusPolicy.shouldFocus(
                    isRequested: true,
                    isEnabled: true,
                    isWindowVisible: window.isVisible,
                    hasAttachedSheet: window.attachedSheet != nil
                ) else { return }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            } else if window.firstResponder === textView {
                window.makeFirstResponder(nil)
            }
        }
    }

    private func configureHeightReporting(
        for scrollView: ComposerTextScrollView,
        coordinator: Coordinator
    ) {
        scrollView.onPreferredHeightChange = { [weak scrollView, weak coordinator] height in
            coordinator?.updateMeasuredHeight(height)

            // SwiftUI applies the exact new frame after the binding changes.
            // Re-scroll on the following run-loop turn so a paste or newline
            // keeps the insertion point visible in that final geometry.
            DispatchQueue.main.async { [weak scrollView] in
                guard let textView = scrollView?.textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastSelectAllGeneration: UInt = 0

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func updateMeasuredHeight(_ height: CGFloat) {
            guard abs(parent.measuredHeight - height) > 0.5 else { return }
            parent.measuredHeight = height
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerNSTextView else { return }
            parent.text = textView.string
            parent.onEdit()
            if let scrollView = textView.enclosingScrollView as? ComposerTextScrollView {
                scrollView.refreshLayout(scrollToSelection: true)
            }
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            let event = NSApp.currentEvent
            let action = ComposerKeyPolicy.action(
                for: commandSelector,
                modifiers: event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [],
                hasMarkedText: textView.hasMarkedText(),
                isRepeat: event?.isARepeat ?? false
            )

            switch action {
            case .submit:
                parent.onSubmit()
                return true
            case .consume:
                return true
            case .insertNewline, .deferToTextSystem:
                return false
            }
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scrollRangeToVisible(selectedRange())
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let font = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        placeholder.draw(
            at: origin,
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor.placeholderTextColor
            ]
        )
    }
}

final class ComposerTextScrollView: NSScrollView {
    static let minimumHeight: CGFloat = 24
    static let maximumHeight: CGFloat = 132

    let textView = ComposerNSTextView(frame: .zero)
    var onPreferredHeightChange: ((CGFloat) -> Void)?
    private var preferredHeight = minimumHeight
    private var lastReportedHeight: CGFloat?
    private var isRefreshingLayout = false

    var currentPreferredHeight: CGFloat {
        preferredHeight
    }

    func apply(font: NSFont) {
        guard textView.font != font else { return }
        textView.font = font
        textView.typingAttributes[.font] = font
        refreshLayout(scrollToSelection: false)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        borderType = .noBorder
        drawsBackground = false
        // A borderless prompt must never draw AppKit's focus ring; it lands as
        // a rounded rectangle behind the field with the wrong radius.
        focusRingType = .none
        hasHorizontalScroller = false
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay

        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Atmo.Font.prompt
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 1, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: Self.minimumHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    override func layout() {
        super.layout()
        refreshLayout(scrollToSelection: false)
    }

    func refreshLayout(scrollToSelection: Bool) {
        guard !isRefreshingLayout else { return }
        isRefreshingLayout = true
        defer { isRefreshingLayout = false }

        // A representable is initially created before SwiftUI proposes its real
        // width. Measuring against that transient zero-width state would make a
        // short draft appear to need the maximum height for one frame.
        guard contentSize.width > 1 else { return }
        let availableWidth = contentSize.width
        if textView.frame.width != availableWidth {
            textView.setFrameSize(NSSize(width: availableWidth, height: textView.frame.height))
        }
        textView.textContainer?.containerSize = NSSize(
            width: availableWidth,
            height: CGFloat.greatestFiniteMagnitude
        )

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(
            forCharacterRange: NSRange(
                location: 0,
                length: textView.textStorage?.length ?? 0
            )
        )

        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let rawHeight = max(
            Self.minimumHeight,
            ceil(usedHeight + (textView.textContainerInset.height * 2))
        )
        let nextPreferredHeight = min(rawHeight, Self.maximumHeight)
        let documentHeight = max(rawHeight, bounds.height)

        if textView.frame.height != documentHeight {
            textView.setFrameSize(NSSize(width: availableWidth, height: documentHeight))
        }
        hasVerticalScroller = rawHeight > Self.maximumHeight

        if abs(preferredHeight - nextPreferredHeight) > 0.5 {
            preferredHeight = nextPreferredHeight
            invalidateIntrinsicContentSize()
        }

        let shouldReportHeight = lastReportedHeight.map {
            abs($0 - nextPreferredHeight) > 0.5
        } ?? true
        if shouldReportHeight {
            lastReportedHeight = nextPreferredHeight
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      abs(self.preferredHeight - nextPreferredHeight) <= 0.5 else { return }
                self.onPreferredHeightChange?(nextPreferredHeight)
            }
        }

        textView.needsDisplay = true
        guard scrollToSelection else { return }
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }
}
