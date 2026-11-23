import AppKit
import AtemClient
import AstationRemote
import CryptoKit
import XCTest
@testable import Menubar

@MainActor
private final class NativeChannelFixture {
    let crypto = TestAtemCryptography()
    let storage = TestAtemStorage()
    let host = Curve25519.Signing.PrivateKey()
    let identity: AtemE2EIdentity
    let log: MembershipLog
    let generation = UUID()
    var writes: [Data] = []
    var confirmations = 0
    var signatures = 0
    var confirm: (() async -> Bool)?
    lazy var signer = RemoteRoutineChannelSigner(keyID: "manager-a", now: { 100 }, active: { true },
        confirm: { [unowned self] in
            confirmations += 1
            return await confirm?() ?? true
        }, sign: { [unowned self] request in
            signatures += 1
            return try identity.signChannel(request, keyID: "manager-a", expectedPublicKey: crypto.signing.publicKey.x963Representation)
        })
    lazy var router = RemoteChannelRouter(generation: generation, transport: .direct) { [unowned self] in writes.append($0) }

    static func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    static func base64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init(account: String = "account-a", manager: String = "manager-a", device: String = "host-a") throws {
        identity = AtemE2EIdentity(storage: storage, crypto: crypto)
        let keys = try identity.remotePublicKeys()
        let body: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": account, "seq": 1,
            "prev_hash": String(repeating: "0", count: 64), "action": "genesis", "signer": manager, "signed_at": 1_792_400_000_000,
            "member": ["device_id": manager, "kind": "native", "roles": ["control", "manage", "view"],
                "auth_key": ["alg": "p256", "pub": Self.base64(keys.signing)],
                "enc_key": ["alg": "x25519", "pub": Self.base64(keys.encryption)]],
            "recovery_key": ["alg": "ed25519", "pub": Self.base64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)]]
        let managerSigning = crypto.signing
        func signed(_ body: [String: Any]) throws -> String {
            let info = try signedObjectInfo(json: Self.json(["body": body, "sig": Self.base64(Data(repeating: 0, count: 64))]))
            let signature = try AtemE2ECrypto.normalizedP256Signature(managerSigning.signature(for: info.signingInput).rawRepresentation)
            return try Self.json(["body": body, "sig": Self.base64(signature)])
        }
        let genesis = try signed(body)
        let clock = HostClock(wallMs: 1_792_400_000_000, monoMs: 100, bootId: "test-boot")
        log = try MembershipLog.verify(accountId: account, genesisHash: XCTUnwrap(signedObjectInfo(json: genesis).entryHash),
            entries: [genesis], now: clock)
        let hostBody = try log.draftEntry(signer: manager, signedAt: clock.wallMs,
            actionJson: Self.json(["action": "add_host", "host": ["host_id": device, "host_trust_gen": 3,
                "host_key": ["alg": "ed25519", "pub": Self.base64(host.publicKey.rawRepresentation)]]]))
        let result = try log.extend(entries: [signed(XCTUnwrap(JSONSerialization.jsonObject(with: Data(hostBody.utf8)) as? [String: Any]))], now: clock)
        XCTAssertNil(result.stop)
    }

    func open() throws -> RemoteAgentChannel {
        try router.open(hostID: "host-a", identity: ClientIdentity(kind: .native, deviceId: "manager-a", keyId: "manager-a", grantJson: nil), log: log,
            sign: { [unowned self] request in try await signer.sign(request, isCurrent: { router.writer.isConnected }) }, observe: { _ in })
    }

    func accept(for channel: RemoteAgentChannel, tampered: Bool = false) throws -> Data {
        let initial = try XCTUnwrap(writes.first(where: { bytes in
            if case .frame(let handle, _) = try? RemoteChannelEnvelope.readHost(bytes) { return handle == channel.route.handle }
            return false
        }))
        guard case .frame(_, let frame) = try RemoteChannelEnvelope.readHost(initial) else { throw RemoteChannelError.invalidInput }
        var accept: [String: Any] = ["ch": "atem-ch1", "op": "accept",
            "e": Self.base64(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
            "n": Self.base64(Data(repeating: 3, count: 32)),
            "head": ["seq": log.head().seq, "hash": log.head().hash], "sig": Self.base64(Data(repeating: 0, count: 64))]
        let th2 = try hostAcceptTh2(initJson: String(decoding: frame, as: UTF8.self), acceptJson: Self.json(accept))
        let hash = Data(stride(from: 0, to: th2.count, by: 2).map { UInt8(th2.dropFirst($0).prefix(2), radix: 16)! })
        let signature = tampered ? Data(repeating: 0, count: 64) : try host.signature(for: signingInput(label: .channelHost, payload: hash))
        accept["sig"] = Self.base64(signature)
        return try RemoteChannelEnvelope.frame(Data(Self.json(accept).utf8), route: channel.route)
    }
}

