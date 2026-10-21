import AtemClient
import AstationRemote
import CryptoKit
import XCTest
@testable import Menubar

@MainActor
private final class VerificationHarness {
    let storage = TestAtemStorage()
    let crypto = TestAtemCryptography()
    let device = Curve25519.KeyAgreement.PrivateKey()
    let route = AtemVerificationRoute(clientId: "client-1", connectionId: "connection-1", deviceId: "dev-1", deviceName: "Test Mac")
    let manager = AstationIdentity.shared.id
    var currentConnection = "connection-1"
    var account = "acct-1"
    var time = Date()
    var messages: [AstationMessage] = []
    var approvals: [(Bool) -> Void] = []
    var approvalCancellations = 0
    var synchronousApproval: Bool?
    var key: AccountDataKey?
    var deferKeys = false
    var deferPreparation = false
    var deferPublication = false
    var rejectStorage = false
    var kitSaved = true
    var pendingKeys: (() -> Void)?
    var pendingPreparation: (() -> Void)?
    var pendingPublication: (() -> Void)?
    var publicationCount = 0
    var genesis: RemoteRecoveryBootstrap?
    var log: MembershipLog?
    lazy var identity = AtemE2EIdentity(storage: storage, crypto: crypto)
    lazy var reveal = AtemVerifyReveal(devicePub: device.publicKey.rawRepresentation,
        deviceSignPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
        unlockAuthPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
        nonce: Data(repeating: 0x44, count: 32), hostChannelPub: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)

    func provider() throws -> AstationMembershipKeyProvider {
        AstationMembershipKeyProvider(identity: identity, keyID: manager, publicKey: try identity.remotePublicKeys().signing)
    }

    func keys(nonce: Data) throws -> AtemVerifyKeys {
        guard kitSaved else { throw AtemIdentityError.recoveryNotSaved }
        let material = try identity.remotePublicKeys()
        if log == nil {
            let bootstrap = try RemoteRecoveryBootstrap(accountID: account, managerID: manager, keyID: manager,
                authKey: PublicKeyData(alg: .p256, raw: material.signing),
                encryptionKey: PublicKeyData(alg: .x25519, raw: material.encryption), recoverySecret: Data(repeating: 7, count: 32),
                relayURL: "https://station.agora.build", signedAt: AstationRecoveryCoordinator.clock().wallMs, persist: { _ in })
            _ = try bootstrap.sign(provider: provider(), now: AstationRecoveryCoordinator.clock())
            try bootstrap.relayStored(now: AstationRecoveryCoordinator.clock())
            genesis = bootstrap
            log = try bootstrap.committedLog(now: AstationRecoveryCoordinator.clock())
        }
        try identity.markRecoverySaved(signingPublicKey: material.signing)
        return AtemVerifyKeys(signPub: material.signing, encPub: material.encryption,
            recoverySignPub: log!.recoveryKey().raw, nonce: nonce, genesisHash: log!.genesisHash())
    }

