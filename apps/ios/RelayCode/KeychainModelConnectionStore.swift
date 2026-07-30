import Foundation
import RelayCodeCore
import Security

protocol ModelConnectionStoring {
    func loadConnections() throws -> [ModelConnectionConfiguration]
    func saveConnections(_ connections: [ModelConnectionConfiguration]) throws
    func loadCredential(reference: String) throws -> String?
    func saveCredential(_ credential: String, reference: String) throws
    func deleteCredential(reference: String) throws
}

struct KeychainModelConnectionStore: ModelConnectionStoring {
    private let service = "com.minseo.relaycode.models"
    private let profilesAccount = "profiles"

    func loadConnections() throws -> [ModelConnectionConfiguration] {
        guard let data = try read(account: profilesAccount) else {
            return []
        }
        return try JSONDecoder().decode([ModelConnectionConfiguration].self, from: data)
            .sorted(by: Self.connectionOrder)
    }

    func saveConnections(_ connections: [ModelConnectionConfiguration]) throws {
        let data = try JSONEncoder().encode(connections.sorted(by: Self.connectionOrder))
        try upsert(data: data, account: profilesAccount)
    }

    func loadCredential(reference: String) throws -> String? {
        try validate(reference: reference)
        guard let data = try read(account: reference) else {
            return nil
        }
        guard let credential = String(data: data, encoding: .utf8) else {
            throw ModelConnectionStoreError.invalidCredentialEncoding
        }
        return credential
    }

    func saveCredential(_ credential: String, reference: String) throws {
        try validate(reference: reference)
        guard let data = credential.data(using: .utf8), !data.isEmpty else {
            throw ModelConnectionStoreError.invalidCredentialEncoding
        }
        try upsert(data: data, account: reference)
    }

    func deleteCredential(reference: String) throws {
        try validate(reference: reference)
        try delete(account: reference)
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
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
        return data
    }

    private func upsert(data: Data, account: String) throws {
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account: account)
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

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func validate(reference: String) throws {
        guard reference.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw ModelConnectionStoreError.invalidCredentialReference
        }
    }

    private static func connectionOrder(
        _ lhs: ModelConnectionConfiguration,
        _ rhs: ModelConnectionConfiguration
    ) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

enum ModelConnectionStoreError: LocalizedError {
    case invalidCredentialReference
    case invalidCredentialEncoding

    var errorDescription: String? {
        switch self {
        case .invalidCredentialReference:
            "모델 인증정보 식별자가 올바르지 않습니다."
        case .invalidCredentialEncoding:
            "모델 인증정보를 안전하게 저장할 수 없습니다."
        }
    }
}
