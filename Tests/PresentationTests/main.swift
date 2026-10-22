import AppKit

for chip in ["Apple M2", "Apple M2 Pro", "Apple M2 Max", "Apple M2 Ultra", "Apple M3", "Apple M3 Pro",
             "Apple M4", "Apple M4 Max", "Apple M5", "Apple M5 Pro", "Apple M10"] {
    precondition(PlatformRequirements.supports(chip), chip)
}
for chip in ["Apple M1", "Apple M1 Pro", "Apple M1 Max", "Apple M1 Ultra", "Apple M",
             "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", "Unknown processor"] {
    precondition(!PlatformRequirements.supports(chip), chip)
}
let icons = GazeMode.allCases.map { MenuIcon.image(mode: $0) }
for icon in icons {
    precondition(icon.isTemplate && icon.size == NSSize(width: 22, height: 18))
    precondition(icon.tiffRepresentation != nil)
}
precondition(Set(icons.map { $0.tiffRepresentation! }).count == 3, "Each mode needs its own status icon")
let review = URLComponents(url: AppStoreLinks.writeReview, resolvingAgainstBaseURL: false)!
precondition(review.scheme == "macappstore" && review.host == "apps.apple.com" && review.path == "/app/id6814174298")
precondition(review.queryItems == [URLQueryItem(name: "action", value: "write-review")])
for (last, current, before, expected) in [
    ("1.0.1", "1.1.0", true, true), ("1.0.9", "1.0.10", true, true), (nil, "1.1.0", true, true),
    ("1.1.0", "1.1.0", true, false), ("1.2.0", "1.1.0", true, false), (nil, "1.1.0", false, false)
] as [(String?, String, Bool, Bool)] {
    precondition(ReleaseNotes.shouldShow(lastLaunched: last, current: current, launchedBefore: before) == expected,
                 "\(last ?? "none") -> \(current), launched before: \(before)")
}
precondition(!ReleaseNotes.items.isEmpty && ReleaseNotes.items.allSatisfy {
    NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil && !$0.title.isEmpty && !$0.detail.isEmpty
})
print("Processor support policy, review link, What's New policy and menu icon checks passed")

for (state, correcting, mode, icon, status, enabled, badge) in [
    (CameraLifecycle.State.idle, true, GazeMode.off, GazeMode.off, "Off", true, "Off"),
    (.starting, false, .passThrough, .off, "Starting…", false, "…"),
    (.starting, true, .lockedGaze, .off, "Starting…", false, "…"),
    (.active, false, .passThrough, .passThrough, "Pass-through", true, "Pass"),
    (.active, true, .lockedGaze, .lockedGaze, "Locked Gaze", true, "On"),
    (.stopping, true, .off, .off, "Stopping…", false, "…")
] {
    let snapshot = CameraPresentation(state: state, correcting: correcting)
    precondition(snapshot.mode == mode && snapshot.iconMode == icon && snapshot.status == status)
    precondition(snapshot.canSwitch == enabled && snapshot.dockBadge == badge, "\(state) \(correcting)")
    let closing = CameraPresentation(state: state, correcting: correcting, closing: true)
    precondition(closing.mode == .off && closing.iconMode == .off && !closing.canSwitch && closing.status == "Stopping…")
}
print("PASS: checked mode, availability, status icon, Dock state and termination override")
