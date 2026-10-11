import AppKit
import Security
import XCTest
@testable import Menubar

private final class CredentialTestStorage: LocalCredentialStorage {
    var data: Data?
    var failRead = false
    var failWrite = false
    var writes = 0

    func read() throws -> Data? {
        if failRead { throw LocalCredentialError.keychain(errSecInteractionNotAllowed) }
        return data
    }

    func write(_ data: Data, creating: Bool) throws {
        if failWrite { throw LocalCredentialError.keychain(errSecNotAvailable) }
        if creating && self.data != nil { throw LocalCredentialError.keychain(errSecDuplicateItem) }
        if !creating && self.data == nil { throw LocalCredentialError.keychain(errSecItemNotFound) }
        self.data = data
        writes += 1
    }
}

final class LocalCredentialTests: XCTestCase {
    func testCreateReloadUpdateAndDeletePreserveOpaqueValuesAndVersions() throws {
        let storage = CredentialTestStorage(), first = LocalCredentialStore(account: "test", storage: storage)
        let value = "  synthetic-value\nline two\n"
        try first.save(name: "Example_Key", project: nil, value: value, expectedRevision: nil)
        let reloaded = LocalCredentialStore(account: "test", storage: storage)
        let snapshot = try reloaded.snapshot(), entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(entry.name, "Example_Key")
        XCTAssertEqual(entry.version, 1)
        XCTAssertEqual(try reloaded.value(id: entry.id, expectedRevision: snapshot.revision), value)
        try reloaded.save(name: entry.name, project: nil, value: "replacement", updating: entry.id, expectedRevision: snapshot.revision)
        let updated = try first.snapshot()
        XCTAssertEqual(updated.entries.first?.version, 2)
        XCTAssertEqual(try first.value(id: entry.id, expectedRevision: updated.revision), "replacement")
        try first.delete(id: entry.id, expectedRevision: updated.revision)
        let empty = try reloaded.snapshot()
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertNotNil(empty.revision)
        XCTAssertThrowsError(try first.save(name: "new", project: nil, value: "value", expectedRevision: nil))
    }

    func testScopesIsolateCaseInsensitiveNamesAndNormalizeGitRemotes() throws {
        let store = LocalCredentialStore(account: "test", storage: CredentialTestStorage())
        try store.save(name: "Key", project: nil, value: "global", expectedRevision: nil)
        var snapshot = try store.snapshot()
        XCTAssertThrowsError(try store.save(name: "KEY", project: nil, value: "duplicate", expectedRevision: snapshot.revision))
        try store.save(name: "KEY", project: "git@github.com:Owner/Repo.git", value: "project", expectedRevision: snapshot.revision)
        snapshot = try store.snapshot()
        XCTAssertThrowsError(try store.save(name: "key", project: "https://github.com/owner/repo", value: "duplicate", expectedRevision: snapshot.revision))
        try store.save(name: "Key", project: "github.com/owner/other", value: "other", expectedRevision: snapshot.revision)
        XCTAssertEqual(try store.snapshot().entries.count, 3)
        XCTAssertEqual(try LocalCredentialStore.project("ssh://git@github.com/Owner/Repo.git"), "github.com/owner/repo")
        XCTAssertEqual(try LocalCredentialStore.project("https://user:password@example.com/owner/repo.git"), "example.com/owner/repo")
    }

