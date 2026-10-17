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

    private func setBracketedPaste(_ enabled: Bool, renderer: RemoteTerminalRenderer) async {
        let consumed = expectation(description: "Terminal paste mode restored")
        renderer.onAction = { action in if case .consumed = action { consumed.fulfill() } }
        let mode = enabled ? "\u{1b}[?2004h" : "\u{1b}[?2004l"
        renderer.render(RemoteTerminalFrame(stream: RemoteTerminalStream(terminalId: "claude", generation: "test", streamId: "stream"),
            offset: 0, bytes: Data(mode.utf8).base64EncodedString(), reset: true, complete: true, rows: 10, cols: 60), token: "mode")
        await fulfillment(of: [consumed], timeout: 10)
    }

    func testCommandVPastesOnceAndCancelsWebKitDefaultWithoutDebouncingSeparatePastes() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        var pastes: [String] = []
        renderer.onAction = { action in
            if case .paste(let epoch) = action { pastes.append(epoch) }
            if case .input = action { XCTFail("Command-V must request a guarded paste, never raw input") }
        }
        renderer.setControl(true, epoch: "paste-lease")
        let shortcut = """
        (() => {
          const target = document.querySelector('.xterm-helper-textarea');
          target.focus();
          const event = new KeyboardEvent('keydown', {
            key: 'v', code: 'KeyV', keyCode: 86, which: 86,
            metaKey: true, bubbles: true, cancelable: true
          });
          return { allowed: target.dispatchEvent(event), cancelled: event.defaultPrevented };
        })()
        """
        for _ in 0..<2 {
            let value = try await evaluate(renderer, shortcut)
            let result = try XCTUnwrap(value as? [String: Bool])
            XCTAssertEqual(result["allowed"], false, "The same keystroke must not also invoke WebKit's paste default")
            XCTAssertEqual(result["cancelled"], true)
        }
        _ = try await evaluate(renderer, "window.astationTerminal.inspect()")
        XCTAssertEqual(pastes, ["paste-lease", "paste-lease"])
        renderer.setControl(false, epoch: "")
        _ = try await evaluate(renderer, shortcut)
        _ = try await evaluate(renderer, "window.astationTerminal.inspect()")
        XCTAssertEqual(pastes.count, 2, "Viewing cannot request paste")
    }

    func testPasteAndGoAppendsEnterToOneWriteAndOrdinaryPasteRemainsUnsubmitted() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        await setBracketedPaste(true, renderer: renderer)
        var received: [Data] = []
        let bracketed = expectation(description: "Paste-and-go and ordinary paste")
        bracketed.expectedFulfillmentCount = 2
        renderer.onAction = { action in
            if case .input(let bytes, let epoch) = action {
                XCTAssertEqual(epoch, "go-lease")
                received.append(bytes)
                bracketed.fulfill()
            }
        }
        renderer.setControl(true, epoch: "go-lease")
        renderer.paste("first\nsecond", epoch: "go-lease", submit: true)
        renderer.paste("draft", epoch: "go-lease")
        await fulfillment(of: [bracketed], timeout: 10)
        XCTAssertEqual(received, [Data("\u{1b}[200~first\rsecond\u{1b}[201~\r".utf8), Data("\u{1b}[200~draft\u{1b}[201~".utf8)])
        await setBracketedPaste(false, renderer: renderer)
        let plain = expectation(description: "Plain terminal receives text and Enter once")
        renderer.onAction = { action in
            if case .input(let bytes, _) = action { received.append(bytes); plain.fulfill() }
        }
        renderer.setControl(true, epoch: "go-lease")
        renderer.paste("plain", epoch: "go-lease", submit: true)
        await fulfillment(of: [plain], timeout: 10)
        XCTAssertEqual(received.last, Data("plain\r".utf8))
        XCTAssertEqual(received.count, 3)
    }

    func testPasteAndGoRejectsEmptyOversizedStaleAndDisabledInputWithoutSendingEnter() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        await setBracketedPaste(true, renderer: renderer)
        var received: [Data] = []
        var oversized = 0
        renderer.onAction = { action in
            if case .input(let bytes, _) = action { received.append(bytes) }
            if case .oversizedPaste = action { oversized += 1 }
        }
        renderer.setControl(true, epoch: "current-lease")
        renderer.paste("stale", epoch: "old-lease", submit: true)
        renderer.paste("", epoch: "current-lease", submit: true)
        renderer.paste(String(repeating: "a", count: 16 * 1024 - 12), epoch: "current-lease", submit: true)
        _ = try await evaluate(renderer, "window.astationTerminal.inspect()")
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(oversized, 1)
        renderer.paste(String(repeating: "a", count: 16 * 1024 - 13), epoch: "current-lease", submit: true)
        _ = try await evaluate(renderer, "window.astationTerminal.inspect()")
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.count, 16 * 1024)
        renderer.setControl(false, epoch: "")
        renderer.paste("disabled", epoch: "current-lease", submit: true)
        _ = try await evaluate(renderer, "window.astationTerminal.inspect()")
        XCTAssertEqual(received.count, 1)
    }

    func testPasteAndGoDoesNotAppendEnterToTerminalFocusReports() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        let consumed = expectation(description: "Bracketed paste and focus reporting enabled")
        renderer.onAction = { action in if case .consumed = action { consumed.fulfill() } }
        renderer.render(RemoteTerminalFrame(stream: RemoteTerminalStream(terminalId: "claude", generation: "test", streamId: "stream"),
            offset: 0, bytes: Data("\u{1b}[?2004h\u{1b}[?1004h".utf8).base64EncodedString(),
            reset: true, complete: true, rows: 10, cols: 60), token: "focus-mode")
        await fulfillment(of: [consumed], timeout: 10)
        renderer.setControl(true, epoch: "focus-lease")
        _ = try await evaluate(renderer, "document.body.appendChild(document.createElement('input')).focus()")
        var received: [Data] = []
        let pasted = expectation(description: "Paste and focus report have separate semantics")
        renderer.onAction = { action in
            if case .input(let bytes, _) = action {
                received.append(bytes)
                if bytes == Data("\u{1b}[200~go\u{1b}[201~\r".utf8) { pasted.fulfill() }
            }
        }
        renderer.paste("go", epoch: "focus-lease", submit: true)
        await fulfillment(of: [pasted], timeout: 10)
        XCTAssertTrue(received.contains(Data("\u{1b}[I".utf8)))
        XCTAssertEqual(received.filter { $0.last == 13 }, [Data("\u{1b}[200~go\u{1b}[201~\r".utf8)])
    }

    func testNativeContextMenuOffersClipboardActionsAndFencesPasteWhileViewing() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = NSMenu()
        renderer.webView.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Paste", "Select All"])
        XCTAssertFalse(menu.items[1].isEnabled)
        var pastes: [String] = []
        let requested = expectation(description: "One context-menu paste request")
        renderer.onAction = { action in
            if case .paste(let epoch) = action { pastes.append(epoch); requested.fulfill() }
        }
        renderer.setControl(true, epoch: "menu-lease")
        renderer.webView.willOpenMenu(menu, with: event)
        XCTAssertTrue(menu.items[1].isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(menu.items[1].action), to: menu.items[1].target, from: menu.items[1]))
        await fulfillment(of: [requested], timeout: 10)
        XCTAssertEqual(pastes, ["menu-lease"])
        renderer.setControl(false, epoch: "")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(menu.items[1].action), to: menu.items[1].target, from: menu.items[1]))
        _ = try await evaluate(renderer, "window.astationTerminal.inspect()")
        XCTAssertEqual(pastes.count, 1, "An already-open menu cannot outlive control")
    }

    func testNativeEditPasteRequestsOneGuardedPasteWhileTerminalHasFocus() async throws {
        let renderer = RemoteTerminalRenderer()
        let window = host(renderer)
        defer { window.close() }
        await load(renderer)
        let clipboard = NSPasteboard.general
        let savedItems = clipboard.pasteboardItems?.map { original -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { item.setData(data, forType: type) }
            }
            return item
        } ?? []
        defer { clipboard.clearContents(); clipboard.writeObjects(savedItems) }
        clipboard.clearContents()
        clipboard.setString("edit-menu-paste", forType: .string)
        renderer.setControl(true, epoch: "edit-lease")
        _ = try await evaluate(renderer, "document.querySelector('.xterm-helper-textarea').focus()")
        let requested = expectation(description: "Native Edit Paste reaches the guarded bridge")
        requested.assertForOverFulfill = true
        renderer.onAction = { action in
            if case .paste(let epoch) = action { XCTAssertEqual(epoch, "edit-lease"); requested.fulfill() }
            if case .input = action { XCTFail("Native paste must not bypass the clipboard bridge") }
        }
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.paste(_:)), to: renderer.webView, from: nil))
        await fulfillment(of: [requested], timeout: 10)
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
