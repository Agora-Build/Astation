import Foundation

struct Example: Decodable {
    let `case`: String
    let raw: String
    let host_trust_gen: UInt64?
}
struct CommitExamples: Decodable { let valid: [Example]; let invalid: [Example] }
struct Vectors: Decodable { let verify_commit: CommitExamples }
let path = CommandLine.arguments[1]
let examples = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: URL(fileURLWithPath: path))).verify_commit
var checked = 0
func require(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
    checked += 1
}
for example in examples.valid {
    let result = try verifyCommitHostTrustGen(messageJson: example.raw)
    require(result == example.host_trust_gen, example.case)
}
for example in examples.invalid {
    do {
        _ = try verifyCommitHostTrustGen(messageJson: example.raw)
        fatalError("accepted invalid example: \(example.case)")
    } catch AtemError.Invalid(let code, _) {
        require(["malformed", "absent", "out_of_range"].contains(code), "typed error \(example.case): \(code)")
    }
}
let negatives: [(String, String)] = [
    (#"{"type":"other","data":{"host_trust_gen":3}}"#, "not_verify_commit"),
    (#"{"type":"verifyCommit","data":{"host_trust_gen":-0}}"#, "out_of_range"),
    (#"{"type":"verifyCommit","data":{"host_trust_gen":3},"data":{"host_trust_gen":4}}"#, "malformed"),
    (#"{"type":"verifyCommit","data":{"host_trust_gen":true}}"#, "out_of_range"),
    (#"{"type":"verifyCommit","data":{"host_trust_gen":3}} trailing"#, "malformed")
]
for (raw, expected) in negatives {
    do {
        _ = try verifyCommitHostTrustGen(messageJson: raw)
        fatalError("accepted negative: \(raw)")
    } catch AtemError.Invalid(let code, _) {
        require(code == expected, "expected \(expected), got \(code)")
    }
}
require(try verifyCommitHostTrustGen(messageJson: #"{"type":"verifyCommit","data":{"host_trust_gen":1}}"#) == 1, "minimum")
require(try canonicalJson(json: #"{"z":3,"a":"test"}"#) == #"{"a":"test","z":3}"#, "canonical JSON through built core")
let connection = try ClientConnection(hostId: "host-a", identity: ClientIdentity(kind: .native,
    deviceId: "dev-phone", keyId: "phone-key", grantJson: nil), needBefore: nil)
require(!connection.hostPolicyReady(), "policy cannot be ready before admission")
require(connection.hostPolicyRevision() == nil, "policy revision absent before admission")
do {
    _ = try connection.hostPolicyGet(desired: true, nowMs: 100)
    fatalError("policy read before admission")
} catch { checked += 1 }
do {
    _ = try connection.hostPolicyRetry(relayOnly: true, requestId: UUID().uuidString.lowercased(), expectedRevision: 0, nowMs: 100)
    fatalError("policy retry before admission")
} catch { checked += 1 }
print("PASS: \(checked) Swift consumer checks through the pinned production static library; all 12 pinned verifyCommit examples included")
