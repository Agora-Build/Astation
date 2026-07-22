import Cocoa
import SwiftUI

/// A window that shows connected Atem clients and their registered agents.
/// Opens as a separate panel from the menubar, stays on screen until closed.
class ConnectionsWindowController: NSWindowController {
    private var remoteControlWindowController: RemoteControlWindowController?

    convenience init(hubManager: AstationHubManager) {
        let remoteControl = RemoteControlWindowController(hubManager: hubManager)
        let content = ConnectionsView(
            hubManager: hubManager,
            onRemoteControl: { clientId, agent in
                remoteControl.showWindow(clientId: clientId, agent: agent)
            }
        )
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
        remoteControlWindowController = remoteControl
    }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