    lazy var controller = AtemVerificationController(identity: identity, account: { [unowned self] in account },
        key: { [unowned self] _, kid in
            guard kid == nil || kid == key?.kid else { throw AtemIdentityError.invalidState }
            return key
        },
        isCurrent: { [unowned self] in $0.clientId == route.clientId && $0.connectionId == currentConnection },
        send: { [unowned self] message, _ in messages.append(message) },
        approve: { [unowned self] request, callback in
            XCTAssertEqual(request.deviceName, "Test Mac")
            XCTAssertEqual(request.safetyCode.count, 14)
            approvals.append(callback)
            if let synchronousApproval { callback(synchronousApproval) }
            return { [unowned self] in approvalCancellations += 1; callback(false) }
        },
        prepareKeys: { [unowned self] _, nonce, completion in
            let finish = { [unowned self] in completion(Result { try keys(nonce: nonce) }) }
            if deferKeys { pendingKeys = finish } else { finish() }
        },
        prepareHost: { [unowned self] commit, reveal, _, completion in
            let finish = { [unowned self] in
                do {
                    var publisher: RemoteMembershipPublication? = RemoteMembershipPublication(log: try XCTUnwrap(log), persist: { [unowned self] _ in
                        if rejectStorage { throw RemoteRecoveryError.storageUncertain }
                    })
                    let body = try XCTUnwrap(publisher).prepareHost(commit: commit, hostChannelKey: PublicKeyData(alg: .ed25519,
                        raw: reveal.hostChannelPublicKey), signer: manager, signedAt: AstationRecoveryCoordinator.clock().wallMs)
                    completion(.success(AtemPreparedHostMembership(publish: { [unowned self] confirmedAt, current, reply in
                        let publish = { [unowned self] in
                            do {
                                guard current() else { throw RemoteChannelError.staleLink }
                                let live = try XCTUnwrap(publisher)
                                let request = try RemoteConfirmedSigner.membershipRequest(bodyJSON: body, keyID: manager)
                                let confirmed = try RemoteConfirmedSigner(provider: provider(), request: request,
                                    confirmedAt: confirmedAt, now: { DispatchTime.now().uptimeNanoseconds / 1_000_000 })
                                _ = try live.sign(provider: confirmed, keyID: manager)
                                guard !rejectStorage else { throw RemoteRecoveryError.storageUncertain }
                                _ = try live.relayStored(now: AstationRecoveryCoordinator.clock())
                                publicationCount += 1
                                reply(.success(live.entries))
                            } catch { reply(.failure(error)) }
                        }
                        if deferPublication { pendingPublication = publish } else { publish() }
                    }, cancel: { publisher = nil })))
                } catch { completion(.failure(error)) }
            }
            if deferPreparation { pendingPreparation = finish } else { finish() }
        }, now: { [unowned self] in time })

    func begin() throws {
        controller.start(AtemVerifyCommit(deviceId: route.deviceId, commitment: try reveal.commitment(), hostTrustGeneration: 3), route: route, account: account)
        if !deferKeys { controller.reveal(reveal, route: route) }
    }
    var certificates: [AtemDeviceVerified] { messages.compactMap { if case .deviceVerified(let v) = $0 { return v }; return nil } }
    var aborts: [String] { messages.compactMap { if case .verifyAbort(let v) = $0 { return v }; return nil } }
}

@MainActor
final class AtemVerificationControllerTests: XCTestCase {
    func testSuccessfulV2CeremonyPublishesSignedMembershipBeforePinningAndGranting() throws {
        let h = VerificationHarness()
        h.key = AccountDataKey(kid: "0123abcd", key: Data(repeating: 0x99, count: 32))
        try h.begin()
        XCTAssertTrue(h.certificates.isEmpty)
        XCTAssertFalse(try h.identity.isVerified(account: h.account, deviceId: h.route.deviceId))
        try XCTUnwrap(h.approvals.last)(true)
        let certificate = try XCTUnwrap(h.certificates.first)
        XCTAssertEqual(h.publicationCount, 1)
        XCTAssertEqual(certificate.membership?.entries.count, 2)
        XCTAssertTrue(try h.identity.isVerified(account: h.account, deviceId: h.route.deviceId))
        XCTAssertEqual(certificate.grants.count, 1)
        let sentKeys = try XCTUnwrap(h.messages.compactMap { message -> AtemVerifyKeys? in
            if case .verifyKeys(let keys) = message { return keys }; return nil
        }.first)
        XCTAssertEqual(atemStatementFields(certificate.deviceVerified)[7],
            try h.reveal.remote().transcript(keys: sentKeys.remote()))
    }

    func testInvalidDeviceGenerationAndDelayedCommitNeverCreateKeys() throws {
        for change in 0..<5 {
            let h = VerificationHarness()
            let original = h.account
            if change == 0 { h.account = "other" }
            if change == 1 { h.currentConnection = "other" }
            h.controller.start(AtemVerifyCommit(deviceId: change == 2 ? "other" : h.route.deviceId,
                commitment: try h.reveal.commitment(), hostTrustGeneration: change == 3 ? 0 : (change == 4 ? 9_007_199_254_740_992 : 3)),
                route: h.route, account: original)
            XCTAssertEqual(h.crypto.creates, 0)
            XCTAssertTrue(h.approvals.isEmpty)
        }
    }

