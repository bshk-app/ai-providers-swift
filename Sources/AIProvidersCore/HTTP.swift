import Foundation

/// No automatic inference retries, cookies, credential persistence or redirects.
public final class AIHTTP: @unchecked Sendable {
    public let session: URLSession
    private let ownsSession: Bool
    private final class Delegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    public init(session: URLSession? = nil) {
        ownsSession = session == nil
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 240
            self.session = URLSession(configuration: config, delegate: Delegate(), delegateQueue: nil)
        }
    }
    public static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw AIProviderError.refused(response.statusCode) }
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }
    public func data(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Self.check(response); try Task.checkCancellation()
        guard data.count < 8 * 1024 * 1024 else { throw AIProviderError.outputLimit }
        return data
    }
    public func json(_ request: URLRequest) async throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: await data(request)) as? [String: Any] else { throw AIProviderError.invalidResponse }
        return value
    }
    public static func request(_ url: URL, token: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        try AIEndpoint.validate(url)
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw AIProviderError.missingCredential }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
}
