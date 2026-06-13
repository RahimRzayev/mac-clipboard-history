import AppKit
import ApplicationServices

/// Panel placement cascade (spec §9): caret → mouse pointer → screen center,
/// always clamped to the target screen's visibleFrame.
@MainActor
enum PanelPositioner {
    static func origin(for size: NSSize, placement: PanelPlacement) -> NSPoint {
        switch placement {
        case .center:
            return centeredOrigin(size: size)
        case .auto:
            if let caret = caretRect() {
                let proposed = NSPoint(x: caret.minX, y: caret.minY - size.height - 8)
                return clamped(proposed, size: size, near: NSPoint(x: caret.midX, y: caret.midY))
            }
            let mouse = NSEvent.mouseLocation
            let proposed = NSPoint(x: mouse.x - 24, y: mouse.y - size.height + 24)
            return clamped(proposed, size: size, near: mouse)
        }
    }

    /// Focused-element caret bounds via AX, in Cocoa (bottom-left origin) coordinates.
    /// Requires Accessibility trust; fails in non-AX-compliant apps — callers fall through.
    private static func caretRect() -> NSRect? {
        guard AccessibilityPermission.isTrustedForAX else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        // These AX calls are synchronous IPC to the frontmost app, on the main actor, with
        // a ~6s default timeout per call. A beachballing target would freeze the whole app —
        // cap the wait so we degrade to the mouse-position fallback in ~100ms instead.
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement // swiftlint:disable:this force_cast
        AXUIElementSetMessagingTimeout(focused, 0.1)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, rangeRef, &boundsRef
        ) == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }

        var axRect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &axRect), // swiftlint:disable:this force_cast
              axRect != .zero else { return nil }

        // AX coordinates are top-left-origin relative to the primary screen; flip to Cocoa.
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaY = primary.frame.height - axRect.origin.y - axRect.height
        return NSRect(x: axRect.origin.x, y: cocoaY, width: axRect.width, height: axRect.height)
    }

    private static func centeredOrigin(size: NSSize) -> NSPoint {
        let frame = screen(near: NSEvent.mouseLocation).visibleFrame
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + (frame.height - size.height) * 0.55
        )
    }

    private static func clamped(_ proposed: NSPoint, size: NSSize, near point: NSPoint) -> NSPoint {
        let frame = screen(near: point).visibleFrame
        let x = min(max(proposed.x, frame.minX + 8), frame.maxX - size.width - 8)
        let y = min(max(proposed.y, frame.minY + 8), frame.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    private static func screen(near point: NSPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
