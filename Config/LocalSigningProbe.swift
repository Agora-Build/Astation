import Foundation
import Security

@main
struct LocalSigningProbe {
    static func main() {
        exit(run())
    }

    private static func run() -> Int32 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "build.agora.astation.local.keychain-probe",
            kSecAttrAccount as String: UUID().uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        defer { SecItemDelete(query as CFDictionary) }
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = Data([1])
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            print("Data Protection Keychain creation failed:", addStatus)
            return 1
        }
        var request = query
        request[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        let readStatus = SecItemCopyMatching(request as CFDictionary, &attributes)
        let accessibility = (attributes as? [String: Any])?[kSecAttrAccessible as String] as? String
        guard readStatus == errSecSuccess,
              accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String else {
            print("Data Protection Keychain accessibility check failed:", readStatus)
            return 1
        }
        print("Personal-team Data Protection Keychain access verified.")
        return 0
    }
}
