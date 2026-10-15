import Foundation

struct RemoteTerminalConnection: Equatable {
    let clientId: String
    let connectionId: String
}

struct RemoteTerminalSession: Codable, Equatable, Identifiable {
    let terminalId: String
    let generation: String
    let provider: String
    var rows: Int
    var cols: Int
    var exitStatus: String?
    let rendering: String
    let widthProfile: String

    var id: String { terminalId + ":" + generation }
    var isSupported: Bool {
        rendering == "vt100-screen-diff" && widthProfile == "atem-unicode-width-0.1.14"
            && (2...200).contains(rows) && (2...400).contains(cols)
            && !terminalId.isEmpty && !generation.isEmpty
            && terminalId.utf8.count <= 128 && generation.utf8.count <= 128
    }

    enum CodingKeys: String, CodingKey {
        case terminalId = "terminal_id", generation, provider, rows, cols
        case exitStatus = "exit_status", rendering, widthProfile = "width_profile"
    }
}

struct RemoteTerminalStream: Equatable {
    let terminalId: String
    let generation: String
    let streamId: String
}

struct RemoteTerminalFrame: Equatable {
    let stream: RemoteTerminalStream
    let offset: UInt64
    let bytes: String
    let reset: Bool
    let complete: Bool
    let rows: Int
    let cols: Int
}

/// Flat serde-compatible data inside {"type":"terminal","data":...}.
enum RemoteTerminalMessage: Codable, Equatable {
    case list
    case sessions([RemoteTerminalSession])
    case subscribe(terminalId: String, generation: String)
    case unsubscribe(RemoteTerminalStream)
    case ack(RemoteTerminalStream, offset: UInt64)
    case control(RemoteTerminalStream, take: Bool)
    case input(RemoteTerminalStream, leaseId: String, sequence: UInt64, bytes: String)
    case resize(RemoteTerminalStream, leaseId: String, rows: Int, cols: Int)
    case stop(RemoteTerminalStream, leaseId: String)
    case attached(RemoteTerminalSession, streamId: String)
    case frame(RemoteTerminalFrame)
    case controller(RemoteTerminalStream, leaseId: String?)
    case written(RemoteTerminalStream, sequence: UInt64, error: String?)
    case exited(terminalId: String, generation: String, status: String)
    case error(terminalId: String?, message: String)
    case unsupported(version: Int, operation: String)

