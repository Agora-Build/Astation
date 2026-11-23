import AstationRemote
import Foundation

/// The manager reviews all SDK processes holding this member key, including offline ones.
struct AstationProcessRoster: Codable, Equatable {
    let origin: String
    let member: String
    let genesis: String
    let sequence: UInt64
    let headHash: String
    let lines: [String]

    func slots() throws -> [RemoteMemberVerifierSlot] {
        let slots = try Self.rows(member: member, text: lines.joined(separator: "\n"))
        guard slots.map({ $0.slot + " " + $0.process }) == lines else { throw RemoteVerifierGateError.invalidRoster }
        return slots
    }

    static func rows(member: String, text: String) throws -> [RemoteMemberVerifierSlot] {
        guard text.utf8.count <= 1_048_576 else { throw RemoteVerifierGateError.invalidRoster }
        var names = Set<String>()
        var result: [RemoteMemberVerifierSlot] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.isEmpty { continue }
            guard fields.count == 2, result.count < 4096,
                  names.insert(String(fields[0])).inserted else { throw RemoteVerifierGateError.invalidRoster }
            result.append(try RemoteMemberVerifierSlot(memberID: member, slot: String(fields[0]), process: String(fields[1])))
        }
        guard !result.isEmpty else { throw RemoteVerifierGateError.invalidRoster }
        return result.sorted { $0.slot < $1.slot }
    }
}
