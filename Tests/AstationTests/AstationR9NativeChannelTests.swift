import AppKit
import AtemClient
import AstationRemote
import CryptoKit
import XCTest
@testable import Menubar

@MainActor
private final class NativeChannelFixture {
    let crypto = TestAtemCryptography()
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

    init() throws {
        identity = AtemE2EIdentity(storage: TestAtemStorage(), crypto: crypto)
        let keys = try identity.remotePublicKeys()
        let body: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": "account-a", "seq": 1,
            "prev_hash": String(repeating: "0", count: 64), "action": "genesis", "signer": "manager-a", "signed_at": 1_792_400_000_000,
            "member": ["device_id": "manager-a", "kind": "native", "roles": ["control", "manage", "view"],
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
        log = try MembershipLog.verify(accountId: "account-a", genesisHash: XCTUnwrap(signedObjectInfo(json: genesis).entryHash),
            entries: [genesis], now: clock)
        let hostBody = try log.draftEntry(signer: "manager-a", signedAt: clock.wallMs,
            actionJson: Self.json(["action": "add_host", "host": ["host_id": "host-a", "host_trust_gen": 3,
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
            let channel = AstationR9Connection(context: context, current: { true },
                write: { bytes, completion in writes.append(bytes); completion(nil) }, welcomed: { _ in }, receive: { _ in },
                failed: { message, _ in XCTFail("Unexpected failure: \(message)") }, refreshMembership: { _ in })
            try channel.start(identity: ClientIdentity(kind: .native, deviceId: "manager-a", keyId: "manager-a", grantJson: nil),
                log: f.log, signer: signer)
            await fulfillment(of: [prompted], timeout: 1)
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
            if outcome == "disconnected" { XCTAssertTrue(writes.isEmpty) }
            else {
                XCTAssertEqual(writes.count, 2, "Open and init follow owner authentication")
                channel.disconnect()
            }
        }
    }

    @MainActor
    func testConnectionErrorsDistinguishOwnerConfirmationTimeoutAndTransportClosure() {
        XCTAssertTrue(AstationR9Connection.connectionFailureMessage(RemoteRecoveryError.confirmationRequired).contains("Touch ID"))
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
