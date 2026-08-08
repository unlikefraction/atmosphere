import AppKit

enum OverlayFramePersistence {
    static let autosaveName = "AtmosphereOverlayPanelFrame"

    /// A restored panel is usable only when enough of it remains visible to
    /// grab and move. This protects persisted coordinates when a display is
    /// disconnected or its resolution/arrangement changes.
    static func isReachable(
        _ frame: NSRect,
        in visibleScreenFrames: [NSRect]
    ) -> Bool {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }

        let requiredWidth = min(frame.width, 96)
        let requiredHeight = min(frame.height, 44)

        return visibleScreenFrames.contains { screenFrame in
            let intersection = frame.intersection(screenFrame)
            return !intersection.isNull
                && intersection.width >= requiredWidth
                && intersection.height >= requiredHeight
        }
    }

    static let screenMargin: CGFloat = 12

    /// The frame the panel should take when its content wants `height`.
    ///
    /// The bottom edge is the anchor. The prompt lives at the bottom of the
    /// panel, so answers have to unfurl upward for the prompt to stay exactly
    /// where the eye — and the cursor — left it. Only when growth would run off
    /// the top of the display does the whole panel slide to stay on screen.
    static func frame(
        growing current: NSRect,
        to height: CGFloat,
        within visibleScreenFrame: NSRect?
    ) -> NSRect {
        guard height.isFinite, height > 0 else { return current }

        var frame = NSRect(
            x: current.minX,
            y: current.minY,
            width: current.width,
            height: height
        )

        guard let visible = visibleScreenFrame, visible.height > 0 else { return frame }

        if frame.height >= visible.height - (screenMargin * 2) {
            frame.origin.y = visible.midY - (frame.height / 2)
            return frame
        }
        if frame.maxY > visible.maxY - screenMargin {
            frame.origin.y = visible.maxY - screenMargin - frame.height
        }
        if frame.minY < visible.minY + screenMargin {
            frame.origin.y = visible.minY + screenMargin
        }
        return frame
    }
}
