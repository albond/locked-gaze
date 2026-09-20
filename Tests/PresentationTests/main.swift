import AppKit

for chip in ["Apple M2 Pro", "Apple M2 Max", "Apple M2 Ultra", "Apple M3 Pro", "Apple M4 Max", "Apple M5 Pro"] {
    precondition(PlatformRequirements.supports(chip), chip)
}
for chip in ["Apple M1 Ultra", "Apple M2", "Apple M3", "Apple M4", "Intel Core i9", "Unknown processor"] {
    precondition(!PlatformRequirements.supports(chip), chip)
}
for active in [false, true] {
    let icon = MenuIcon.image(active: active)
    precondition(icon.isTemplate && icon.size == NSSize(width: 22, height: 18))
    precondition(icon.tiffRepresentation != nil)
}
print("Processor support policy and menu icon checks passed")

for (state, title, active, enabled, badge) in [
    (CameraLifecycle.State.idle, "Activate", false, true, "Off"),
    (.starting, "Starting…", false, false, "…"),
    (.active, "Deactivate", true, true, "On"),
    (.stopping, "Stopping…", false, false, "…")
] {
    let snapshot = CameraPresentation(state: state)
    precondition(snapshot.actionTitle == title && snapshot.active == active)
    precondition(snapshot.canToggle == enabled && snapshot.dockBadge == badge)
    let closing = CameraPresentation(state: state, closing: true)
    precondition(!closing.active && !closing.canToggle && closing.actionTitle == "Stopping…")
}
precondition(MenuIcon.image(active: true).tiffRepresentation != MenuIcon.image(active: false).tiffRepresentation)
print("PASS: unified toggle title, availability, active icon, Dock state and termination override")
