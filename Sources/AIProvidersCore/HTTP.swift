import Foundation

/// Timing metadata only: no URL, headers, credentials or response content.
public struct AINetworkMetrics: Sendable {
    public let reusedConnection: Bool
    public let networkProtocol: String
    public let dnsSeconds: Double
    public let connectSeconds: Double
    public let tlsSeconds: Double
    public let firstByteSeconds: Double
    public let totalSeconds: Double
    public init(_ transaction: URLSessionTaskTransactionMetrics) {
        func elapsed(_ start: Date?, _ end: Date?) -> Double {
            guard let start, let end else { return 0 }; return max(0, end.timeIntervalSince(start))
        }
        reusedConnection = transaction.isReusedConnection
        networkProtocol = transaction.networkProtocolName ?? "unknown"
        dnsSeconds = elapsed(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        connectSeconds = elapsed(transaction.connectStartDate, transaction.connectEndDate)
        tlsSeconds = elapsed(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        firstByteSeconds = elapsed(transaction.requestStartDate, transaction.responseStartDate)
        // A completed SSE response cancels the still-open HTTP task. Foundation
        // can omit responseEndDate for that transaction; collection time bounds it.
        totalSeconds = elapsed(transaction.fetchStartDate, transaction.responseEndDate ?? Date())
    }
}

/// No automatic inference retries, cookies, credential persistence or redirects.
public final class AIHTTP: @unchecked Sendable {
    public let session: URLSession
    private let ownsSession: Bool
    private final class Delegate: NSObject, URLSessionTaskDelegate {
        let onMetrics: (@Sendable (AINetworkMetrics) -> Void)?
        init(onMetrics: (@Sendable (AINetworkMetrics) -> Void)?) { self.onMetrics = onMetrics }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            for transaction in metrics.transactionMetrics { onMetrics?(AINetworkMetrics(transaction)) }
        }
    }
    public init(session: URLSession? = nil, onMetrics: (@Sendable (AINetworkMetrics) -> Void)? = nil) {
        ownsSession = session == nil
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 240
            self.session = URLSession(configuration: config, delegate: Delegate(onMetrics: onMetrics), delegateQueue: nil)
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
