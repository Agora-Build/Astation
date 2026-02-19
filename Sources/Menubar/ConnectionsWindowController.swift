import Cocoa
import SwiftUI

/// A window that shows connected Atem clients and their registered agents.
/// Opens as a separate panel from the menubar, stays on screen until closed.
class ConnectionsWindowController: NSWindowController {

    convenience init(hubManager: AstationHubManager) {
        let content = ConnectionsView(hubManager: hubManager)
        let host = NSHostingController(rootView: content)

        let window = NSWindow(contentViewController: host)
        window.title = "Clients & Agents"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 720, height: 480))
        window.minSize = NSSize(width: 620, height: 360)
        window.center()
        // Keep window above other app windows but don't steal focus from IDE
        window.level = .floating

        self.init(window: window)
    }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
