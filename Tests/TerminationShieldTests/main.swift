import AppKit

MainActor.assumeIsolated {
    _ = NSApplication.shared
    func onScreen() -> [NSWindow] { NSApp.windows.filter(\.isVisible) }

    let shield = TerminationShield()
    precondition(!shield.isHeld && onScreen().isEmpty)
    print("An idle camera keeps no window")

    shield.set(held: true)
    precondition(shield.isHeld && onScreen().count == 1)
    let window = onScreen()[0]
    precondition(window.frame.size == NSSize(width: 1, height: 1))
    precondition(!window.isOpaque && window.backgroundColor == .clear && !window.hasShadow)
    precondition(window.ignoresMouseEvents && !window.canBecomeKey && !window.canBecomeMain)
    precondition(window.sharingType == .none && window.isExcludedFromWindowsMenu)
    precondition(window.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]))
    print("A running camera holds one transparent, click-through 1×1 window on every Space")

    // Repeated activation, e.g. Pass-through to Locked Gaze or a source camera restart.
    for _ in 0..<25 { shield.set(held: true) }
    precondition(onScreen().count == 1 && onScreen()[0] === window)
    print("Repeated activation reuses the window")

    shield.set(held: false); shield.set(held: false)
    precondition(!shield.isHeld && onScreen().isEmpty)
    print("Stopping the camera removes the window")

    for _ in 0..<25 { shield.set(held: true); shield.set(held: false) }
    precondition(!shield.isHeld && onScreen().isEmpty)
    shield.set(held: true)
    precondition(shield.isHeld && onScreen().count == 1)
    shield.set(held: false)
    print("The window returns with the next activation")
}
