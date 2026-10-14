import Foundation
import CryptoKit
import Security
import AIProvidersCore

public struct ChatGPTSession: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String
    public var clientID: String
    public var subject: String
    public var email: String?
    public var scopes: [String]
    public var expiresAt: Date
}
public struct ChatGPTAuthorization: Sendable {
    public let state: String
    public let nonce: String
    public let verifier: String
    public let callback: URL
    public let clientID: String?
    public let url: URL
    public init(hostID: String, appName: String, callback: URL, existing: ChatGPTSession? = nil) throws {
        guard callback.scheme == "http", callback.host == "127.0.0.1", callback.path == "/auth/callback", callback.port != nil else { throw AIProviderError.insecureEndpoint }
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AIProviderError.invalidResponse }
            return Data(bytes).base64URLEncoded
        }
        state = try random(); nonce = try random(); verifier = try random(); self.callback = callback; clientID = existing?.clientID
        var query = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var items = ["client_id": existing?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
            "response_type": "code", "redirect_uri": callback.absoluteString,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce, "code_challenge_method": "S256",
            "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded]
        if let existing { items["id_token_hint"] = existing.idToken }
        else { items["agent_name_hint"] = appName }
        query.queryItems = items.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }; url = query.url!
    }
    public func exchange(_ returned: URL, http: AIHTTP = AIHTTP()) async throws -> ChatGPTSession {
        guard returned.scheme == callback.scheme, returned.host == callback.host, returned.port == callback.port,
              returned.path == callback.path, let components = URLComponents(url: returned, resolvingAgainstBaseURL: false) else { throw AIProviderError.invalidResponse }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { throw AIProviderError.invalidResponse }
        func field(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard field("state") == state else { throw AIProviderError.invalidResponse }
        guard field("error") == nil else { throw AIProviderError.missingCredential }
        guard let code = field("code"), let issued = field("client_id") ?? clientID, issued != "dynamic_agent_client",
              clientID == nil || issued == clientID else { throw AIProviderError.invalidResponse }
        let value = try await ChatGPTTokenRequest.perform(["grant_type": "authorization_code", "client_id": issued,
            "code": code, "code_verifier": verifier, "redirect_uri": callback.absoluteString, "resource": "https://api.openai.com/v1"], http: http)
        let claims = try await ChatGPTIDToken.validate(value.idToken ?? "", clientID: issued, nonce: nonce, http: http)
        guard value.scopes.contains("chatgpt.tokens.use.direct"), let refresh = value.refreshToken else { throw AIProviderError.unsupported }
        return .init(accessToken: value.accessToken, refreshToken: refresh, idToken: value.idToken!, clientID: issued,
            subject: claims.subject, email: claims.email, scopes: value.scopes, expiresAt: Date().addingTimeInterval(value.expiresIn))
    }
}
private extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}
private struct ChatGPTTokenRequest {
    let accessToken: String, refreshToken: String?, idToken: String?
    let expiresIn: Double
    let scopes: [String]
    static func perform(_ fields: [String: String], http: AIHTTP) async throws -> Self {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        let value = try await http.json(request)
        guard let access = value["access_token"] as? String, (value["token_type"] as? String)?.lowercased() == "bearer",
              let expires = value["expires_in"] as? Double, expires > 0, let scopes = value["scope"] as? String else { throw AIProviderError.invalidResponse }
        return .init(accessToken: access, refreshToken: value["refresh_token"] as? String, idToken: value["id_token"] as? String,
            expiresIn: expires, scopes: scopes.split(separator: " ").map(String.init))
    }
}
public actor ChatGPTTokenStore {
    private let vault: AICredentialVault
    private let id: UUID
    private let http: AIHTTP
    private var refreshing: Task<String, Error>?
    private var refreshID: UUID?
    private var waiters: [UUID: CheckedContinuation<String, Error>] = [:]
    public init(vault: AICredentialVault, id: UUID, http: AIHTTP = AIHTTP()) { self.vault = vault; self.id = id; self.http = http }
    public func token() async throws -> String {
        try Task.checkCancellation()
        if let refreshing, let refreshID { return try await wait(for: refreshing, refreshID: refreshID) }
        var session = try JSONDecoder().decode(ChatGPTSession.self, from: vault.read(id))
        guard session.scopes.contains("chatgpt.tokens.use.direct") else { throw AIProviderError.unsupported }
        if session.expiresAt > Date().addingTimeInterval(60) { return session.accessToken }
        let task = Task { [vault, id, http] in
            let value = try await ChatGPTTokenRequest.perform(["grant_type": "refresh_token", "client_id": session.clientID,
                "refresh_token": session.refreshToken, "resource": "https://api.openai.com/v1"], http: http)
            guard value.scopes.contains("chatgpt.tokens.use.direct") else { throw AIProviderError.unsupported }
            if let token = value.idToken {
                let claims = try await ChatGPTIDToken.validate(token, clientID: session.clientID, nonce: nil, http: http)
                guard claims.subject == session.subject else { throw AIProviderError.missingCredential }; session.idToken = token
            }
            session.accessToken = value.accessToken; session.refreshToken = value.refreshToken ?? session.refreshToken
            session.scopes = value.scopes; session.expiresAt = Date().addingTimeInterval(value.expiresIn)
            try Task.checkCancellation()
            try vault.replace(JSONEncoder().encode(session), id: id)
            return session.accessToken
        }
        let id = UUID()
        refreshing = task; refreshID = id
        Task { [self] in
            let result = await task.result
            finishRefresh(id, result: result)
        }
        return try await wait(for: task, refreshID: id)
    }
    private func wait(for task: Task<String, Error>, refreshID expected: UUID) async throws -> String {
        // The refresh can finish between entering token() and registering.
        if refreshID != expected {
            let value = try await task.value; try Task.checkCancellation(); return value
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                if Task.isCancelled { cancelWaiter(id) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        // Refresh-token rotation is account state. Finish it atomically even
        // when this text request stops waiting, so a rotated token is not lost
        // and another consumer can still share the same in-flight refresh.
    }
    private func finishRefresh(_ id: UUID, result: Result<String, Error>) {
        guard refreshID == id else { return }
        refreshing = nil; refreshID = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }
}
private enum ChatGPTIDToken {
    struct Claims { let subject: String; let email: String? }
    static func validate(_ jwt: String, clientID: String, nonce: String?, http: AIHTTP) async throws -> Claims {
        let parts = jwt.split(separator: ".").map(String.init)
        guard parts.count == 3, let header = Data(base64URL: parts[0]), let body = Data(base64URL: parts[1]), let signature = Data(base64URL: parts[2]),
              let headers = try JSONSerialization.jsonObject(with: header) as? [String: Any], headers["alg"] as? String == "RS256",
              let kid = headers["kid"] as? String, let claims = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com", let exp = claims["exp"] as? Double, exp > Date().timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw AIProviderError.missingCredential }
        let audiences = claims["aud"] as? [String] ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID), nonce == nil || claims["nonce"] as? String == nonce else { throw AIProviderError.missingCredential }
        let discovery = try await http.json(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!))
        guard discovery["issuer"] as? String == "https://auth.openai.com", let address = discovery["jwks_uri"] as? String,
              let url = URL(string: address), url.scheme == "https", url.host == "auth.openai.com" else { throw AIProviderError.invalidResponse }
        let jwks = try await http.json(URLRequest(url: url))
        guard let keys = jwks["keys"] as? [[String: Any]], let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let n = key["n"] as? String, let e = key["e"] as? String, let modulus = Data(base64URL: n), let exponent = Data(base64URL: e) else { throw AIProviderError.missingCredential }
        func der(_ tag: UInt8, _ data: Data) -> Data {
            var length = data.count, bytes: [UInt8] = []
            repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
            let prefix: [UInt8] = data.count < 128 ? [UInt8(data.count)] : [0x80 | UInt8(bytes.count)] + bytes
            return Data([tag] + prefix) + data
        }
        func integer(_ data: Data) -> Data { der(2, data.first.map { $0 >= 128 } == true ? Data([0]) + data : data) }
        let rsa = der(0x30, integer(modulus) + integer(exponent))
        let attrs = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary
        guard let publicKey = SecKeyCreateWithData(rsa as CFData, attrs, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil) else { throw AIProviderError.missingCredential }
        return .init(subject: subject, email: claims["email"] as? String)
    }
}
