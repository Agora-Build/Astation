import AppKit
import WebKit
import XCTest
@testable import Menubar

@MainActor
final class RemoteTerminalRendererTests: XCTestCase {
    private func host(_ renderer: RemoteTerminalRenderer) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func load(_ renderer: RemoteTerminalRenderer) async {
        let ready = expectation(description: "Bundled xterm and Unicode provider loaded")
        renderer.onFailure = { XCTFail("Native terminal renderer failed to load") }
        renderer.onAction = { action in if case .ready = action { ready.fulfill() } }
        renderer.load()
        await fulfillment(of: [ready], timeout: 15)
    }

    private func evaluate(_ renderer: RemoteTerminalRenderer, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            renderer.webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    func testActualWebKitRendersByteSplitUnicodeAndCanonicalColors() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        let consumed = expectation(description: "Both frame writes consumed")
        consumed.expectedFulfillmentCount = 2
        renderer.onAction = { action in if case .consumed = action { consumed.fulfill() } }
        let prefix = Data([0x1b, 0x5b, 0x33, 0x31, 0x6d]) + Data("RED ".utf8) + Data([0xf0, 0x9f])
        let suffix = Data([0x8c, 0x9f]) + Data("\u{1b}[0m\r\nsecond row".utf8)
        let stream = RemoteTerminalStream(terminalId: "claude", generation: "test", streamId: "stream")
        renderer.render(RemoteTerminalFrame(stream: stream, offset: 0, bytes: prefix.base64EncodedString(),
            reset: true, complete: false, rows: 10, cols: 60), token: "first")
        renderer.render(RemoteTerminalFrame(stream: stream, offset: UInt64(prefix.count), bytes: suffix.base64EncodedString(),
            reset: false, complete: true, rows: 10, cols: 60), token: "second")
        await fulfillment(of: [consumed], timeout: 10)
        let result = try await evaluate(renderer, "window.astationTerminal.inspect()")
        let state = try XCTUnwrap(result as? [String: Any])
        XCTAssertTrue((state["text"] as? String ?? "").contains("RED \u{1f31f}"))
        XCTAssertTrue((state["text"] as? String ?? "").contains("second row"))
        XCTAssertEqual(state["unicode"] as? String, "atem-unicode-width-0.1.14")
        XCTAssertEqual(state["scrollback"] as? Int, 0)
        XCTAssertEqual(state["cols"] as? Int, 60)
        XCTAssertEqual(state["enabled"] as? Bool, false)
        XCTAssertEqual(state["firstForeground"] as? Int, 1)
    }

    func testPastePreservesBracketedModeAndRejectsOldOwnershipEpoch() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        let restore = expectation(description: "Bracketed paste mode restored")
        renderer.onAction = { action in if case .consumed = action { restore.fulfill() } }
        renderer.render(RemoteTerminalFrame(stream: RemoteTerminalStream(terminalId: "claude", generation: "test", streamId: "stream"),
            offset: 0, bytes: Data("\u{1b}[?2004h".utf8).base64EncodedString(), reset: true, complete: true, rows: 10, cols: 60), token: "restore")
        await fulfillment(of: [restore], timeout: 10)
        let input = expectation(description: "One atomic bracketed paste")
        var received: [Data] = []
        renderer.onAction = { action in
            if case .input(let bytes, let epoch) = action {
                received.append(bytes)
                XCTAssertEqual(epoch, "lease-2")
                input.fulfill()
            }
        }
        renderer.setControl(true, epoch: "lease-2")
        renderer.paste("must not be sent", epoch: "lease-1")
        renderer.paste("first\nsecond", epoch: "lease-2")
        await fulfillment(of: [input], timeout: 10)
        XCTAssertEqual(received, [Data("\u{1b}[200~first\rsecond\u{1b}[201~".utf8)])
        renderer.setControl(false, epoch: "")
        renderer.paste("disabled", epoch: "lease-2")
        _ = try await evaluate(renderer, "window.astationTerminal.inspect()")
        XCTAssertEqual(received.count, 1)
    }

    func testNewStreamDiscardsOldScreenAndResetsControl() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        let written = expectation(description: "New stream restored")
        renderer.onAction = { action in if case .consumed(let token) = action, token == "new" { written.fulfill() } }
        let oldStream = RemoteTerminalStream(terminalId: "claude", generation: "old", streamId: "old-stream")
        let newStream = RemoteTerminalStream(terminalId: "codex", generation: "new", streamId: "new-stream")
        renderer.render(RemoteTerminalFrame(stream: oldStream, offset: 0, bytes: Data("OLD SCREEN".utf8).base64EncodedString(),
            reset: true, complete: true, rows: 10, cols: 60), token: "old")
        renderer.setControl(true, epoch: "old-lease")
        renderer.render(RemoteTerminalFrame(stream: newStream, offset: 0, bytes: Data("NEW SCREEN".utf8).base64EncodedString(),
            reset: true, complete: true, rows: 10, cols: 60), token: "new")
        await fulfillment(of: [written], timeout: 10)
        let result = try await evaluate(renderer, "window.astationTerminal.inspect()")
        let state = try XCTUnwrap(result as? [String: Any])
        XCTAssertTrue((state["text"] as? String ?? "").contains("NEW SCREEN"))
        XCTAssertFalse((state["text"] as? String ?? "").contains("OLD SCREEN"))
        XCTAssertEqual(state["enabled"] as? Bool, false)
    }

    func testTmuxCopyModeShortcutForwardsControlBThenBracketOnlyWhileControlling() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        let shortcut = """
        (() => {
          const target = document.querySelector('.xterm-helper-textarea');
          target.focus();
          const key = (type, value, code, keyCode, ctrlKey = false, charCode = 0) =>
            target.dispatchEvent(new KeyboardEvent(type, {
              key: value, code, keyCode, which: charCode || keyCode, charCode,
              ctrlKey, bubbles: true, cancelable: true
            }));
          key('keydown', 'Control', 'ControlLeft', 17, true);
          key('keydown', 'b', 'KeyB', 66, true);
          key('keyup', 'b', 'KeyB', 66, true);
          key('keyup', 'Control', 'ControlLeft', 17);
          key('keydown', '[', 'BracketLeft', 219);
          key('keypress', '[', 'BracketLeft', 91, false, 91);
          key('keyup', '[', 'BracketLeft', 219);
        })()
        """
        var received: [Data] = []
        let input = expectation(description: "Control-B followed by a literal bracket")
        input.expectedFulfillmentCount = 2
        renderer.onAction = { action in
            if case .input(let bytes, let epoch) = action {
                received.append(bytes)
                XCTAssertEqual(epoch, "tmux-lease")
                input.fulfill()
            }
        }
        _ = try await evaluate(renderer, shortcut)
        XCTAssertTrue(received.isEmpty)
        renderer.setControl(true, epoch: "tmux-lease")
        _ = try await evaluate(renderer, shortcut)
        await fulfillment(of: [input], timeout: 10)
        XCTAssertEqual(received, [Data([0x02]), Data("[".utf8)])
        renderer.setControl(false, epoch: "")
        _ = try await evaluate(renderer, shortcut)
        XCTAssertEqual(received, [Data([0x02]), Data("[".utf8)])
    }
}
