import Cocoa
import XCTest
@testable import Menubar

@MainActor
final class TokenToolsUITests: XCTestCase {
    private let app = "0123456789abcdef0123456789abcdef"
    private let certificate = "abcdef0123456789abcdef0123456789"

    private func project(_ id: String = "demo") -> AgoraProject {
        AgoraProject(id: id, name: "Voice Lab", vendorKey: app, signKey: certificate, status: "active", created: 0)
    }

    private func find<T: NSView>(_ root: NSView, _ type: T.Type, _ predicate: (T) -> Bool) throws -> T {
        func search(_ view: NSView) -> T? {
            if let match = view as? T, predicate(match) { return match }
            for child in view.subviews {
                if let match = search(child) { return match }
            }
            return nil
        }
        return try XCTUnwrap(search(root))
    }

    private func host(_ controller: TokenToolsViewController) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 740),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 680, height: 740))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func generate(_ controller: TokenToolsViewController) throws -> NSTextView {
        let channel = try find(controller.view, NSTextField.self) { $0.placeholderString == "Channel name" }
        channel.stringValue = "test-channel"
        let button = try find(controller.view, NSButton.self) { $0.title == "Generate Token" }
        button.performClick(nil)
        return try find(controller.view, NSTextView.self) { $0.accessibilityLabel() == "Generated token" }
    }

    func testGenerationAndProjectChangeNeverLeaveAStaleCopy() throws {
        let controller = TokenToolsViewController(projects: { [self.project(), self.project("second")] }, initialProjectID: "demo")
        let window = host(controller); defer { window.close() }
        let output = try generate(controller)
        XCTAssertEqual(try AgoraTokenService.decode(output.string).services.first?.details.channel, "test-channel")
        let copy = try find(controller.view, NSButton.self) { $0.title == "Copy Token" }
        XCTAssertTrue(copy.isEnabled)
        let picker = try find(controller.view, NSPopUpButton.self) { $0.accessibilityLabel() == "Token project" }
        picker.selectItem(at: 1)
        NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker)
        XCTAssertFalse(copy.isEnabled)
        XCTAssertTrue(output.string.isEmpty)
    }

    func testRevokedProjectCannotGenerateFromCachedCredentials() throws {
        var projects = [project()]
        let controller = TokenToolsViewController(projects: { projects }, initialProjectID: "demo")
        let window = host(controller); defer { window.close() }
        _ = try generate(controller)
        projects = []
        let output = try generate(controller)
        XCTAssertTrue(output.string.isEmpty)
        XCTAssertFalse(try find(controller.view, NSButton.self) { $0.title == "Copy Token" }.isEnabled)
    }

    func testInspectionRequiresExplicitVerificationAndInvalidatesOnEdit() throws {
        let controller = TokenToolsViewController(projects: { [self.project()] }, initialProjectID: "demo")
        let window = host(controller); defer { window.close() }
        _ = try generate(controller)
        try find(controller.view, NSButton.self) { $0.title == "Inspect" }.performClick(nil)
        let status = try find(controller.view, NSTextField.self) { $0.accessibilityLabel() == "Token verification status" }
        XCTAssertTrue(status.stringValue.contains("Signature not verified"))
        let verify = try find(controller.view, NSButton.self) { $0.title == "Verify with Project" }
        verify.performClick(nil)
        XCTAssertTrue(status.stringValue.contains("Signature verified for this project"))
        let input = try find(controller.view, NSTextView.self) { $0.accessibilityLabel() == "Token to inspect" }
        input.string = "007invalid"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
        XCTAssertFalse(verify.isEnabled)
        XCTAssertFalse(status.stringValue.contains("Signature verified"))
    }

    func testCustomRTMGenerationWorksWithoutSignedInProjects() throws {
        let controller = TokenToolsViewController(projects: { [] }, initialProjectID: nil)
        let window = host(controller); defer { window.close() }
        try find(controller.view, NSTextField.self) { $0.placeholderString == "32-character App ID" }.stringValue = app
        try find(controller.view, NSSecureTextField.self) { $0.accessibilityLabel() == "Custom App Certificate" }.stringValue = certificate
        let kind = try find(controller.view, NSSegmentedControl.self) { $0.accessibilityLabel() == "Token service" }
        kind.selectedSegment = 1
        NSApp.sendAction(try XCTUnwrap(kind.action), to: kind.target, from: kind)
        let output = try generate(controller)
        let decoded = try AgoraTokenService.decode(output.string)
        XCTAssertEqual(decoded.services.first?.service_type, 2)
        controller.clearSensitiveContent()
        XCTAssertTrue(output.string.isEmpty)
        XCTAssertTrue(try find(controller.view, NSSecureTextField.self) { $0.accessibilityLabel() == "Custom App Certificate" }.stringValue.isEmpty)
    }

    func testTokenTextHasReadableWidthAndOptionalSnapshots() throws {
        let controller = TokenToolsViewController(projects: { [self.project()] }, initialProjectID: "demo")
        let window = host(controller); defer { window.close() }
        _ = try generate(controller)
        controller.view.layoutSubtreeIfNeeded()
        let output = try find(controller.view, NSTextView.self) { $0.accessibilityLabel() == "Generated token" }
        XCTAssertGreaterThan(output.frame.width, 300)
        let body = try find(controller.view, NSScrollView.self) { !$0.drawsBackground }
        XCTAssertGreaterThan(body.frame.height, 400)
        guard ProcessInfo.processInfo.environment["ASTATION_TOKEN_SNAPSHOTS"] == "1" else { return }
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        for name in ["generate", "inspect"] {
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if CGPreflightScreenCaptureAccess() {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), ".build/token-tools-\(name).png"]
                try capture.run(); capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0)
            }
            try find(controller.view, NSButton.self) { $0.title == "Inspect" }.performClick(nil)
        }
    }
}
