import AppKit

/// Keeps macOS from terminating the app while the camera runs and no window is on screen.
///
/// A menu bar app resists termination only as "non-interactive", the level at which
/// low-disk cache purging may terminate a sandboxed app to clear its container caches.
/// A window on screen, visible or occluded, raises that to "interactive". The status
/// item is the app's only window, and it goes away whenever the menu bar does, e.g. on
/// a full-screen Space. One transparent 1×1 window stands in for it during a call.
@MainActor
final class TerminationShield {
    private var window: NSWindow?
    var isHeld: Bool { window != nil }

    func set(held: Bool) {
        guard held != isHeld else { return }
        guard held else { window?.orderOut(nil); window = nil; return }
        let shield = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: .borderless, backing: .buffered, defer: false)
        shield.isReleasedWhenClosed = false
        shield.isOpaque = false; shield.backgroundColor = .clear; shield.hasShadow = false
        shield.ignoresMouseEvents = true
        // Stay out of screen sharing, window pickers, the Window menu and Mission Control.
        shield.sharingType = .none
        shield.isExcludedFromWindowsMenu = true
        shield.setAccessibilityElement(false)
        shield.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        shield.orderFrontRegardless()
        window = shield
    }
}