    func testMissingSavedKitAndFailedCheckpointNeverOfferApproval() throws {
        for noKit in [false, true] {
            let h = VerificationHarness()
            h.kitSaved = !noKit
            h.rejectStorage = !noKit
            try h.begin()
            XCTAssertTrue(h.approvals.isEmpty)
            XCTAssertTrue(h.certificates.isEmpty)
            XCTAssertFalse(h.aborts.isEmpty)
        }
    }

    func testDeniedOwnerConfirmationDoesNotPublishOrPin() throws {
        let h = VerificationHarness()
        try h.begin()
        try XCTUnwrap(h.approvals.last)(false)
        XCTAssertEqual(h.publicationCount, 0)
        XCTAssertTrue(h.certificates.isEmpty)
        XCTAssertFalse(try h.identity.isVerified(account: h.account, deviceId: h.route.deviceId))
    }

    func testCancellationAccountChangeReconnectAndExpiryFenceEveryAsyncBoundary() throws {
        for boundary in 0..<3 {
            for change in 0..<4 {
                let h = VerificationHarness()
                h.deferKeys = boundary == 0
                h.deferPreparation = boundary == 1
                h.deferPublication = boundary == 2
                try h.begin()
                if boundary == 2 { try XCTUnwrap(h.approvals.last)(true) }
                switch change {
                case 0: h.controller.disconnect(clientId: h.route.clientId)
                case 1: h.currentConnection = "replacement"
                case 2: h.account = "other"
                default: h.time = h.time.addingTimeInterval(181)
                }
                h.pendingKeys?(); h.pendingPreparation?(); h.pendingPublication?()
                XCTAssertTrue(h.certificates.isEmpty)
                XCTAssertEqual(h.publicationCount, 0)
                XCTAssertFalse(try h.identity.isVerified(account: "acct-1", deviceId: h.route.deviceId))
            }
        }
    }

    func testPublicationFailureNeverPinsDevice() throws {
        let h = VerificationHarness()
        h.deferPublication = true
        try h.begin()
        try XCTUnwrap(h.approvals.last)(true)
        h.rejectStorage = true
        h.pendingPublication?()
        XCTAssertEqual(h.publicationCount, 0)
        XCTAssertTrue(h.certificates.isEmpty)
        XCTAssertFalse(try h.identity.isVerified(account: h.account, deviceId: h.route.deviceId))
    }

    func testReplayAndObsoleteApprovalCannotBeReused() throws {
        let h = VerificationHarness()
        try h.begin()
        let obsolete = try XCTUnwrap(h.approvals.last)
        h.controller.reveal(h.reveal, route: h.route)
        obsolete(true)
        XCTAssertTrue(h.certificates.isEmpty)
        try h.begin()
        obsolete(true)
        XCTAssertTrue(h.certificates.isEmpty)
        try XCTUnwrap(h.approvals.last)(true)
        XCTAssertEqual(h.certificates.count, 1)
    }

    func testDisconnectDismissesThePromptAndNewAttemptUsesANewNonce() throws {
        let h = VerificationHarness()
        try h.begin()
        h.controller.disconnect(clientId: h.route.clientId)
        XCTAssertEqual(h.approvalCancellations, 1)
        try h.begin()
        let nonces = h.messages.compactMap { if case .verifyKeys(let k) = $0 { return k.nonce }; return nil }
        XCTAssertEqual(nonces.count, 2)
        XCTAssertNotEqual(nonces[0], nonces[1])
    }

    func testKeyGrantStillRequiresAPinnedDeviceAndItsExactEncryptionKey() throws {
        let h = VerificationHarness()
        h.key = AccountDataKey(kid: "0123abcd", key: Data(repeating: 0x99, count: 32))
        h.controller.requestKey(publicKey: h.reveal.devicePub.base64EncodedString(), route: h.route)
        try h.begin()
        try XCTUnwrap(h.approvals.last)(true)
        h.controller.requestKey(publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), route: h.route)
        h.controller.requestKey(publicKey: h.reveal.devicePub.base64EncodedString(), route: h.route)
        XCTAssertEqual(h.messages.filter { if case .keyGrant = $0 { return true }; return false }.count, 1)
    }
}
