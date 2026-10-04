import Foundation
import AgoraRtcKit
import Darwin

/// Each child owns its RTC singleton, isolated from the app's existing C++ call engine.
final class CloudTranscriptionHelper: CloudAudioPublishing, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var stopped = false
    private var joined = false
    private var failure: String?
    private var readBuffer = Data()
    private var caption: (@Sendable (Data) -> Void)?
    private var pending: [Int16] = []
    func start(tokens: AgoraTranscriptionTokens, onCaption: @escaping @Sendable (Data) -> Void) async throws {
        guard let executable = Bundle.main.executableURL else { throw TranscriptionError.message("Cloud audio helper executable is missing.") }
        lock.withLock { caption = onCaption }
        process.executableURL = executable
        process.arguments = ["--cloud-transcription-worker"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in self?.recordFailure("The cloud audio publisher exited. Restart transcription.") }
        try writeLock.withLock {
            guard !stopped else { throw CancellationError() }
            try process.run()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try send(["type": "configure", "appID": tokens.appID, "channel": tokens.channel,
                      "uid": tokens.publisherUID, "botUID": tokens.botUID, "token": tokens.publisherToken])
        }
        for _ in 0..<750 {
            try Task.checkCancellation()
            if let error = snapshot().failure { throw TranscriptionError.message(error) }
            if snapshot().joined { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TranscriptionError.message("Cloud audio channel did not connect within 15 seconds.")
    }
    private func snapshot() -> (joined: Bool, failure: String?) {
        lock.lock(); defer { lock.unlock() }; return (joined, failure)
    }
    private func recordFailure(_ error: String) { lock.lock(); failure = error; lock.unlock() }
    private func receive(_ data: Data) {
        lock.lock()
        readBuffer.append(data)
        if readBuffer.count > 1_048_576 { failure = "Oversized cloud publisher message."; readBuffer.removeAll() }
        var messages: [[String: Any]] = []
        while let newline = readBuffer.firstIndex(of: 10) {
            let line = readBuffer.prefix(upTo: newline)
            if let item = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { messages.append(item) }
            readBuffer.removeSubrange(...newline)
        }
        lock.unlock()
        for item in messages {
            switch item["type"] as? String {
            case "ready": lock.lock(); joined = true; lock.unlock()
            case "caption":
                if let encoded = item["data"] as? String, let bytes = Data(base64Encoded: encoded) {
                    let callback = lock.withLock { caption }; callback?(bytes)
                }
            case "error": recordFailure("Agora audio publisher failed (\(item["code"] as? Int ?? -1)).")
            default: break
            }
        }
    }
    func push(_ samples: [Float]) async throws {
        if let error = snapshot().failure { throw TranscriptionError.message(error) }
        try writeLock.withLock {
            guard !stopped else { throw CancellationError() }
            pending.append(contentsOf: samples.map { $0.isFinite ? Int16((max(-1, min(1, $0)) * 32_767).rounded()) : 0 })
            while pending.count >= 320 {
                let frame = Array(pending.prefix(320))
                let data = frame.withUnsafeBytes { Data($0) }
                try send(["type": "audio", "data": data.base64EncodedString()])
                pending.removeFirst(320)
            }
        }
    }
    func finishAudio() async throws {
        try writeLock.withLock {
            guard !stopped else { throw CancellationError() }
            if !pending.isEmpty {
                let padded = pending + [Int16](repeating: 0, count: 320 - pending.count)
                try send(["type": "audio", "data": padded.withUnsafeBytes { Data($0) }.base64EncodedString()])
                pending.removeAll()
            }
        }
    }
    func renew(token: String) async throws {
        try writeLock.withLock {
            guard !stopped else { throw CancellationError() }
            try send(["type": "renew", "token": token])
        }
    }
    private func send(_ message: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: message)
        bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    func stop() async {
        writeLock.withLock {
            guard !stopped else { return }
            stopped = true
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            lock.withLock { caption = nil }
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            pending.removeAll()
        }
    }
}

final class CloudTranscriptionWorker: NSObject, AgoraRtcEngineDelegate {
    private var engine: AgoraRtcEngineKit?
    private var track = -1
    private var botUID: UInt = 0
    private let outputLock = NSLock()
    static func run() -> Int32 {
        let worker = CloudTranscriptionWorker()
        let completion = CloudWorkerCompletion()
        // Native SDK delegates run on the main queue. Keep it serviced while
        // stdin is read on a background thread; otherwise join never completes.
        DispatchQueue.global(qos: .userInitiated).async { completion.finish(worker.readInput()) }
        let port = Port()
        RunLoop.current.add(port, forMode: .default)
        defer { RunLoop.current.remove(port, forMode: .default) }
        defer {
            if worker.track >= 0 { worker.engine?.destroyCustomAudioTrack(worker.track) }
            worker.engine?.leaveChannel(nil)
            AgoraRtcEngineKit.destroy()
        }
        while completion.result == nil {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return completion.result ?? 1
    }
    private func readInput() -> Int32 {
        do {
            while let line = readLine(), line.utf8.count <= 131_072 {
                guard let bytes = line.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return 1 }
                try DispatchQueue.main.sync { try handle(object) }
            }
            return 0
        } catch { emit(["type": "error", "code": -1]); return 1 }
    }
    private func handle(_ object: [String: Any]) throws {
        switch object["type"] as? String {
        case "configure": try configure(object)
        case "audio":
            guard let text = object["data"] as? String, var data = Data(base64Encoded: text), data.count == 640,
                  let engine, track >= 0 else { throw TranscriptionError.message("Invalid audio packet.") }
            let result = data.withUnsafeMutableBytes {
                engine.pushExternalAudioFrameRawData($0.baseAddress!, samples: 320, sampleRate: 16_000,
                                                    channels: 1, trackId: track,
                                                    timestamp: Double(engine.getCurrentMonotonicTimeInMs()))
            }
            if result != 0 { emit(["type": "error", "code": result]); throw TranscriptionError.message("Cloud audio push failed.") }
        case "renew":
            guard let token = object["token"] as? String, token.hasPrefix("007") else { throw TranscriptionError.message("Invalid token.") }
            let result = engine?.renewToken(token) ?? -1
            if result != 0 { emit(["type": "error", "code": result]); throw TranscriptionError.message("Cloud renewal failed.") }
        default: throw TranscriptionError.message("Invalid cloud publisher message.")
        }
    }
    private func configure(_ object: [String: Any]) throws {
        guard engine == nil, let appID = object["appID"] as? String,
              appID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
              let channel = object["channel"] as? String, !channel.isEmpty, channel.utf8.count <= 64,
              let token = object["token"] as? String, token.hasPrefix("007"),
              let uid = object["uid"] as? NSNumber, let bot = object["botUID"] as? NSNumber else {
            throw TranscriptionError.message("Invalid cloud publisher configuration.")
        }
        botUID = bot.uintValue
        let config = AgoraRtcEngineConfig()
        config.appId = appID
        config.channelProfile = .liveBroadcasting
        let rtc = AgoraRtcEngineKit.sharedEngine(with: config, delegate: self)
        engine = rtc
        rtc.enableAudio()
        rtc.enableLocalAudio(false)
        let audio = AgoraAudioTrackConfig()
        audio.enableLocalPlayback = false
        track = Int(rtc.createCustomAudioTrack(.direct, config: audio))
        guard track >= 0, track != Int(UInt32.max) else { throw TranscriptionError.message("Cannot create cloud audio track.") }
        let options = AgoraRtcChannelMediaOptions()
        options.clientRoleType = .broadcaster
        options.channelProfile = .liveBroadcasting
        options.publishMicrophoneTrack = false
        options.publishCameraTrack = false
        options.publishCustomAudioTrack = true
        options.publishCustomAudioTrackId = track
        options.autoSubscribeAudio = false
        options.autoSubscribeVideo = false
        options.enableAudioRecordingOrPlayout = false
        let result = rtc.joinChannel(byToken: token, channelId: channel, uid: uid.uintValue, mediaOptions: options)
        guard result == 0 else { throw TranscriptionError.message("Cannot join cloud audio channel.") }
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        emit(["type": "ready"])
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, receiveStreamMessageFromUid uid: UInt, streamId: Int, data: Data) {
        guard uid == botUID, data.count <= 262_144 else { return }
        emit(["type": "caption", "data": data.base64EncodedString()])
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) { emit(["type": "error", "code": errorCode.rawValue]) }
    private func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        outputLock.lock(); defer { outputLock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

private final class CloudWorkerCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Int32?
    var result: Int32? { lock.withLock { storedResult } }
    func finish(_ result: Int32) { lock.withLock { storedResult = result } }
}