    func testInputBoundsUseUTF8AndRejectAmbiguousScopesAndNames() throws {
        XCTAssertEqual(try LocalCredentialStore.name(" KEY "), "KEY")
        for name in ["", "  ", "key\nvalue", "name\u{202E}", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try LocalCredentialStore.name(name))
        }
        for project in ["dialf", "github.com/owner/../repo", "github.com//repo", "host/repo", "https://github.com", "file:///tmp/repo", "github.com/a/b?token=example"] {
            XCTAssertThrowsError(try LocalCredentialStore.project(project))
        }
        XCTAssertNil(try LocalCredentialStore.project(nil))
        XCTAssertThrowsError(try LocalCredentialStore.validateValue(""))
        try LocalCredentialStore.validateValue(String(repeating: "x", count: 65_536))
        XCTAssertThrowsError(try LocalCredentialStore.validateValue(String(repeating: "x", count: 65_537)))
        XCTAssertThrowsError(try LocalCredentialStore.validateValue(String(repeating: "\u{1F600}", count: 16_385)))
    }

    func testStaleRevisionCannotReadUpdateOrDeleteAReplacedValue() throws {
        let store = LocalCredentialStore(account: "test", storage: CredentialTestStorage())
        try store.save(name: "Key", project: nil, value: "one", expectedRevision: nil)
        let old = try store.snapshot(), entry = try XCTUnwrap(old.entries.first)
        try store.save(name: "Key", project: nil, value: "two", updating: entry.id, expectedRevision: old.revision)
        XCTAssertThrowsError(try store.value(id: entry.id, expectedRevision: old.revision))
        XCTAssertThrowsError(try store.save(name: "Key", project: nil, value: "three", updating: entry.id, expectedRevision: old.revision))
        XCTAssertThrowsError(try store.delete(id: entry.id, expectedRevision: old.revision))
        XCTAssertEqual(try store.value(id: entry.id, expectedRevision: store.snapshot().revision), "two")
    }

    func testFailedReadsAndWritesRetainExistingRecords() throws {
        let storage = CredentialTestStorage(), store = LocalCredentialStore(account: "test", storage: storage)
        storage.failWrite = true
        XCTAssertThrowsError(try store.save(name: "Key", project: nil, value: "one", expectedRevision: nil))
        XCTAssertNil(storage.data)
        storage.failWrite = false
        try store.save(name: "Key", project: nil, value: "one", expectedRevision: nil)
        let before = storage.data, snapshot = try store.snapshot(), id = try XCTUnwrap(snapshot.entries.first?.id)
        storage.failWrite = true
        XCTAssertThrowsError(try store.save(name: "Key", project: nil, value: "two", updating: id, expectedRevision: snapshot.revision))
        XCTAssertThrowsError(try store.delete(id: id, expectedRevision: snapshot.revision))
        XCTAssertEqual(storage.data, before)
        storage.failRead = true
        XCTAssertThrowsError(try store.snapshot())
        XCTAssertThrowsError(try store.save(name: "new", project: nil, value: "new", expectedRevision: nil))
        XCTAssertEqual(storage.data, before)
        XCTAssertEqual(storage.writes, 1)
    }

    func testCorruptAndNewerStoresAreNeverReset() throws {
        let storage = CredentialTestStorage(), store = LocalCredentialStore(account: "test", storage: storage)
        for raw in ["broken", "{}", "{\"format\":2}", "{\"format\":0}"] {
            storage.data = Data(raw.utf8)
            let before = storage.data
            XCTAssertThrowsError(try store.snapshot())
            XCTAssertThrowsError(try store.save(name: "new", project: nil, value: "new", expectedRevision: nil))
            XCTAssertEqual(storage.data, before)
        }
        XCTAssertEqual(storage.writes, 0)
    }

    func testMetadataSnapshotDoesNotSerializeValues() throws {
        let store = LocalCredentialStore(account: "test", storage: CredentialTestStorage())
        try store.save(name: "Name", project: nil, value: "synthetic-private-value", expectedRevision: nil)
        let metadata = try JSONEncoder().encode(store.snapshot().entries)
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("synthetic-private-value"))
    }

    func testDeniedAndCancelledAuthenticationNeverRunsAnOperation() {
        var callback: ((Bool) -> Void)?, operations = 0, results = 0, cancellations = 0
        let actions = LocalCredentialActions(account: { "a" }, authenticate: { _, response in
            callback = response
            return { cancellations += 1 }
        })
        actions.perform(account: "a", reason: "test", operation: { operations += 1 }) { _ in results += 1 }
        callback?(false)
        XCTAssertEqual(operations, 0)
        XCTAssertFalse(actions.isBusy)
        actions.perform(account: "a", reason: "test", operation: { operations += 1 }) { _ in results += 1 }
        actions.cancel()
        callback?(true)
        XCTAssertEqual(operations, 0)
        XCTAssertEqual(results, 2)
        XCTAssertEqual(cancellations, 1)
    }

    func testAccountChangeAndDuplicateAuthenticationCallbacksCannotAuthorize() {
        var account = "a", callback: ((Bool) -> Void)?, operations = 0
        let actions = LocalCredentialActions(account: { account }, authenticate: { _, response in callback = response; return {} })
        actions.perform(account: "a", reason: "test", operation: { operations += 1 }) { _ in }
        account = "b"
        callback?(true)
        XCTAssertEqual(operations, 0)
        account = "a"
        actions.perform(account: "a", reason: "test", operation: { operations += 1 }) { _ in }
        callback?(true)
        callback?(true)
        XCTAssertEqual(operations, 1)
    }

    func testConcurrentActionIsRejectedAndSynchronousApprovalIsSafe() {
        var callback: ((Bool) -> Void)?, operations = 0, failures = 0
        let actions = LocalCredentialActions(account: { "a" }, authenticate: { _, response in callback = response; return {} })
        actions.perform(account: "a", reason: "first", operation: { operations += 1 }) { _ in }
        actions.perform(account: "a", reason: "second", operation: { operations += 1 }) { result in
            if case .failure = result { failures += 1 }
        }
        callback?(true)
        XCTAssertEqual(operations, 1)
        XCTAssertEqual(failures, 1)
        let synchronous = LocalCredentialActions(account: { "a" }, authenticate: { _, response in response(true); return { response(false) } })
        synchronous.perform(account: "a", reason: "test", operation: { operations += 1 }) { _ in }
        XCTAssertEqual(operations, 2)
        XCTAssertFalse(synchronous.isBusy)
    }

    func testStoreChangedDuringApprovalCannotOverwriteIt() throws {
        let store = LocalCredentialStore(account: "a", storage: CredentialTestStorage())
        var callback: ((Bool) -> Void)?, failed = false
        let actions = LocalCredentialActions(account: { "a" }, authenticate: { _, response in callback = response; return {} })
        actions.perform(account: "a", reason: "test", operation: {
            try store.save(name: "Key", project: nil, value: "stale", expectedRevision: nil)
        }) { result in if case .failure = result { failed = true } }
        try store.save(name: "Key", project: nil, value: "current", expectedRevision: nil)
        callback?(true)
        let snapshot = try store.snapshot(), id = try XCTUnwrap(snapshot.entries.first?.id)
        XCTAssertTrue(failed)
        XCTAssertEqual(try store.value(id: id, expectedRevision: snapshot.revision), "current")
    }

    func testClipboardExpiryClearsOnlyOurCopyAndNotSubsequentContent() {
        let board = NSPasteboard(name: NSPasteboard.Name("credential-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let clipboard = CredentialClipboard(pasteboard: board)
        var expiry: (() -> Void)?
        clipboard.copy("synthetic", schedule: { delay, operation in XCTAssertEqual(delay, 30); expiry = operation })
        XCTAssertEqual(board.string(forType: .string), "synthetic")
        expiry?()
        XCTAssertNil(board.string(forType: .string))
        clipboard.copy("synthetic", schedule: { _, operation in expiry = operation })
        board.clearContents(); board.setString("new content", forType: .string)
        expiry?()
        XCTAssertEqual(board.string(forType: .string), "new content")
    }

    func testMaskedAndMultilineEditorsPreserveValueAndClearOnClose() throws {
        let input = CredentialValueInput(), value = "  first\nsecond\n"
        input.value = value
        XCTAssertEqual(input.value, value)
        XCTAssertTrue(input.textView.string.isEmpty)
        input.showButton.state = .on
        input.toggleVisibility()
        XCTAssertEqual(input.value, value)
        XCTAssertTrue(input.secureField.stringValue.isEmpty)
        input.showButton.state = .off
        input.toggleVisibility()
        XCTAssertEqual(input.value, value)
        input.clear()
        XCTAssertTrue(input.value.isEmpty)
        XCTAssertTrue(input.textView.string.isEmpty)
    }

    func testEditorRequiresProjectWhenSelectedAndStartsUpdateWithBlankValue() throws {
        let snapshot = LocalCredentialSnapshot(revision: UUID(), entries: [])
        let form = CredentialEditor(entry: nil, snapshot: snapshot)
        form.nameField.stringValue = "Key"
        form.input.value = "value"
        XCTAssertNil(try form.validatedInput().project)
        form.projectButton.state = .on
        XCTAssertThrowsError(try form.validatedInput())
        form.projectField.stringValue = "git@github.com:Owner/Repo.git"
        XCTAssertEqual(try form.validatedInput().project, "github.com/owner/repo")
        let existing = LocalCredentialMetadata(id: UUID(), name: "Key", project: "github.com/owner/repo", version: 2, updatedAt: Date())
        let update = CredentialEditor(entry: existing, snapshot: snapshot)
        XCTAssertFalse(update.nameField.isEnabled)
        XCTAssertFalse(update.projectField.isEnabled)
        XCTAssertTrue(update.input.value.isEmpty)
        form.clear()
        XCTAssertTrue(form.input.value.isEmpty)
    }

    func testRealProtectedKeychainRoundTripAccessibilityAndAccountIsolation() throws {
        let account = "credentials-test-\(UUID())", other = "credentials-test-\(UUID())"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: LocalCredentialKeychainStorage.service,
            kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
        defer { SecItemDelete(query as CFDictionary) }
        let store = LocalCredentialStore(account: account)
        do { try store.save(name: "Synthetic", project: nil, value: "synthetic-value", expectedRevision: nil) }
        catch {
            if case LocalCredentialError.keychain(errSecMissingEntitlement) = error,
               ProcessInfo.processInfo.environment["ASTATION_REQUIRE_KEYCHAIN_TESTS"] != "1" {
                throw XCTSkip("Requires a provisioned XCTest host for Data Protection Keychain")
            }
            throw error
        }
        let restored = LocalCredentialStore(account: account), snapshot = try restored.snapshot()
        let id = try XCTUnwrap(snapshot.entries.first?.id)
        XCTAssertEqual(try restored.value(id: id, expectedRevision: snapshot.revision), "synthetic-value")
        XCTAssertTrue(try LocalCredentialStore(account: other).snapshot().entries.isEmpty)
        var attrsQuery = query
        attrsQuery[kSecReturnAttributes as String] = true
        var attrs: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attrsQuery as CFDictionary, &attrs), errSecSuccess)
        XCTAssertEqual((attrs as? [String: Any])?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try restored.delete(id: id, expectedRevision: snapshot.revision)
        XCTAssertTrue(try LocalCredentialStore(account: account).snapshot().entries.isEmpty)
    }

    func testCredentialsViewLoadsMetadataAndDisablesWritesOnStorageFailure() throws {
        let storage = CredentialTestStorage(), store = LocalCredentialStore(account: "test", storage: storage)
        try store.save(name: "EXAMPLE_KEY", project: nil, value: "synthetic-private-value", expectedRevision: nil)
        let controller = CredentialsViewController(account: { "test" }, makeStore: { _ in store }, authenticate: { _, reply in reply(false); return {} })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 560)
        controller.view.layoutSubtreeIfNeeded()
        let children = descendants(controller.view)
        let add = try XCTUnwrap(children.compactMap { $0 as? NSButton }.first { $0.title == "Add Credential" })
        XCTAssertTrue(add.isEnabled)
        XCTAssertEqual(controller.numberOfRows(in: NSTableView()), 1)
        XCTAssertFalse(children.compactMap { ($0 as? NSTextField)?.stringValue }.contains("synthetic-private-value"))
        storage.failRead = true
        controller.viewWillAppear()
        XCTAssertFalse(add.isEnabled)
        XCTAssertEqual(controller.numberOfRows(in: NSTableView()), 0)
    }

    func testEditorLayoutFitsMaskedAndMultilineInput() throws {
        let form = CredentialEditor(entry: nil, snapshot: LocalCredentialSnapshot(revision: nil, entries: []))
        let content = try XCTUnwrap(form.panel.contentView)
        for visible in [false, true] {
            form.input.showButton.state = visible ? .on : .off
            form.input.toggleVisibility()
            content.layoutSubtreeIfNeeded()
            let name = form.nameField.convert(form.nameField.bounds, to: content)
            let input = form.input.convert(form.input.bounds, to: content)
            let save = form.saveButton.convert(form.saveButton.bounds, to: content)
            for frame in [name, input, save] {
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width)
                XCTAssertLessThanOrEqual(frame.maxY, content.bounds.height)
            }
        }
    }

    func testDeleteConfirmationRequiresActiveControllerAndCancelsLateApproval() throws {
        for cancelled in [false, true] {
            let storage = CredentialTestStorage(), store = LocalCredentialStore(account: "test", storage: storage)
            try store.save(name: "EXAMPLE_KEY", project: nil, value: "synthetic-value", expectedRevision: nil)
            var approvals = 0
            var confirm: ((NSApplication.ModalResponse) -> Void)?
            let controller = CredentialsViewController(account: { "test" }, makeStore: { _ in store }, authenticate: { _, reply in
                approvals += 1
                reply(true)
                return {}
            }, presentConfirmation: { _, _, reply in confirm = reply })
            let window = NSWindow(contentViewController: controller)
            defer { controller.cancelPending(); window.close() }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            let children = descendants(controller.view)
            let table = try XCTUnwrap(children.compactMap { $0 as? NSTableView }.first)
            let delete = try XCTUnwrap(children.compactMap { $0 as? NSButton }.first { $0.title == "Delete" })
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            delete.performClick(nil)
            let respond = try XCTUnwrap(confirm)
            XCTAssertFalse(delete.isEnabled)
            if cancelled { controller.cancelPending(); controller.refreshForDisplay() }
            respond(.alertFirstButtonReturn)
            respond(.alertFirstButtonReturn)
            XCTAssertEqual(approvals, cancelled ? 0 : 1)
            XCTAssertEqual(try store.snapshot().entries.count, cancelled ? 1 : 0)
        }
    }
}
