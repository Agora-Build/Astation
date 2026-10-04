import Foundation
import XCTest
@testable import Menubar

private final class CaptionURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let callback = Self.lock.withLock { Self.handler }
            let (status, bytes) = try XCTUnwrap(callback)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private actor CaptionPublisher: CloudAudioPublishing {
    var events: [String] = []
    var caption: (@Sendable (Data) -> Void)?
    var failStart = false
    func failOnStart() { failStart = true }
    func start(tokens: AgoraTranscriptionTokens, onCaption: @escaping @Sendable (Data) -> Void) throws {
        events.append("start:\(tokens.publisherUID)"); caption = onCaption
        if failStart { throw TranscriptionError.message("Publisher failed") }
    }
    func push(_ samples: [Float]) { events.append("audio") }
    func finishAudio() { events.append("flush") }
    func renew(token: String) { events.append("renew:\(token)") }
    func stop() { events.append("stop") }
    func emit(_ data: Data) { caption?(data) }
}
private final class CaptionRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { stored } }
    func record(_ request: URLRequest) { lock.withLock { stored.append(request) } }
}

final class AgoraTranscriptionTests: XCTestCase {
    private var tokens: AgoraTranscriptionTokens {
        AgoraTranscriptionTokens(appID: String(repeating: "a", count: 32), channel: "astation-caption-test",
                                 publisherUID: 101, botUID: 201, publisherToken: "007publisher", botToken: "007bot")
    }
    private func client(handler: @escaping (URLRequest) throws -> (Int, Data)) -> AgoraTranscriptionClient {
        CaptionURLProtocol.lock.withLock { CaptionURLProtocol.handler = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptionURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel(); CaptionURLProtocol.lock.withLock { CaptionURLProtocol.handler = nil } }
        return AgoraTranscriptionClient(session: session)
    }
    private func data(_ text: String) -> Data { Data(text.utf8) }
    func testMixedJSONAndGzipCaptionsIncludeLiveSuffixWithoutCompatibilityDuplicate() throws {
        let json = data("""
        {"transcript":{"uid":101,"sentenceId":7,"offset":2000,"language":"en-US","text":"Hello.","isFinal":true,"results":[{"text":"Hello.","isFinal":true},{"text":"How","isFinal":false}]}}
        """)
        let segments = try AgoraCaptionDecoder.decode(json, sourceID: "system", publisherUID: 101)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello. How")
        XCTAssertFalse(segments[0].isFinal)
        XCTAssertEqual(segments[0].offset, 2)
        let gzip = Data(base64Encoded: "H4sIAAAAAAAAE03KMQoCMRAF0Lv8OkrWRpgDiNZiJRZhd7IEhlnJTFgh5O6WWr/X4TWpzbW8HdTRygKa4hRgrM46820BnQO2nI0ddIoxBkjStaWVQWA9PO4IqGxN3EDPDuePg3Blke2IgGKXoklAXhuP8Avb/q85ifF4jfEFrgq/HpYAAAA=")!
        XCTAssertEqual(try AgoraCaptionDecoder.decode(gzip, sourceID: "system", publisherUID: 101), segments)
        let duplicate = data("{\"transcript\":{\"uid\":101,\"text\":\"Hello.\",\"isFinal\":true,\"results\":[]}}")
        XCTAssertTrue(try AgoraCaptionDecoder.decode(duplicate, sourceID: "system", publisherUID: 101).isEmpty)
    }
    func testCaptionUIDDoesNotAcceptWrappedOrFractionalValuesAndBoundsPayload() throws {
        for uid in ["4294967397", "101.5", "-4294967195", "102"] {
            let payload = data("{\"transcript\":{\"uid\":\(uid),\"text\":\"wrong source\",\"isFinal\":true}}")
            XCTAssertTrue(try AgoraCaptionDecoder.decode(payload, sourceID: "mic", publisherUID: 101).isEmpty)
        }
        XCTAssertThrowsError(try AgoraCaptionDecoder.decode(Data([0x1f, 0x8b, 1]), sourceID: "mic", publisherUID: 101))
        XCTAssertThrowsError(try AgoraCaptionDecoder.decode(Data(repeating: 0, count: 262_145), sourceID: "mic", publisherUID: 101))
    }
    func testTranslationsAreGroupedByLanguageAndFinalState() throws {
        let payload = data("""
        {"translation":{"uid":101,"sentenceId":8,"offset":1000,"isFinal":true,"results":[
            {"language":"es-ES","texts":["Hola."],"isFinal":true},
            {"language":"es-ES","texts":["Como"],"isFinal":false},
            {"language":"fr-FR","texts":["Bonjour."],"isFinal":true}]}}
        """)
        let segments = try AgoraCaptionDecoder.decode(payload, sourceID: "app", publisherUID: 101)
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy(\.isTranslation))
        let spanish = try XCTUnwrap(segments.first { $0.language == "es-ES" })
        XCTAssertEqual(spanish.text, "Hola. Como")
        XCTAssertFalse(spanish.isFinal)
        XCTAssertEqual(segments.first { $0.language == "fr-FR" }?.isFinal, true)
    }
    func testJoinBodyAndAccessTokenAuthenticationOnlySubscribeToSelectedPublisher() async throws {
        let requests = CaptionRequests()
        let client = client { request in requests.record(request); return (200, Data("{\"agent_id\":\"test-agent\"}".utf8)) }
        var settings = TranscriptionSettings(); settings.provider = .agora; settings.translationLanguage = "es-ES"
        let id = try await client.join(tokens: tokens, settings: settings)
        XCTAssertEqual(id, "test-agent")
        let request = try XCTUnwrap(requests.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/speech-to-text/v1/projects/\(tokens.appID)/join")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "agora token=\"007publisher\"")
        // URLProtocol may expose upload bytes as a stream; build the same body directly for schema assertions.
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: AgoraTranscriptionClient.joinBody(tokens: tokens, settings: settings, name: "test")) as? [String: Any])
        XCTAssertEqual(body["languages"] as? [String], ["en-US"])
        XCTAssertEqual(body["maxIdleTime"] as? Int, 30)
        let rtc = try XCTUnwrap(body["rtcConfig"] as? [String: Any])
        XCTAssertEqual(rtc["subscribeAudioUids"] as? [String], ["101"])
        XCTAssertEqual(rtc["pubBotUid"] as? String, "201")
        XCTAssertEqual(rtc["enableJsonProtocol"] as? Bool, true)
        let translation = try XCTUnwrap(body["translateConfig"] as? [String: Any])
        let pair = try XCTUnwrap((translation["languages"] as? [[String: Any]])?.first)
        XCTAssertEqual(pair["source"] as? String, "en-US")
        XCTAssertEqual(pair["target"] as? [String], ["es-ES"])
    }
    func testHTTPErrorDoesNotExposeTokensOrResponseBodyAndRejectsUnsafeAgentID() async throws {
        let client = client { _ in (403, Data("SECRET_RESPONSE_007token".utf8)) }
        do { _ = try await client.join(tokens: tokens, settings: TranscriptionSettings()); XCTFail("Error ignored") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("403"))
            XCTAssertFalse(error.localizedDescription.contains("SECRET_RESPONSE"))
            XCTAssertFalse(error.localizedDescription.contains("007"))
        }
        do { try await client.leave(agentID: "../escape", tokens: tokens); XCTFail("Unsafe agent accepted") } catch {}
        var settings = TranscriptionSettings(); settings.translationLanguage = "en-US"
        XCTAssertThrowsError(try AgoraTranscriptionClient.joinBody(tokens: tokens, settings: settings, name: "test"))
    }
    func testCloudLifecycleCaptionsCleanupAndIdempotentCancel() async throws {
        let requests = CaptionRequests()
        let client = client { request in
            requests.record(request)
            return (200, Data("{\"agent_id\":\"cloud-agent\"}".utf8))
        }
        let publisher = CaptionPublisher(), credentials = tokens
        let engine = AgoraCloudTranscriber(settings: TranscriptionSettings(), tokenProvider: { credentials }, client: client, publisher: publisher)
        let caption = expectation(description: "Decoded caption")
        try await engine.start { segment in XCTAssertEqual(segment.text, "Hello"); caption.fulfill() }
        await publisher.emit(data("{\"transcript\":{\"uid\":101,\"sentenceId\":1,\"text\":\"Hello\",\"isFinal\":true}}"))
        await fulfillment(of: [caption], timeout: 1)
        try await engine.consume([0.25])
        await engine.cancel(); await engine.cancel()
        let events = await publisher.events
        XCTAssertEqual(events, ["start:101", "audio", "stop"])
        XCTAssertEqual(requests.requests.map { $0.url!.lastPathComponent }, ["join", "leave"])
    }
    func testPublisherStartFailureDoesNotStartCloudAgentAndCleansUp() async throws {
        let requests = CaptionRequests()
        let client = client { request in requests.record(request); return (200, Data()) }
        let publisher = CaptionPublisher(), credentials = tokens
        await publisher.failOnStart()
        let engine = AgoraCloudTranscriber(settings: TranscriptionSettings(), tokenProvider: { credentials }, client: client, publisher: publisher)
        do { try await engine.start { _ in }; XCTFail("Failure ignored") } catch {}
        XCTAssertTrue(requests.requests.isEmpty)
        let events = await publisher.events
        XCTAssertEqual(events, ["start:101", "stop"])
    }
    func testRenewalRecreatesAgentBeforeExpiryAndCancelLeavesCurrentAgent() async throws {
        let requests = CaptionRequests()
        let client = client { request in requests.record(request); return (200, Data("{\"agent_id\":\"renewal-agent\"}".utf8)) }
        let publisher = CaptionPublisher(), credentials = tokens
        let engine = AgoraCloudTranscriber(settings: TranscriptionSettings(), tokenProvider: { credentials }, client: client,
                                          publisher: publisher, renewalInterval: 30_000_000)
        try await engine.start { _ in }
        for _ in 0..<100 {
            if requests.requests.count >= 3 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await engine.cancel()
        XCTAssertGreaterThanOrEqual(requests.requests.count, 4)
        XCTAssertEqual(Array(requests.requests.prefix(3)).map { $0.url!.lastPathComponent }, ["join", "leave", "join"])
        XCTAssertEqual(requests.requests.last?.url?.lastPathComponent, "leave")
        let events = await publisher.events
        XCTAssertTrue(events.contains("renew:007publisher"))
    }
    func testCancellationDuringHTTPJoinStillLeavesCreatedAgent() async throws {
        let requests = CaptionRequests()
        let client = client { request in
            requests.record(request)
            if request.url!.lastPathComponent == "join" { Thread.sleep(forTimeInterval: 0.06) }
            return (200, Data("{\"agent_id\":\"cancelled-agent\"}".utf8))
        }
        let publisher = CaptionPublisher(), credentials = tokens
        let engine = AgoraCloudTranscriber(settings: TranscriptionSettings(), tokenProvider: { credentials }, client: client, publisher: publisher)
        let task = Task { try await engine.start { _ in } }
        for _ in 0..<100 {
            if !requests.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel(); await engine.cancel()
        do { try await task.value; XCTFail("Cancelled start succeeded") } catch {}
        XCTAssertEqual(requests.requests.map { $0.url!.lastPathComponent }, ["join", "leave"])
    }
}
