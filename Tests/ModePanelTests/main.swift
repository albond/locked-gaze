import AppKit
import AVFoundation

let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
precondition(ModePanelLayout.origin(for: NSSize(width: 300, height: 200), in: visible) == NSPoint(x: 1202, y: 736))
let second = NSRect(x: -1920, y: 100, width: 1920, height: 1055)
precondition(ModePanelLayout.origin(for: NSSize(width: 300, height: 320), in: second) == NSPoint(x: -310, y: 827))
print("Panel opens below the menu bar at the right edge of the screen in use")

let usb = CameraChoice(id: "usb", name: "USB Camera", connected: true)
let builtIn = CameraChoice(id: "builtin", name: "FaceTime HD Camera", connected: true)
let symbols = ["builtin": "laptopcomputer"]

let automatic = PanelCameraList.rows(cameras: [builtIn, usb], symbols: symbols, selectedID: nil)
precondition(automatic.map(\.name) == ["Automatic (System Preferred)", "FaceTime HD Camera", "USB Camera"])
precondition(automatic.map(\.selected) == [true, false, false] && automatic.allSatisfy(\.selectable))
precondition(automatic.map(\.cameraID) == [nil, "builtin", "usb"])
precondition(automatic.map(\.symbol) == ["sparkles", "laptopcomputer", "web.camera"])

let chosen = PanelCameraList.rows(cameras: [builtIn, usb], symbols: symbols, selectedID: "usb")
precondition(chosen.map(\.selected) == [false, false, true])

let missing = PanelCameraList.rows(cameras: [builtIn], symbols: symbols, selectedID: "usb")
precondition(missing.last == PanelCamera(id: "unavailable", cameraID: "usb", name: "Selected Camera Unavailable",
                                         symbol: "video.slash", selectable: false, selected: true))
precondition(missing.filter(\.selected).count == 1)

let empty = PanelCameraList.rows(cameras: [], symbols: [:], selectedID: nil)
precondition(empty.map(\.name) == ["Automatic (System Preferred)", "No Cameras Connected"])
precondition(empty.map(\.selectable) == [true, false])
precondition(Set(missing.map(\.id)).count == missing.count && Set(empty.map(\.id)).count == empty.count)

precondition(PanelCameraList.symbol(for: .builtInWideAngleCamera) == "laptopcomputer")
precondition(PanelCameraList.symbol(for: .continuityCamera) == "iphone")
precondition(PanelCameraList.symbol(for: .external) == "web.camera")
for row in automatic + missing + empty {
    precondition(NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil) != nil, row.symbol)
}
for mode in GazeMode.allCases {
    precondition(NSImage(systemSymbolName: ModePanelView.symbol(mode), accessibilityDescription: nil) != nil)
}
print("PASS: panel camera rows match the Source Camera menu and every symbol exists")
