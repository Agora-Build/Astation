import XCTest
import Foundation
@testable import Menubar

private final class CustomCaptionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptSegment] = []
    func append(_ value: TranscriptSegment) { lock.withLock { storage.append(value) } }
    var segments: [TranscriptSegment] { lock.withLock { storage } }
}

private actor CustomTestHTTP {
    var requests: [URLRequest] = []
    var status = 200
    var data = Data("{\"text\":\"hello from a compatible server\"}".utf8)
    func configure(status: Int = 200, data: Data) { self.status = status; self.data = data }
    func send(_ request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class CustomResponseProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var declaredLength: Int?
    static func configure(body: Data, declaredLength: Int?) {
        lock.withLock { self.body = body; self.declaredLength = declaredLength }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, length) = Self.lock.withLock { (Self.body, Self.declaredLength) }
        let headers = length.map { ["Content-Length": String($0)] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor CustomPendingHTTP {
    var requests = 0
    private var pending: CheckedContinuation<(Data, URLResponse), Never>?
    private var request: URLRequest?
    func send(_ request: URLRequest) async -> (Data, URLResponse) {
        requests += 1; self.request = request
        return await withCheckedContinuation { pending = $0 }
    }
    func resolve() {
        pending?.resume(returning: (Data("{\"text\":\"late response\"}".utf8),
            HTTPURLResponse(url: request!.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        pending = nil
    }
}

final class CustomTranscriptionTests: XCTestCase {
    private func settings() -> TranscriptionSettings {
        var settings = TranscriptionSettings()
        settings.provider = .custom
        settings.customEndpoint = "https://speech.example.test/v1/audio/transcriptions"
        return settings
    }
    func testEndpointSafetyAndLocalHTTP() {
        for endpoint in ["https://api.example.test/v1/audio/transcriptions", "http://localhost:8080/v1/audio/transcriptions",
                         "http://127.0.0.1:9000/transcribe", "http://[::1]:8080/transcribe"] {
            XCTAssertNotNil(CustomTranscriptionHTTP.endpoint(endpoint), endpoint)
        }
        for endpoint in ["http://example.test/transcribe", "ftp://example.test/x", "https://user:key@example.test/x",
                         "https://example.test/x?key=secret", "https://example.test/x#fragment", "/v1/audio/transcriptions", ""] {
            XCTAssertNil(CustomTranscriptionHTTP.endpoint(endpoint), endpoint)
        }
    }
    func testMultipartMatchesOpenAICompatibleSchemaAndWAVHeader() throws {
        var config = settings(); config.language = "fr-FR"; config.customModel = "custom-whisper"
        let samples: [Float] = [-2, -0.5, 0, 0.5, 2, .nan, .infinity]
        let request = try CustomTranscriptionHTTP.request(settings: config, key: "test-only-key", samples: samples)
        XCTAssertEqual(request.url?.absoluteString, config.customEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
        let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary=astation-"))
        let body = try XCTUnwrap(request.httpBody)
        let printable = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(printable.contains("name=\"model\"\r\n\r\ncustom-whisper\r\n"))
        XCTAssertTrue(printable.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        XCTAssertTrue(printable.contains("name=\"language\"\r\n\r\nfr\r\n"))
        XCTAssertTrue(printable.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertFalse(printable.contains("test-only-key"))
        let wav = CustomTranscriptionHTTP.wav(samples)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        func u16(_ offset: Int) -> UInt16 { UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
        XCTAssertEqual(u32(4), UInt32(wav.count - 8)); XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u16(20), 1); XCTAssertEqual(u16(22), 1); XCTAssertEqual(u16(34), 16)
        XCTAssertEqual(u32(40), UInt32(samples.count * 2))
        XCTAssertEqual(Int16(bitPattern: u16(44)), -32_767)
        XCTAssertEqual(Int16(bitPattern: u16(52)), 32_767)
        XCTAssertEqual(u16(54), 0); XCTAssertEqual(u16(56), 0)
        XCTAssertNil(try CustomTranscriptionHTTP.request(settings: config, key: nil, samples: []).value(forHTTPHeaderField: "Authorization"))
    }
    func testRejectsMalformedPersistedSettingsAndHeaderInjection() {
        for model in ["", "bad\r\nmodel", String(repeating: "x", count: 257)] {
            var config = settings(); config.customModel = model
            XCTAssertThrowsError(try CustomTranscriptionHTTP.validate(config))
        }
        for language in ["", "en\r\nattack", "en_US", String(repeating: "a", count: 40)] {
            var config = settings(); config.language = language
            XCTAssertThrowsError(try CustomTranscriptionHTTP.validate(config))
        }
        var config = settings(); config.customChunkSeconds = 0
        XCTAssertThrowsError(try CustomTranscriptionHTTP.validate(config))
        XCTAssertThrowsError(try CustomTranscriptionHTTP.request(settings: settings(), key: "key\r\nInjected: yes", samples: []))
        XCTAssertThrowsError(try CustomTranscriptionHTTP.request(settings: settings(), key: nil, samples: [Float](repeating: 0, count: 24 * 16_000 + 1)))
    }
    func testSilenceIsNotUploadedAndWindowsCarrySourceAndOffset() async throws {
        let http = CustomTestHTTP(), captions = CustomCaptionCollector()
        var config = settings(); config.sourceID = "system"
        let engine = CustomHTTPTranscriber(settings: config, key: nil, send: { await http.send($0) })
        try await engine.start { captions.append($0) }
        try await engine.consume([Float](repeating: 0, count: 32_000))
        var requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        try await engine.consume([Float](repeating: 0.2, count: 16_000))
        try await engine.consume([Float](repeating: 0, count: 12_800))
        requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let caption = try XCTUnwrap(captions.segments.first)
        XCTAssertEqual(caption.sourceID, "system"); XCTAssertTrue(caption.isFinal)
        XCTAssertEqual(caption.offset, 1.8, accuracy: 0.001)
        try await engine.finish(); await engine.cancel()
        requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testHTTPAndSchemaFailuresAreRedactedAndDoNotRetry() async throws {
        for (status, data) in [(401, Data("secret-body-test-key".utf8)), (302, Data()),
                               (200, Data("{\"not_text\":42}".utf8)),
                               (200, Data(repeating: 65, count: 1_000_001)),
                               (200, try JSONSerialization.data(withJSONObject: ["text": String(repeating: "x", count: 65_537)]))] {
            let http = CustomTestHTTP(), captions = CustomCaptionCollector()
            await http.configure(status: status, data: data)
            let engine = CustomHTTPTranscriber(settings: settings(), key: "test-key", send: { await http.send($0) })
            try await engine.start { captions.append($0) }
            do {
                try await engine.consume([Float](repeating: 0.3, count: 80_000))
                XCTFail("Expected a failure")
            } catch { XCTAssertFalse(error.localizedDescription.contains("test-key")); XCTAssertFalse(error.localizedDescription.contains("secret-body")) }
            XCTAssertTrue(captions.segments.isEmpty)
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
            await engine.cancel()
        }
    }
    func testCancelRejectsTrailingUploads() async throws {
        let http = CustomTestHTTP(), captions = CustomCaptionCollector()
        let engine = CustomHTTPTranscriber(settings: settings(), key: nil, send: { await http.send($0) })
        try await engine.start { captions.append($0) }
        try await engine.consume([Float](repeating: 0.1, count: 16_000))
        await engine.cancel()
        do { try await engine.finish(); XCTFail("Cancelled engine must not upload trailing speech") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty); XCTAssertTrue(captions.segments.isEmpty)
    }
    func testRedirectDelegateDoesNotForwardAudioOrAuthorization() {
        let request = URLRequest(url: URL(string: "https://other.example.test/transcribe")!)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var decision: URLRequest? = request
        NoTranscriptionRedirects().urlSession(session, task: session.dataTask(with: request),
            willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!,
            newRequest: request) { decision = $0 }
        XCTAssertNil(decision)
    }
    func testTransportEnforcesResponseLimitWithAndWithoutContentLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CustomResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = try CustomTranscriptionHTTP.request(settings: settings(), key: nil, samples: [])
        CustomResponseProtocol.configure(body: Data("{\"text\":\"valid\"}".utf8), declaredLength: nil)
        let (valid, _) = try await CustomTranscriptionHTTP.send(request, session: session)
        XCTAssertEqual(String(decoding: valid, as: UTF8.self), "{\"text\":\"valid\"}")
        for length in [Int?.none, Int?(2_000_000)] {
            CustomResponseProtocol.configure(body: Data(repeating: 65, count: 1_000_001), declaredLength: length)
            do { _ = try await CustomTranscriptionHTTP.send(request, session: session); XCTFail("Expected bounded-response rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
        }
    }
    func testCancelDuringRequestSuppressesResultAndRemainingWindows() async throws {
        let http = CustomPendingHTTP(), captions = CustomCaptionCollector()
        let engine = CustomHTTPTranscriber(settings: settings(), key: nil, send: { await http.send($0) })
        try await engine.start { captions.append($0) }
        let consume = Task { try await engine.consume([Float](repeating: 0.2, count: 160_000)) }
        for _ in 0..<100 {
            if await http.requests > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await engine.cancel(); await http.resolve()
        do { try await consume.value; XCTFail("Cancelled request result must be suppressed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await http.requests
        XCTAssertEqual(requests, 1); XCTAssertTrue(captions.segments.isEmpty)
    }
}
