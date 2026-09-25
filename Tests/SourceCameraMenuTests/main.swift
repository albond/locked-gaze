import AppKit

@MainActor final class MenuTarget: NSObject {
    @objc func selectCamera(_ item: NSMenuItem) {}
}

MainActor.assumeIsolated {
    let target = MenuTarget()
    let menu = NSMenu(title: "Source Camera")
    let devices = [CameraChoice(id: "test-usb", name: "USB Camera", connected: true)]
    @MainActor func populate(_ selected: String?, devices: [CameraChoice] = devices, enabled: Bool = true) {
        SourceCameraMenu.populate(menu, devices: devices, selectedID: selected,
            enabled: enabled, target: target, action: #selector(MenuTarget.selectCamera(_:)))
        precondition(menu.items.filter { $0.state == .on }.count == 1,
                     "The source menu must always identify exactly one selection")
    }
    // A clean preference domain must show Automatic before any menu interaction.
    let domain = "source-menu-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    populate(defaults.string(forKey: "sourceCameraID"))
    precondition(menu.items[0].title == "Automatic (System Preferred)" && menu.items[0].state == .on)
    precondition(menu.items[0].representedObject == nil)
    defaults.set("test-usb", forKey: "sourceCameraID")
    populate(defaults.string(forKey: "sourceCameraID"))
    precondition(menu.items[0].state == .off && menu.items[2].state == .on)
    defaults.removeObject(forKey: "sourceCameraID")
    populate(defaults.string(forKey: "sourceCameraID"))
    precondition(menu.items[0].state == .on && menu.items[2].state == .off)
    populate(nil, devices: [])
    precondition(menu.items[0].state == .on && !menu.items.last!.isEnabled)
    populate("disconnected", devices: [])
    precondition(menu.items.first { $0.state == .on }?.title == "Selected Camera Unavailable")
    populate(nil, enabled: false)
    precondition(menu.items[0].state == .on && !menu.items[0].isEnabled)
}
print("PASS: first-launch Automatic checkmark, explicit selection, return to Automatic, no cameras, disconnected selection and busy state")
