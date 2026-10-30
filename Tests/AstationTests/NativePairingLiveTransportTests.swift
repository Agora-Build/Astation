import Foundation
import XCTest
@testable import Menubar

@MainActor
final class NativePairingLiveTransportTests: XCTestCase {
    func testDeployedStationCarriesTokenFreeNativeIntroduction() async throws {
        try await checkDeployedStationIntroduction(includeHostID: true)
    }

    func testDeployedStationAssignedRouteCannotMatchAnUnrelatedIdentity() async throws {
        try await checkDeployedStationIntroduction(includeHostID: false)
    }

    private func checkDeployedStationIntroduction(includeHostID: Bool) async throws {
        guard let origin = ProcessInfo.processInfo.environment["ASTATION_PAIRING_LIVE_STATION"],
              let base = URL(string: origin), StationRelayURL.validatedBase(origin) != nil else {
            throw XCTSkip("Set ASTATION_PAIRING_LIVE_STATION to an isolated diagnostic Station")
        }
        var create = URLRequest(url: base.appendingPathComponent("api/pair"))
        create.httpMethod = "POST"; create.timeoutInterval = 15
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = Data(#"{"hostname":"astation-native-pairing-transport-test"}"#.utf8)
        let (bytes, response) = try await URLSession.shared.data(for: create)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let code = try XCTUnwrap(object["code"] as? String)
        var remove = URLRequest(url: base.appendingPathComponent("api/pair").appendingPathComponent(code))
        remove.httpMethod = "DELETE"; remove.timeoutInterval = 15
        let context = NativePairingContext(accountGeneration: UUID(), account: "synthetic-no-login",
            station: origin, astationID: "astation-diagnostic-" + UUID().uuidString)
        let hostID = "diagnostic-" + UUID().uuidString
        var hostURL = try XCTUnwrap(URLComponents(url: base, resolvingAgainstBaseURL: false))
        hostURL.scheme = base.scheme == "https" ? "wss" : "ws"
        hostURL.path += "/ws"
        hostURL.queryItems = [URLQueryItem(name: "role", value: "atem"), URLQueryItem(name: "code", value: code)]
        if includeHostID { hostURL.queryItems?.append(URLQueryItem(name: "atem_id", value: hostID)) }
        let host = URLSession.shared.webSocketTask(with: try XCTUnwrap(hostURL.url))
        var states: [NativePairingState] = []
        let native = NativePairingSession(context: { context }, authorize: {},
            makeSocket: { URLSession.shared.webSocketTask(with: $0) }, changed: { states.append($0) })
        host.resume()
        defer { native.cancel(); host.cancel(with: .normalClosure, reason: nil) }
        do {
            native.start(code: code)
            var bothConnected = false
            for _ in 0..<100 {
                let (status, _) = try await URLSession.shared.data(from: remove.url!)
                let peers = try XCTUnwrap(JSONSerialization.jsonObject(with: status) as? [String: Any])
                if peers["atem_connected"] as? Bool == true && peers["astation_connected"] as? Bool == true {
                    bothConnected = true; break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(bothConnected)
            let id = UUID().uuidString
            try await host.send(.string(#"{"type":"pairing","data":{"v":1,"op":"hello","id":"\#(id)"}}"#))
            let deadline = Task { try await Task.sleep(nanoseconds: 15_000_000_000); host.cancel(with: .goingAway, reason: nil) }
            defer { deadline.cancel() }
            let received: URLSessionWebSocketTask.Message
            do { received = try await host.receive() }
            catch { XCTFail("No introduction; native progress: \(states)"); throw error }
            guard case .string(let text) = received else { throw PairingIntroductionFrame.Invalid.message }
            let expected = try PairingIntroductionFrame.introduction(id: id, astationID: context.astationID)
            XCTAssertEqual(try AtemSessionJSON.parse(Data(text.utf8)), expected)
            XCTAssertEqual(native.state, .waitingForVerification, "Synthetic transport cannot establish real device trust")
            host.cancel(with: .normalClosure, reason: nil)
            // Routing agreement permits the owner prompt; it never substitutes for verification.
            XCTAssertEqual(native.beginAuthentication(code: code, attemptID: id, device: hostID,
                connection: UUID().uuidString), includeHostID)
            XCTAssertEqual(native.state, includeHostID ? .confirmingPairing : .waitingForVerification)
            let (_, cleaned) = try await URLSession.shared.data(for: remove)
            XCTAssertEqual((cleaned as? HTTPURLResponse)?.statusCode, 200)
        } catch {
            _ = try? await URLSession.shared.data(for: remove)
            throw error
        }
    }
}
