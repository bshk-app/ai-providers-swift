import Foundation
import Security
import AIProvidersCore

/// Each app chooses its own service. Shared SDK code does not share secrets.
public final class AICredentialVault: @unchecked Sendable {
    public let service: String
    public init(service: String) { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    public func read(_ id: UUID) throws -> Data {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else { throw AIProviderError.missingCredential }
        return data
    }
    public func write(_ data: Data, id: UUID) throws {
        let query = query(id)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AIProviderError.missingCredential }
        } else if status != errSecSuccess { throw AIProviderError.missingCredential }
    }
    public func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIProviderError.missingCredential }
    }
    /// Refresh can replace an existing item but cannot resurrect a disconnected account.
    public func replace(_ data: Data, id: UUID) throws {
        guard SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else { throw AIProviderError.missingCredential }
    }
    public func token(_ id: UUID) throws -> String {
        guard let string = String(data: try read(id), encoding: .utf8), !string.isEmpty else { throw AIProviderError.missingCredential }
        return string
    }
}
