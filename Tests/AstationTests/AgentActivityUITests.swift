import AppKit
import XCTest
@testable import Menubar

final class AgentActivityUITests: XCTestCase {
    @MainActor
    func testTerminalActivityFollowsReleaseAndFitsAtMinimumWindowWidth() throws {
        _ = NSApplication.shared
        let fixture = try TerminalHubFixture(verified: false)
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = RemoteControlWindowController(hubManager: fixture.hub)
        controller.showWindow(clientId: fixture.clientId, agent: nil)
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.title == "Remote Terminal" && !previous.contains(ObjectIdentifier($0))
        })
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let controls = try XCTUnwrap(content.subviews.compactMap { $0 as? NSStackView }.first {
            $0.arrangedSubviews.compactMap { $0 as? NSButton }.contains { $0.title == "Release" }
        })
        let buttons = controls.arrangedSubviews.compactMap { $0 as? NSButton }
        let release = try XCTUnwrap(buttons.firstIndex { $0.title == "Release" })
        XCTAssertEqual(buttons[release + 1].title, "Activity")
        XCTAssertFalse(buttons[release + 1].isEnabled, "An unauthenticated target has no activity access")
        let minimumContent = window.contentRect(forFrameRect: NSRect(origin: .zero, size: window.minSize))
        XCTAssertLessThanOrEqual(controls.fittingSize.width, minimumContent.width - 32)
        withExtendedLifetime(controller) {}
    }
}