final class AstationR9NativeChannelTests: XCTestCase {
    @MainActor
    func testMacVerifierReportUsesOnlyExistingKeysWithoutInteractionAndTheLoadedSDKInventory() throws {
        let f = try NativeChannelFixture()
        let saved = f.storage.data, writes = f.storage.writes
        let wall: UInt64 = 1_792_400_000_000
        let anchor = try RemoteVerifierReportAnchor(log: f.log)
        let challenge = try verifierReportChallenge(signer: "member:manager-a", slot: "astation-macos",
            origin: "https://station.example", connection: 1, issuedAt: wall, expiresAt: wall + 30_000)
        func report(origin: String = "https://station.example", current: Bool = true) throws -> String {
            try f.identity.verifierReport(log: f.log, anchor: anchor, memberID: "manager-a", challengeJSON: challenge,
                slot: "astation-macos", origin: origin, wallMs: wall, current: { current })
        }
        let proof = try report()
        let verified = try verifyVerifierReport(log: f.log, reportJson: proof, expectedChallengeJson: challenge, nowMs: wall)
        XCTAssertEqual(verified.inventory, verifierInventory()); XCTAssertEqual(verified.process, verifierReportProcess())
        XCTAssertTrue(verified.atHead)
        XCTAssertEqual(f.crypto.noninteractiveSigningCalls, 1); XCTAssertEqual(f.crypto.signingCalls, 0)
        XCTAssertEqual(f.storage.writes, writes); XCTAssertEqual(f.storage.data, saved); XCTAssertEqual(f.crypto.creates, 1)
        XCTAssertThrowsError(try report(origin: "https://other.example"))
        XCTAssertThrowsError(try report(current: false))
        XCTAssertEqual(f.crypto.noninteractiveSigningCalls, 1)
        f.crypto.refuseNoninteractive = true
        XCTAssertThrowsError(try report())
        XCTAssertEqual(f.crypto.signingCalls, 0)
        f.crypto.refuseNoninteractive = false
        f.crypto.afterNoninteractiveSign = { f.storage.data = nil }
        XCTAssertThrowsError(try report(), "A changed protected record cannot export the signature")
        XCTAssertEqual(f.crypto.creates, 1)
    }

    @MainActor
    func testMacReportCannotCreateOrReplaceMissingLockedOrForeignIdentity() throws {
        let f = try NativeChannelFixture(), storage = TestAtemStorage(), crypto = TestAtemCryptography()
        let identity = AtemE2EIdentity(storage: storage, crypto: crypto)
        let wall: UInt64 = 1_792_400_000_000
        let anchor = try RemoteVerifierReportAnchor(log: f.log)
        let challenge = try verifierReportChallenge(signer: "member:manager-a", slot: "astation-macos",
            origin: "https://station.example", connection: 1, issuedAt: wall, expiresAt: wall + 30_000)
        func report() throws -> String {
            try identity.verifierReport(log: f.log, anchor: anchor, memberID: "manager-a", challengeJSON: challenge,
                slot: "astation-macos", origin: "https://station.example", wallMs: wall, current: { true })
        }
        XCTAssertThrowsError(try report())
        XCTAssertEqual(crypto.creates, 0); XCTAssertEqual(storage.writes, 0)
        _ = try identity.remotePublicKeys()
        let saved = storage.data
        XCTAssertThrowsError(try report(), "Another device's key cannot report for this member")
        storage.failRead = true
        XCTAssertThrowsError(try report())
        XCTAssertEqual(storage.data, saved); XCTAssertEqual(crypto.creates, 1)
        XCTAssertEqual(crypto.noninteractiveSigningCalls, 0); XCTAssertEqual(crypto.signingCalls, 0)
    }

