import Foundation
import Security
import StreamProtocol

struct ViewerHost: Codable, Identifiable {
    var id: String { MacID.make(fingerprint: fingerprint) }
    let name: String
    let fingerprint: Data
    let recognitionKey: Data
    let serviceName: String?
    let address: String?
}

enum ViewerStore {
    // App and CLI builds have separate identities and Keychain access controls.
    private static let service = "\(Bundle.main.bundleIdentifier ?? "local.sill.viewer.cli").credentials"

    static func identity() throws -> RemoteIdentity {
        let tag = Data("\(service).tls-key".utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                   kSecAttrApplicationTag as String: tag,
                                   kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                   kSecReturnRef as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let key: SecKey
        if status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() {
            key = item as! SecKey
        } else if status == errSecItemNotFound {
            var error: Unmanaged<CFError>?
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                       kSecAttrKeySizeInBits as String: 256,
                                       kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                                          kSecAttrApplicationTag as String: tag,
                                          kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]]
            guard let created = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
                throw error?.takeRetainedValue() ?? failure("Cannot create viewer identity.")
            }
            key = created
        } else {
            throw failure("Cannot read viewer identity (Keychain \(status)).")
        }
        guard let identity = RemoteIdentity(privateKey: key) else { throw failure("Cannot create TLS certificate.") }
        return identity
    }

    static func hosts() throws -> [ViewerHost] {
        var query = hostQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data else {
            throw failure("Cannot read saved Macs (Keychain \(status)).")
        }
        return try JSONDecoder().decode([ViewerHost].self, from: data)
    }

    static func save(_ hosts: [ViewerHost]) throws {
        let data = try JSONEncoder().encode(hosts)
        let status = SecItemUpdate(hostQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = hostQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure("Cannot save paired Mac (Keychain \(added)).") }
        } else if status != errSecSuccess {
            throw failure("Cannot save paired Mac (Keychain \(status)).")
        }
    }

    private static var hostQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "paired-hosts"]
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "SillViewer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
