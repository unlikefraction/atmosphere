import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// A native mouse target behind the footer, leaving its controls in front.
struct OverlayWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> OverlayWindowDragView {
        OverlayWindowDragView()
    }

    func updateNSView(_ nsView: OverlayWindowDragView, context: Context) {}
}

final class OverlayWindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
