import Foundation
import RelayCodeCore
import Security

protocol PairingStoring {
    func load() throws -> PairingConfiguration?
    func save(_ pairing: PairingConfiguration) throws
    func delete() throws
}

struct KeychainPairingStore: PairingStoring {
    private let service = "com.minseo.relaycode"
    private let account = "pairing"

    func load() throws -> PairingConfiguration? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unhandled(status)
        }
        return try JSONDecoder().decode(PairingConfiguration.self, from: data)
    }

    func save(_ pairing: PairingConfiguration) throws {
        let data = try JSONEncoder().encode(pairing)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item.merge(updates) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

enum KeychainError: LocalizedError {
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unhandled(status):
            "Keychain 작업에 실패했습니다. (\(status))"
        }
    }
}
