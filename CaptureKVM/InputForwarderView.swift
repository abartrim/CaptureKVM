import SwiftUI
import AppKit

struct InputForwarderView: NSViewRepresentable {
    var isActive: Bool
    var onKeyDown: (NSEvent) -> Void
    var onKeyUp: (NSEvent) -> Void
    var onFlagsChanged: (NSEvent) -> Void
    var onMouseMove: (CGFloat, CGFloat) -> Void
    var onMouseButton: (Bool, Int) -> Void
    var onScroll: (CGFloat, CGFloat) -> Void
    var onEscapeRelease: () -> Void
    var onPasteFromHost: () -> Void

    func makeNSView(context: Context) -> ForwarderView {
        let v = ForwarderView()
        v.onKeyDown = onKeyDown
        v.onKeyUp = onKeyUp
        v.onFlagsChanged = onFlagsChanged
        v.onMouseMove = onMouseMove
        v.onMouseButton = onMouseButton
        v.onScroll = onScroll
        v.onEscapeRelease = onEscapeRelease
        v.onPasteFromHost = onPasteFromHost
        return v
    }

    func updateNSView(_ nsView: ForwarderView, context: Context) {
        nsView.isActive = isActive
        nsView.setCursorCaptured(isActive)
        if isActive {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class ForwarderView: NSView {
        var isActive: Bool = false
        var onKeyDown: ((NSEvent) -> Void)?
        var onKeyUp: ((NSEvent) -> Void)?
        var onFlagsChanged: ((NSEvent) -> Void)?
        var onMouseMove: ((CGFloat, CGFloat) -> Void)?
        var onMouseButton: ((Bool, Int) -> Void)?
        var onScroll: ((CGFloat, CGFloat) -> Void)?
        var onEscapeRelease: (() -> Void)?
        var onPasteFromHost: (() -> Void)?

        private var trackingArea: NSTrackingArea?
        private var cursorCaptured: Bool = false

        func setCursorCaptured(_ capture: Bool) {
            if capture && !cursorCaptured {
                // Move the cursor onto this view first so mouseMoved events come to us
                // (otherwise the cursor stays wherever the user clicked the toggle and
                // events route to that view instead).
                warpCursorToViewCenter()
                NSCursor.hide()
                CGAssociateMouseAndMouseCursorPosition(0)
                cursorCaptured = true
            } else if !capture && cursorCaptured {
                CGAssociateMouseAndMouseCursorPosition(1)
                NSCursor.unhide()
                cursorCaptured = false
            }
        }

        private func warpCursorToViewCenter() {
            guard let window = self.window else { return }
            let centerInView = NSPoint(x: bounds.midX, y: bounds.midY)
            let centerInWindow = convert(centerInView, to: nil)
            let centerInScreen = window.convertPoint(toScreen: centerInWindow)
            // CGWarpMouseCursorPosition uses global display coords with origin at the
            // top-left of the primary display, whereas NSScreen uses bottom-left.
            guard let primary = NSScreen.screens.first else { return }
            let flippedY = primary.frame.maxY - centerInScreen.y
            CGWarpMouseCursorPosition(CGPoint(x: centerInScreen.x, y: flippedY))
        }

        deinit {
            // Safety net: ensure cursor is restored if the view goes away mid-capture.
            if cursorCaptured {
                CGAssociateMouseAndMouseCursorPosition(1)
                NSCursor.unhide()
            }
        }

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.clear.setFill()
            dirtyRect.fill()
        }

        // Tracking area is required for mouseMoved (without buttons held) to be delivered.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let opts: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
            let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func keyDown(with event: NSEvent) {
            // fn+Esc releases capture; plain Esc passes through to the target.
            if event.keyCode == 53, event.modifierFlags.contains(.function) {
                onEscapeRelease?()
                return
            }
            // Cmd+Shift+V pastes the host clipboard into the target (synthesized keystrokes).
            if event.keyCode == 9,
               event.modifierFlags.contains(.command),
               event.modifierFlags.contains(.shift) {
                onPasteFromHost?()
                return
            }
            onKeyDown?(event)
        }

        override func keyUp(with event: NSEvent) {
            onKeyUp?(event)
        }

        // macOS delivers modifier key state changes (Shift/Ctrl/Option/Cmd) via flagsChanged, not keyDown/keyUp.
        override func flagsChanged(with event: NSEvent) {
            onFlagsChanged?(event)
        }

        override func mouseMoved(with event: NSEvent) {
            guard isActive else { return }
            onMouseMove?(event.deltaX, event.deltaY)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isActive else { return }
            onMouseMove?(event.deltaX, event.deltaY)
        }

        override func rightMouseDragged(with event: NSEvent) {
            guard isActive else { return }
            onMouseMove?(event.deltaX, event.deltaY)
        }

        override func otherMouseDragged(with event: NSEvent) {
            guard isActive else { return }
            onMouseMove?(event.deltaX, event.deltaY)
        }

        override func scrollWheel(with event: NSEvent) {
            guard isActive else { return }
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY)
        }

        override func mouseDown(with event: NSEvent) { onMouseButton?(true, 1) }
        override func mouseUp(with event: NSEvent) { onMouseButton?(false, 1) }
        override func rightMouseDown(with event: NSEvent) { onMouseButton?(true, 2) }
        override func rightMouseUp(with event: NSEvent) { onMouseButton?(false, 2) }
        override func otherMouseDown(with event: NSEvent) { onMouseButton?(true, 3) }
        override func otherMouseUp(with event: NSEvent) { onMouseButton?(false, 3) }
    }
}
