import AppKit

/// Builds every item from one selection snapshot, including the default choice.
@MainActor
enum SourceCameraMenu {
    static func populate(_ menu: NSMenu, devices: [CameraChoice], selectedID: String?,
                         enabled: Bool, target: AnyObject, action: Selector) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        func add(_ title: String, id: String?) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = id
            item.state = selectedID == id ? .on : .off
            item.isEnabled = enabled
        }
        add("Automatic (System Preferred)", id: nil)
        menu.addItem(.separator())
        for device in devices { add(device.name, id: device.id) }
        if let selectedID, !devices.contains(where: { $0.id == selectedID }) {
            let missing = menu.addItem(withTitle: "Selected Camera Unavailable", action: nil, keyEquivalent: "")
            missing.state = .on
            missing.isEnabled = false
        }
        if devices.isEmpty {
            let empty = menu.addItem(withTitle: "No Cameras Connected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
    }
}
