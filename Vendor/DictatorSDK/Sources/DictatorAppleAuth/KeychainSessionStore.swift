import Foundation
import Security
import DictatorCore

public struct KeychainSessionStore: Sendable {
    private let service: String
    private let account: String
    public init(service: String, account: String = "dictator-session") { self.service = service; self.account = account }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let token = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return token
    }
    public func save(_ token: String) throws {
        let attributes = [kSecValueData as String: Data(token.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
        var request = query
        request[kSecValueData as String] = Data(token.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? { "Secure credentials could not be accessed." }
}

/// Persist only completed authentication. Second-factor cookies stay in the ephemeral session.
public actor StoredAuthentication {
    private let client: DictatorClient
    private let store: KeychainSessionStore
    public init(client: DictatorClient, store: KeychainSessionStore) { self.client = client; self.store = store }
    public func restore() async throws { await client.setSessionToken(try store.load()) }
    public func saveIfSignedIn(_ result: AuthenticationResult) async throws {
        if case .signedIn = result, let token = await client.storedSessionToken() { try store.save(token) }
    }
    public func signIn(email: String, password: String) async throws -> AuthenticationResult {
        try store.clear()
        let result = try await client.signIn(email: email, password: password)
        try await saveIfSignedIn(result)
        return result
    }
    public func verifyTOTP(_ code: String) async throws -> AuthenticationResult {
        let result = try await client.verifyTOTP(code)
        try await saveIfSignedIn(result)
        return result
    }
    public func signOut() async throws {
        defer { try? store.clear() }
        try await client.signOut()
    }
    public func verifyOTP(_ code: String) async throws -> AuthenticationResult {
        let result = try await client.verifyOTP(code)
        try await saveIfSignedIn(result)
        return result
    }
    public func verifyBackupCode(_ code: String) async throws -> AuthenticationResult {
        let result = try await client.verifyBackupCode(code)
        try await saveIfSignedIn(result)
        return result
    }
}
