import Foundation

/// Routing metadata is a hint; endpoint identity comes exclusively from the encrypted channel.
public struct RemoteRelayEnvelope {
    public let host: String
    public let connection: String
    public let payload: Data

    public init(_ data: Data) throws {
        guard data.count <= RemoteChannelEnvelope.maximumBytes + 1024 else { throw RemoteChannelWriteError.tooLarge }
        let fields = try RawFields.read(data)
        guard let host = fields.string("atem_id"), let connection = fields.string("connection_id"),
              !host.isEmpty, host.utf8.count <= 128, !connection.isEmpty, connection.utf8.count <= 128,
              let payload = fields.values["payload"] else { throw RemoteChannelWriteError.malformedFrame }
        self.host = host
        self.connection = connection
        self.payload = payload
    }

    public static func wrap(_ payload: Data, host: String, connection: String) throws -> Data {
        guard payload.count <= RemoteChannelEnvelope.maximumBytes,
              host.utf8.count <= 128, connection.utf8.count <= 128 else { throw RemoteChannelWriteError.tooLarge }
        var bytes = Data("{\"atem_id\":".utf8)
        bytes.append(try JSONEncoder().encode(host))
        bytes.append(Data(",\"connection_id\":".utf8))
        bytes.append(try JSONEncoder().encode(connection))
        bytes.append(Data(",\"payload\":".utf8)); bytes.append(payload); bytes.append(125)
        return bytes
    }

    public static func isChannel(_ data: Data) -> Bool {
        // A discriminator only. The bounded channel reader rejects malformed envelopes.
        guard data.count <= RemoteChannelEnvelope.maximumBytes else { return false }
        return (try? RawFields.read(data).string("type")) == "channel"
    }
}
