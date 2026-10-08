import XCTest
import AppKit
import CoreGraphics
import CStationCore
@testable import Menubar

final class ScreenShareLiveValidationTests: XCTestCase {
    @MainActor
    func testLiveScreenCapturePublication() async throws {
        guard ProcessInfo.processInfo.environment["ASTATION_SCREEN_SHARE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set ASTATION_SCREEN_SHARE_LIVE_TEST=1 to run a live Agora capture check.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required for the test runner.")
        }
        guard let session = SsoSessionStore().load(), !session.needsRefresh() else {
            throw XCTSkip("Sign in to Astation before running the live check.")
        }
        var request = URLRequest(url: URL(string: "\(SsoConfig.currentBffUrl)/api/cli/v1/projects")!)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let projects = try JSONDecoder().decode(BffProjectsEnvelope.self, from: data)
        let project = try XCTUnwrap(projects.items.first(where: { !($0.signKey ?? "").isEmpty }))
        let channel = "astation-screen-check-\(UUID().uuidString.prefix(8))"
        let tokenPointer = try XCTUnwrap(astation_rtc_build_token(
            project.appId, project.signKey!, channel, 0, 1, 120, 120
        ))
        let token = String(cString: tokenPointer)
        astation_token_free(tokenPointer)
        let configuration: [String: Any] = [
            "app_id": project.appId, "channel": channel, "token": token, "uid": 12345, "name": "Screen test"
        ]
        let configURL = URL(fileURLWithPath: "/private/tmp/astation-screen-share-live.json")
        try JSONSerialization.data(withJSONObject: configuration).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let manager = RTCManager()
        try manager.initialize(appId: project.appId)
        manager.muteMic(true)
        defer { manager.leaveChannel() }
        let joined = expectation(description: "Agora channel joined")
        manager.onJoinSuccess = { _, _ in joined.fulfill() }
        manager.onError = { code, message in print("Live RTC error: \(code) \(message)") }
        manager.joinChannel(token: token, channel: channel, uid: 12344)
        await fulfillment(of: [joined], timeout: 20)
        guard manager.isInChannel else { return }
        let started = await manager.startScreenShare(displayId: 0, options: ScreenShareOptions(captureAudio: true, frameRate: 60))
        XCTAssertTrue(started)
        guard started else { return }
        try await Task.sleep(nanoseconds: 20_000_000_000)
        let stats = try XCTUnwrap(manager.screenCaptureStatistics)
        print("Live capture accepted: \(stats.videoFrames) video frames, \(stats.width)x\(stats.height), \(stats.audioPackets) stereo audio packets")
        XCTAssertGreaterThan(stats.videoFrames, 0)
        XCTAssertGreaterThan(stats.audioPackets, 0)
        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(CGMainDisplayID()))
        XCTAssertEqual(stats.width, mode.pixelWidth & ~1)
        XCTAssertEqual(stats.height, mode.pixelHeight & ~1)
    }
}
