import CryptoKit
import Foundation

struct AtemProjectReportWire: Codable, Equatable {
    let signed: AtemSignedWire
    let encappedKey: Data
    let ciphertext: Data

    enum CodingKeys: String, CodingKey {
        case signed, ciphertext
        case encappedKey = "encapped_key"
    }
}

struct AtemReportedProjects {
    let account: String
    let deviceId: String
    let pin: AtemDevicePin
    let time: UInt64
    let projects: [String]
}

enum AtemCredentialProjects {
    static let maximumBytes = 65_536

    static func checkedFields(_ report: AtemProjectReportWire, account: String, deviceId: String,
                              pin: AtemDevicePin, now: Date) throws -> (time: UInt64, info: Data) {
        guard report.signed.statement.count <= 2048, report.signed.signature.count == 64,
              report.encappedKey.count == 32, (16...maximumBytes + 16).contains(report.ciphertext.count) else {
            throw AtemIdentityError.invalidState
        }
        try AtemStatementReader.verify(report.signed, publicKey: pin.deviceSignPub)
        let fields = try AtemE2ECrypto.decode(report.signed.statement, maximumFields: 6)
        guard fields.count == 6, fields[0] == Data("atem-credential-projects-v1".utf8),
              fields[1] == Data(account.utf8), fields[2] == Data(deviceId.utf8),
              fields[3] == AtemStatements.number(1), fields[4].count == 8,
              fields[5] == Data(SHA256.hash(data: try AtemE2ECrypto.encode([report.encappedKey, report.ciphertext]))) else {
            throw AtemIdentityError.invalidState
        }
        let time = fields[4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let age = now.timeIntervalSince1970 - Double(time)
        guard age >= -60, age <= 300 else { throw AtemIdentityError.invalidState }
        return (time, try AtemE2ECrypto.encode([Data("atem-credential-projects-info-v1".utf8)] + Array(fields[1...4])))
    }

    static func projects(_ plain: Data) throws -> [String] {
        guard plain.count <= maximumBytes, let names = try? JSONDecoder().decode([String].self, from: plain),
              names.count <= 256 else { throw AtemIdentityError.invalidState }
        for name in names {
            guard !name.isEmpty, try LocalCredentialStore.project(name) == name else { throw AtemIdentityError.invalidState }
        }
        return Array(Set(names)).sorted()
    }
}