    private enum Keys: String, CodingKey {
        case v, op, sessions, session, generation, offset, take, sequence, bytes, rows, cols
        case reset, complete, error, status, message
        case terminalId = "terminal_id", streamId = "stream_id", leaseId = "lease_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let version = try c.decode(Int.self, forKey: .v)
        let op = try c.decode(String.self, forKey: .op)
        guard version == 1 else { self = .unsupported(version: version, operation: op); return }
        switch op {
        case "list": self = .list
        case "sessions": self = .sessions(try c.decode([RemoteTerminalSession].self, forKey: .sessions))
        case "subscribe":
            self = .subscribe(terminalId: try c.decode(String.self, forKey: .terminalId),
                              generation: try c.decode(String.self, forKey: .generation))
        case "unsubscribe": self = .unsubscribe(try Self.stream(c))
        case "ack": self = .ack(try Self.stream(c), offset: try c.decode(UInt64.self, forKey: .offset))
        case "control": self = .control(try Self.stream(c), take: try c.decode(Bool.self, forKey: .take))
        case "input":
            self = .input(try Self.stream(c), leaseId: try c.decode(String.self, forKey: .leaseId),
                          sequence: try c.decode(UInt64.self, forKey: .sequence),
                          bytes: try c.decode(String.self, forKey: .bytes))
        case "resize":
            self = .resize(try Self.stream(c), leaseId: try c.decode(String.self, forKey: .leaseId),
                           rows: try c.decode(Int.self, forKey: .rows), cols: try c.decode(Int.self, forKey: .cols))
        case "stop": self = .stop(try Self.stream(c), leaseId: try c.decode(String.self, forKey: .leaseId))
        case "attached":
            self = .attached(try c.decode(RemoteTerminalSession.self, forKey: .session),
                             streamId: try c.decode(String.self, forKey: .streamId))
        case "frame":
            self = .frame(RemoteTerminalFrame(
                stream: try Self.stream(c), offset: try c.decode(UInt64.self, forKey: .offset),
                bytes: try c.decode(String.self, forKey: .bytes), reset: try c.decode(Bool.self, forKey: .reset),
                complete: try c.decode(Bool.self, forKey: .complete), rows: try c.decode(Int.self, forKey: .rows),
                cols: try c.decode(Int.self, forKey: .cols)))
        case "controller": self = .controller(try Self.stream(c), leaseId: try c.decodeIfPresent(String.self, forKey: .leaseId))
        case "written":
            self = .written(try Self.stream(c), sequence: try c.decode(UInt64.self, forKey: .sequence),
                            error: try c.decodeIfPresent(String.self, forKey: .error))
        case "exited":
            self = .exited(terminalId: try c.decode(String.self, forKey: .terminalId),
                           generation: try c.decode(String.self, forKey: .generation),
                           status: try c.decode(String.self, forKey: .status))
        case "error":
            self = .error(terminalId: try c.decodeIfPresent(String.self, forKey: .terminalId),
                          message: try c.decode(String.self, forKey: .message))
        default: self = .unsupported(version: version, operation: op)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(1, forKey: .v)
        switch self {
        case .list: try c.encode("list", forKey: .op)
        case .sessions(let sessions):
            try c.encode("sessions", forKey: .op); try c.encode(sessions, forKey: .sessions)
        case .subscribe(let terminalId, let generation):
            try c.encode("subscribe", forKey: .op)
            try c.encode(terminalId, forKey: .terminalId); try c.encode(generation, forKey: .generation)
        case .unsubscribe(let stream):
            try c.encode("unsubscribe", forKey: .op); try Self.encode(stream, into: &c)
        case .ack(let stream, let offset):
            try c.encode("ack", forKey: .op); try Self.encode(stream, into: &c); try c.encode(offset, forKey: .offset)
        case .control(let stream, let take):
            try c.encode("control", forKey: .op); try Self.encode(stream, into: &c); try c.encode(take, forKey: .take)
        case .input(let stream, let leaseId, let sequence, let bytes):
            try c.encode("input", forKey: .op); try Self.encode(stream, into: &c)
            try c.encode(leaseId, forKey: .leaseId); try c.encode(sequence, forKey: .sequence)
            try c.encode(bytes, forKey: .bytes)
        case .resize(let stream, let leaseId, let rows, let cols):
            try c.encode("resize", forKey: .op); try Self.encode(stream, into: &c)
            try c.encode(leaseId, forKey: .leaseId); try c.encode(rows, forKey: .rows); try c.encode(cols, forKey: .cols)
        case .stop(let stream, let leaseId):
            try c.encode("stop", forKey: .op); try Self.encode(stream, into: &c); try c.encode(leaseId, forKey: .leaseId)
        case .attached(let session, let streamId):
            try c.encode("attached", forKey: .op); try c.encode(session, forKey: .session)
            try c.encode(streamId, forKey: .streamId)
        case .frame(let frame):
            try c.encode("frame", forKey: .op); try Self.encode(frame.stream, into: &c)
            try c.encode(frame.offset, forKey: .offset); try c.encode(frame.bytes, forKey: .bytes)
            try c.encode(frame.reset, forKey: .reset); try c.encode(frame.complete, forKey: .complete)
            try c.encode(frame.rows, forKey: .rows); try c.encode(frame.cols, forKey: .cols)
        case .controller(let stream, let leaseId):
            try c.encode("controller", forKey: .op); try Self.encode(stream, into: &c)
            try c.encode(leaseId, forKey: .leaseId)
        case .written(let stream, let sequence, let error):
            try c.encode("written", forKey: .op); try Self.encode(stream, into: &c)
            try c.encode(sequence, forKey: .sequence); try c.encode(error, forKey: .error)
        case .exited(let terminalId, let generation, let status):
            try c.encode("exited", forKey: .op); try c.encode(terminalId, forKey: .terminalId)
            try c.encode(generation, forKey: .generation); try c.encode(status, forKey: .status)
        case .error(let terminalId, let message):
            try c.encode("error", forKey: .op); try c.encode(terminalId, forKey: .terminalId)
            try c.encode(message, forKey: .message)
        case .unsupported:
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                debugDescription: "Unsupported terminal messages cannot be sent"))
        }
    }

    private static func stream(_ c: KeyedDecodingContainer<Keys>) throws -> RemoteTerminalStream {
        RemoteTerminalStream(terminalId: try c.decode(String.self, forKey: .terminalId),
                             generation: try c.decode(String.self, forKey: .generation),
                             streamId: try c.decode(String.self, forKey: .streamId))
    }

    private static func encode(_ stream: RemoteTerminalStream, into c: inout KeyedEncodingContainer<Keys>) throws {
        try c.encode(stream.terminalId, forKey: .terminalId)
        try c.encode(stream.generation, forKey: .generation)
        try c.encode(stream.streamId, forKey: .streamId)
    }
}