    @MainActor
    func testNativeConnectionInvalidatesPreviousVerifierEvidenceBeforeAccept() async throws {
        let f = try NativeChannelFixture()
        let gate = try RemoteVerifierSigningGate(log: f.log,
            verifiers: [.host("host-a"), .member("manager-a"), .stationReplica("test-replica")], now: { 100 })
        let welcome = WelcomeInfo(principal: "member:manager-a", clientKind: "native", permissions: ["view", "control"],
            revision: 9, features: [], accountId: "account-a", atemDeviceId: "host-a", hostTrustGen: 3,
            attachmentGen: "attachment", controllerSession: "controller", runtimeGen: "runtime",
            authorizationMsLeft: 1_000, serverTime: 1_792_400_000_000, head: f.log.head(),
            pendingRecovery: [], channelId: "channel", scopeJson: nil, verifier: verifierInventory(), json: "")
        for verifier in [RemoteVerifierID.host("host-a"), .member("manager-a"), .stationReplica("test-replica")] {
            let token = try gate.connect(verifier)
            if case .host = verifier { try gate.observeHostWelcome(welcome, on: token) }
            else { try gate.observeConsumer(verifierInventory(), on: token) }
        }
        let review = try RemoteHostSenderReview(stationOrigin: "https://station.example", log: f.log,
            managerID: "manager-a", hostID: "host-a", operation: .revoke(interruptRunning: false),
            now: HostClock(wallMs: 1_792_400_000_000, monoMs: 100, bootId: "test-boot"))
        let request = try review.signingRequest(managerID: "manager-a")
        XCTAssertNoThrow(try gate.authorize(request, log: f.log))

        let started = expectation(description: "Real shared-core init sent")
        let failed = expectation(description: "Malformed accept closes native channel")
        var route: RemoteChannelRoute?
        let signer = try AstationChannelSigner(identity: f.identity, keyID: "manager-a",
            active: { true }, confirm: { true })
        let context = AtemSessionContext(route: RemoteTerminalConnection(clientId: "local-host", connectionId: "connection-a"),
            account: "account-a", device: "host-a", pairingSession: "pairing-a")
        let connection = AstationR9Connection(context: context, current: { true }, write: { bytes, completion in
            if case .frame(let handle, _) = try? RemoteChannelEnvelope.readHost(bytes) {
                route = try? RemoteChannelRoute(linkGeneration: f.generation, handle: handle)
                started.fulfill()
            }
            completion(nil)
        }, welcomed: { _ in XCTFail("Malformed accept cannot welcome") }, receive: { _ in },
            failed: { _, _ in failed.fulfill() }, refreshMembership: { _ in },
            verifierGate: gate, generation: f.generation)
        try connection.start(identity: ClientIdentity(kind: .native, deviceId: "manager-a", keyId: "manager-a", grantJson: nil),
            log: f.log, signer: signer)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log), "Native router must retire the old report before accept")
        connection.receive(try RemoteChannelEnvelope.frame(Data("{}".utf8), route: XCTUnwrap(route)))
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(connection.isClosed)
        XCTAssertThrowsError(try gate.authorize(request, log: f.log))
    }

    @MainActor
    func testRelayOnlyAndSessionsOpenOneHandshakeAfterOwnerConfirmation() async throws {
        let manager = AstationIdentity.shared.id
        let membership = try NativeChannelFixture(account: manager, manager: manager, device: "selected-host")
        var answer: CheckedContinuation<Bool, Never>?
        var confirmations = 0
        var active = false
        let prompted = expectation(description: "One owner confirmation for session and policy")
        let signer = try AstationChannelSigner(identity: membership.identity, keyID: manager, active: { active }, confirm: {
            confirmations += 1
            return await withCheckedContinuation { answer = $0; prompted.fulfill() }
        })
        var preparations = 0
        let f = try TerminalHubFixture(relayOnly: true, prepareR9Channel: { _ in
            preparations += 1
            return (membership.log, signer)
        })
        try await f.start(); try await f.authenticate()
        let client = try XCTUnwrap(f.hub.sessionClient(for: f.clientId))
        for _ in 0..<3 { f.hub.requestAgentList(from: f.clientId) }
        try await Task.sleep(for: .milliseconds(2_200))
        await f.drain()
        XCTAssertEqual(client.phase, .connecting)
        XCTAssertTrue(client.status.contains("automatically"))
        XCTAssertFalse(client.connectionStatus.canReconnect, "Background discovery waits rather than requiring Retry")
        XCTAssertEqual(confirmations, 0)
        XCTAssertFalse(f.socket.sent.contains { ($0["payload"] as? [String: Any])?["type"] as? String == "channel" })
        XCTAssertFalse(f.hub.relayOnlyPolicyReady)
        active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [prompted], timeout: 1)
        try XCTUnwrap(answer).resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        await f.drain()
        let envelopes = f.socket.sent.compactMap { $0["payload"] as? [String: Any] }.filter { $0["type"] as? String == "channel" }
        let opens = envelopes.filter { $0["event"] as? String == "open" }
        let inits = envelopes.filter { ($0["frame"] as? [String: Any])?["op"] as? String == "init" }
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(opens.count, 1, "Policy must not race a second init against the session on the same host link")
        XCTAssertEqual(inits.count, 1)
        XCTAssertEqual(opens.first?["channel"] as? String, inits.first?["channel"] as? String)
        XCTAssertFalse(f.hub.relayOnlyPolicyReady, "A successful owner check alone is not a durable host ACK")
        f.hub.refreshNativeSessionMembership(try XCTUnwrap(client.context))
        await f.drain()
        let closes = f.socket.sent.compactMap { $0["payload"] as? [String: Any] }.filter { $0["event"] as? String == "close" }
        XCTAssertEqual(closes.count, 1, "Replacing a shared attachment must close its old host channel")
        XCTAssertEqual(closes.first?["channel"] as? String, opens.first?["channel"] as? String)
        XCTAssertFalse(f.hub.relayOnlyPolicyReady, "Replacement cannot retain the previous attachment's policy readiness")
        f.socket.fail(); await f.drain()
    }

    @MainActor
    func testBackgroundPreparationCannotSurviveDisconnectReplacementOrInvalidation() async throws {
        for outcome in ["disconnected", "replaced", "locked"] {
            let f = try NativeChannelFixture()
            var active = false
            var current = true
            var confirmations = 0
            var writes = 0
            var failures = 0
            let signer = try AstationChannelSigner(identity: f.identity, keyID: "manager-a", active: { active }, confirm: {
                confirmations += 1; return true
            })
            let context = AtemSessionContext(route: RemoteTerminalConnection(clientId: "local-host", connectionId: "connection-a"),
                account: "account-a", device: "host-a", pairingSession: "pairing-a")
            let waiting = expectation(description: "Waiting for activation before \(outcome)")
            let channel = AstationR9Connection(context: context, current: { current },
                write: { _, completion in writes += 1; completion(nil) },
                welcomed: { _ in }, receive: { _ in },
                failed: { _, _ in failures += 1 }, refreshMembership: { _ in },
                authorizationChanged: { stage in if stage == .waitingForForeground { waiting.fulfill() } })
            try channel.start(identity: ClientIdentity(kind: .native, deviceId: "manager-a", keyId: "manager-a", grantJson: nil),
                log: f.log, signer: signer)
            await fulfillment(of: [waiting], timeout: 1)
            switch outcome {
            case "disconnected": channel.disconnect()
            case "replaced": current = false
            default:
                // Use the same invalidation path as screen lock, without changing the real desktop session.
                signer.invalidate()
            }
            active = true
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(confirmations, 0, outcome)
            XCTAssertEqual(writes, 0, outcome)
            XCTAssertEqual(failures, outcome == "locked" ? 1 : 0, outcome)
            channel.disconnect()
        }
    }

    @MainActor
    func testDeniedOwnerConfirmationDoesNotAutomaticallyPromptAgain() async throws {
        let f = try NativeChannelFixture()
        var active = false
        var confirmations = 0
        var writes = 0
        var failures = 0
        let signer = try AstationChannelSigner(identity: f.identity, keyID: "manager-a", active: { active }, confirm: {
            confirmations += 1; return false
        })
        let context = AtemSessionContext(route: RemoteTerminalConnection(clientId: "local-host", connectionId: "connection-a"),
            account: "account-a", device: "host-a", pairingSession: "pairing-a")
        let waiting = expectation(description: "Background session waiting")
        let denied = expectation(description: "Owner declined")
        let channel = AstationR9Connection(context: context, current: { true },
            write: { _, completion in writes += 1; completion(nil) },
            welcomed: { _ in }, receive: { _ in },
            failed: { message, _ in
                XCTAssertTrue(message.contains("not completed")); failures += 1; denied.fulfill()
            }, refreshMembership: { _ in },
            authorizationChanged: { stage in if stage == .waitingForForeground { waiting.fulfill() } })
        try channel.start(identity: ClientIdentity(kind: .native, deviceId: "manager-a", keyId: "manager-a", grantJson: nil),
            log: f.log, signer: signer)
        await fulfillment(of: [waiting], timeout: 1)
        active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [denied], timeout: 1)
        active = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(channel.isClosed)
    }

    @MainActor
    func testNativeConnectionWaitsForActivationBeforeAndAfterAuthentication() async throws {
        let f = try NativeChannelFixture()
        var active = false
        let awaitingPrompt = expectation(description: "Foreground prompt")
        var answer: CheckedContinuation<Bool, Never>?
        let signer = try AstationChannelSigner(identity: f.identity, keyID: "manager-a", active: { active }, confirm: {
            XCTAssertTrue(active)
            return await withCheckedContinuation { answer = $0; awaitingPrompt.fulfill() }
        }, restoreForeground: {})
        let context = AtemSessionContext(route: RemoteTerminalConnection(clientId: "local-host", connectionId: "connection-a"),
            account: "account-a", device: "host-a", pairingSession: "pairing-a", transportGeneration: "transport-a")
        var writes: [Data] = []
        let opened = expectation(description: "Channel opened after restored activation")
        let channel = AstationR9Connection(context: context, current: { true },
            write: { bytes, completion in
                XCTAssertTrue(active)
                writes.append(bytes); completion(nil)
                if writes.count == 2 { opened.fulfill() }
            }, welcomed: { _ in }, receive: { _ in },
            failed: { message, _ in XCTFail("Unexpected failure: \(message)") }, refreshMembership: { _ in })
        try channel.start(identity: ClientIdentity(kind: .native, deviceId: "manager-a", keyId: "manager-a", grantJson: nil),
            log: f.log, signer: signer)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(answer)
        XCTAssertTrue(writes.isEmpty)
        active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [awaitingPrompt], timeout: 1)
        active = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try XCTUnwrap(answer).resume(returning: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(writes.isEmpty, "Authentication callback can precede restored app activation")
        active = true
        await fulfillment(of: [opened], timeout: 1)
        channel.disconnect()
    }

    @MainActor
    func testSuccessfulNativeAuthenticationExplicitlyRestoresForegroundBeforeOpening() async throws {
        let f = try NativeChannelFixture()
        var active = true
        var restorations = 0
        let signer = try AstationChannelSigner(identity: f.identity, keyID: "manager-a", active: { active }, confirm: {
            active = false
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            return true
        }, restoreForeground: {
            restorations += 1
            active = true
        })
        let context = AtemSessionContext(route: RemoteTerminalConnection(clientId: "local-host", connectionId: "connection-a"),
            account: "account-a", device: "host-a", pairingSession: "pairing-a", transportGeneration: "transport-a")
        let opened = expectation(description: "Restored foreground before channel init")
        var writes = 0
        let channel = AstationR9Connection(context: context, current: { true },
            write: { _, completion in
                XCTAssertTrue(active)
                XCTAssertEqual(restorations, 1)
                writes += 1; completion(nil)
                if writes == 2 { opened.fulfill() }
            }, welcomed: { _ in }, receive: { _ in },
            failed: { message, _ in XCTFail("Unexpected failure: \(message)") }, refreshMembership: { _ in })
        try channel.start(identity: ClientIdentity(kind: .native, deviceId: "manager-a", keyId: "manager-a", grantJson: nil),
            log: f.log, signer: signer)
        await fulfillment(of: [opened], timeout: 1)
        channel.disconnect()
    }

    @MainActor
    func testNativeForegroundWaitIsBoundedAndCancellationAware() async throws {
        do {
            try await AstationChannelSigner.waitForForeground(active: { false }, timeout: .milliseconds(10))
            XCTFail("Background wait did not expire")
        } catch { XCTAssertEqual(error as? RemoteOwnerAuthenticationError, .notForeground) }
        let task = Task { try await AstationChannelSigner.waitForForeground(active: { false }) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled activation wait succeeded") } catch { }
    }

    @MainActor
    func testOwnerConfirmationPrecedesAnyChannelTrafficAndDisconnectFencesItsCompletion() async throws {
        for outcome in ["confirmed", "disconnected", "system-auth-focus"] {
            let f = try NativeChannelFixture()
            let prompted = expectation(description: "Owner confirmation")
            var answer: CheckedContinuation<Bool, Never>?
            let signer = try AstationChannelSigner(identity: f.identity, keyID: "manager-a", active: { true }, confirm: {
                await withCheckedContinuation { answer = $0; prompted.fulfill() }
            })
            let context = AtemSessionContext(route: RemoteTerminalConnection(clientId: "local-host", connectionId: "connection-a"),
                account: "account-a", device: "host-a", pairingSession: "pairing-a", transportGeneration: "transport-a")
            var writes: [Data] = []
            var handshakes = 0
            let channel = AstationR9Connection(context: context, current: { true },
                write: { bytes, completion in
                    XCTAssertEqual(handshakes, 1, "The network timeout starts before the first write")
                    writes.append(bytes); completion(nil)
                }, welcomed: { _ in }, receive: { _ in },
                failed: { message, _ in XCTFail("Unexpected failure: \(message)") }, refreshMembership: { _ in },
                handshakeStarted: { handshakes += 1 })
            try channel.start(identity: ClientIdentity(kind: .native, deviceId: "manager-a", keyId: "manager-a", grantJson: nil),
                log: f.log, signer: signer)
            await fulfillment(of: [prompted], timeout: 1)
            XCTAssertEqual(handshakes, 0)
            XCTAssertTrue(writes.isEmpty, "The host handshake cannot start while waiting for owner authentication")
            if outcome == "disconnected" { channel.disconnect() }
            if outcome == "system-auth-focus" { NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil) }
            try XCTUnwrap(answer).resume(returning: true)
            let drained = expectation(description: "Authorization completion drained")
            Task { @MainActor in
                for _ in 0..<20 { await Task.yield() }
                drained.fulfill()
            }
            await fulfillment(of: [drained], timeout: 1)
            if outcome == "disconnected" { XCTAssertTrue(writes.isEmpty); XCTAssertEqual(handshakes, 0) }
            else {
                XCTAssertEqual(writes.count, 2, "Open and init follow owner authentication")
                channel.disconnect()
            }
        }
    }

    @MainActor
    func testConnectionErrorsDistinguishOwnerConfirmationTimeoutAndTransportClosure() {
        XCTAssertTrue(AstationR9Connection.connectionFailureMessage(RemoteRecoveryError.confirmationRequired).contains("Touch ID"))
        XCTAssertTrue(AstationR9Connection.connectionFailureMessage(RemoteOwnerAuthenticationError.notForeground).contains("foreground"))
        XCTAssertTrue(AstationR9Connection.connectionFailureMessage(RemoteOwnerAuthenticationError.denied).contains("not completed"))
        XCTAssertTrue(AstationR9Connection.connectionFailureMessage(RemoteChannelError.deadlineExceeded).contains("timed out"))
        XCTAssertFalse(AstationR9Connection.connectionFailureMessage(nil).contains("complete r9 device verification"))
    }

    @MainActor
    func testProductionBindingVerifiesHostThenRequestsAnOwnerAuthorizedEnclaveDomainSignature() async throws {
        let f = try NativeChannelFixture()
        let channel = try f.open()
        f.router.receive(try f.accept(for: channel), generation: f.generation)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(channel.phase, .awaitingWelcome)
        XCTAssertEqual(f.confirmations, 1)
        XCTAssertEqual(f.signatures, 1)
        guard case .frame(_, let frame) = try RemoteChannelEnvelope.readHost(XCTUnwrap(f.writes.last)) else { return XCTFail("No finish") }
        let finish = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: String])
        XCTAssertEqual(finish["op"], "finish")
        XCTAssertEqual(Set(finish.keys), ["ch", "op", "ct"])
        XCTAssertFalse(finish["ct"]?.isEmpty ?? true)
        XCTAssertThrowsError(try channel.perform(.list))
        f.router.linkLost()
    }

    @MainActor
    func testForgedHostNeverPromptsAndDisconnectDuringOwnerApprovalNeverSendsFinish() async throws {
        let forged = try NativeChannelFixture()
        let first = try forged.open()
        forged.router.receive(try forged.accept(for: first, tampered: true), generation: forged.generation)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(first.phase, .closed)
        XCTAssertEqual(forged.confirmations, 0)
        XCTAssertEqual(forged.signatures, 0)

        let f = try NativeChannelFixture()
        var answer: CheckedContinuation<Bool, Never>?
        f.confirm = { await withCheckedContinuation { answer = $0 } }
        let channel = try f.open()
        f.router.receive(try f.accept(for: channel), generation: f.generation)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(channel.phase, .signing)
        let writes = f.writes.count
        f.router.linkLost()
        try XCTUnwrap(answer).resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.signatures, 0)
        XCTAssertEqual(f.writes.count, writes)
        XCTAssertEqual(channel.phase, .closed)
    }
}
