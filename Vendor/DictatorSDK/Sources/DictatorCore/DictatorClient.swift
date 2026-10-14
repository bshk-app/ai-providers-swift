import Foundation

public actor DictatorClient {
    private let controlURL: URL
    private var gatewayURL: URL?
    private let session: URLSession
    private var sessionToken: String?
    private var key: (value: String, expiresAt: Double)?
    private var userAPIKey: String?

    /// BYOK never calls the account API or issues a temporary gateway key.
    public init(gatewayURL: URL, apiKey: String, session: URLSession? = nil) throws {
        guard gatewayURL.scheme == "https", gatewayURL.host != nil,
              gatewayURL.user == nil, gatewayURL.password == nil, gatewayURL.query == nil, gatewayURL.fragment == nil else { throw DictatorError.insecureURL }
        guard !apiKey.isEmpty, !apiKey.contains("\r"), !apiKey.contains("\n") else { throw DictatorError.unauthorized("Missing API key") }
        self.controlURL = gatewayURL; self.gatewayURL = gatewayURL; userAPIKey = apiKey
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public init(controlURL: URL, gatewayURL: URL? = nil, session: URLSession? = nil) throws {
        guard controlURL.scheme == "https", gatewayURL == nil || gatewayURL?.scheme == "https" else { throw DictatorError.insecureURL }
        self.controlURL = controlURL; self.gatewayURL = gatewayURL
        self.session = session ?? URLSession(configuration: .ephemeral)
    }
    public func setSessionToken(_ token: String?) { sessionToken = token; key = nil }
    public func storedSessionToken() -> String? { sessionToken }

    private func endpoint(_ base: URL, _ path: String) -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        if root.hasSuffix("/v1") { root.removeLast(3) }
        return URL(string: root + path)!
    }
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DictatorError.invalidResponse }
        if !(200..<300).contains(response.statusCode) {
            struct Failure: Decodable { let error: String?; let message: String?; let detail: String? }
            let body = try? JSONDecoder().decode(Failure.self, from: data)
            let message = body?.error ?? body?.message ?? body?.detail ?? "Request refused"
            switch response.statusCode {
            case 401: throw DictatorError.unauthorized(message)
            case 402: throw DictatorError.insufficientCredits(message)
            case 502, 503, 504: throw DictatorError.unavailable(message)
            default: throw DictatorError.rejected(status: response.statusCode, message: message)
            }
        }
        return (data, response)
    }
    private func control(_ path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint(controlURL, path))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var origin = URLComponents(url: controlURL, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil; origin.fragment = nil
        request.setValue(origin.string, forHTTPHeaderField: "Origin")
        if let token = sessionToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await perform(request)
    }
    public func account() async throws -> Account {
        try JSONDecoder().decode(Account.self, from: await control("/api/mobile/account").0)
    }
    public func organizations() async throws -> [Organization] {
        try JSONDecoder().decode([Organization].self, from: await control("/api/auth/organization/list").0)
    }
    public func selectOrganization(_ id: String) async throws {
        _ = try await control("/api/auth/organization/set-active", method: "POST", body: JSONSerialization.data(withJSONObject: ["organizationId": id]))
        key = nil
    }
    public func capabilities() async throws -> Capabilities {
        let result = try JSONDecoder().decode(Capabilities.self, from: await control("/api/mobile/capabilities").0)
        guard result.gatewayUrl.scheme == "https" else { throw DictatorError.insecureURL }
        gatewayURL = result.gatewayUrl
        return result
    }
    private func cloudAccess() async throws -> (URL, String) {
        if let userAPIKey, let gatewayURL { return (gatewayURL, userAPIKey) }
        if gatewayURL == nil { _ = try await capabilities() }
        if key == nil || key!.expiresAt <= Date().timeIntervalSince1970 * 1000 + 5_000 {
            struct Key: Decodable { let key: String; let expiresAt: Double }
            let value = try JSONDecoder().decode(Key.self, from: await control("/api/mobile/key", method: "POST").0)
            key = (value.key, value.expiresAt)
        }
        return (gatewayURL!, key!.value)
    }
    public func transcribe(audio: Data, options: TranscriptionOptions = .init()) async throws -> TranscriptionResult {
        guard audio.count <= 32 * 1024 * 1024 else { throw DictatorError.invalidAudio }
        var fields = ["tier": options.tier.rawValue.lowercased()]
        if let value = options.language { fields["language"] = value }
        if let value = options.targetLanguage { fields["target_language"] = value }
        let boundary = "dictator-\(UUID().uuidString)"
        let filename = options.filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = multipart(fields, boundary: boundary)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let data = try await cloud("/v1/audio/transcriptions", body: body, boundary: boundary, timeout: 900)
        return try JSONDecoder().decode(TranscriptionResult.self, from: data)
    }
    public func translate(text: String, from: String, to: String, requestID: UUID = UUID()) async throws -> TranslationResult {
        let boundary = "dictator-\(UUID().uuidString)"
        var body = multipart(["text": text, "language": from, "target_language": to, "request_id": requestID.uuidString], boundary: boundary)
        body.append(Data("--\(boundary)--\r\n".utf8))
        return try JSONDecoder().decode(TranslationResult.self, from: await cloud("/v1/translate", body: body, boundary: boundary, timeout: 150))
    }
    private func cloud(_ path: String, body: Data, boundary: String, timeout: Double) async throws -> Data {
        let (base, token) = try await cloudAccess()
        var request = URLRequest(url: endpoint(base, path))
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = timeout
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return try await perform(request).0
    }
    private func multipart(_ fields: [String: String], boundary: String) -> Data {
        var result = Data()
        for name in fields.keys.sorted() {
            result.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(fields[name]!)\r\n".utf8))
        }
        return result
    }
    public func stream(options: StreamOptions) async throws -> DictatorStream {
        let (base, token) = try await cloudAccess()
        var components = URLComponents(url: endpoint(base, "/v1/stream"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        let stream = DictatorStream(socket: session.webSocketTask(with: components.url!))
        try await stream.start(key: token, options: options)
        return stream
    }

    private func authenticate(_ path: String, body: [String: Any], headers: [String: String] = [:]) async throws -> AuthenticationResult {
        let (data, response) = try await control(path, method: "POST", body: JSONSerialization.data(withJSONObject: body), headers: headers)
        struct Reply: Decodable { let token: String?; let twoFactorRedirect: Bool? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if reply.twoFactorRedirect == true { return .requiresSecondFactor }
        guard let token = response.value(forHTTPHeaderField: "set-auth-token") else { throw DictatorError.invalidResponse }
        setSessionToken(token)
        return .signedIn
    }
    public func signIn(email: String, password: String) async throws -> AuthenticationResult {
        setSessionToken(nil); session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
        return try await authenticate("/api/auth/sign-in/email", body: ["email": email, "password": password])
    }
    public func verifyTOTP(_ code: String) async throws -> AuthenticationResult {
        try await authenticate("/api/auth/two-factor/verify-totp", body: ["code": code, "trustDevice": false])
    }
    public func requestSecondFactorOTP() async throws {
        _ = try await control("/api/auth/two-factor/send-otp", method: "POST", body: Data("{}".utf8))
    }
    public func verifyOTP(_ code: String) async throws -> AuthenticationResult {
        try await authenticate("/api/auth/two-factor/verify-otp", body: ["code": code, "trustDevice": false])
    }
    public func verifyBackupCode(_ code: String) async throws -> AuthenticationResult {
        try await authenticate("/api/auth/two-factor/verify-backup-code", body: ["code": code, "disableSession": false])
    }
    public func appleChallenge() async throws -> AppleChallenge {
        try JSONDecoder().decode(AppleChallenge.self, from: await control("/api/mobile/apple-challenge", method: "POST").0)
    }
    public func authenticateApple(identityToken: String, challenge: AppleChallenge, link: Bool = false) async throws -> AuthenticationResult {
        let body: [String: Any] = ["provider": "apple", "idToken": ["token": identityToken, "nonce": challenge.nonce]]
        if link {
            _ = try await control("/api/auth/link-social", method: "POST", body: JSONSerialization.data(withJSONObject: body), headers: ["x-apple-challenge": challenge.id])
            return .signedIn
        }
        setSessionToken(nil); session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
        return try await authenticate("/api/auth/sign-in/social", body: body, headers: ["x-apple-challenge": challenge.id])
    }
    public func signOut() async throws {
        defer { setSessionToken(nil); session.configuration.httpCookieStorage?.removeCookies(since: .distantPast) }
        _ = try await control("/api/auth/sign-out", method: "POST", body: Data("{}".utf8))
    }
}
