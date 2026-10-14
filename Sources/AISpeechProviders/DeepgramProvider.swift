import Foundation
import AIProvidersCore

public struct DeepgramProvider: AISpeechProviding {
    private let http: AIHTTP
    private let token: String
    private let endpoint: URL
    public init(endpoint: URL = URL(string: "https://api.deepgram.com/v1")!, token: String, http: AIHTTP = AIHTTP()) {
        self.endpoint = endpoint; self.token = token; self.http = http
    }
    private func query(_ options: AISpeechRequest, streaming: Bool) throws -> URLRequest {
        var request = try AIHTTP.request(AIEndpoint.url(endpoint, path: "listen"), token: token, method: streaming ? "GET" : "POST")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        var values = [URLQueryItem(name: "model", value: options.model), .init(name: "punctuate", value: "true"), .init(name: "smart_format", value: "true")]
        if options.language != "auto" { values.append(.init(name: "language", value: options.language)) }
        else if !streaming { values.append(.init(name: "detect_language", value: "true")) }
        else { throw AIProviderError.unsupported } // Nova streaming needs an explicit language.
        if streaming {
            url.scheme = "wss"
            values += [.init(name: "encoding", value: "linear16"), .init(name: "sample_rate", value: String(options.sampleRate)),
                       .init(name: "channels", value: "1"), .init(name: "interim_results", value: "true")]
        }
        url.queryItems = values; request.url = url.url
        return request
    }
    public func transcribe(_ audio: Data, request: AISpeechRequest) async throws -> String {
        var query = try query(request, streaming: false); query.httpBody = audio
        query.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let response = try await http.json(query)
        guard let results = response["results"] as? [String: Any], let channels = results["channels"] as? [[String: Any]],
              let alternative = (channels.first?["alternatives"] as? [[String: Any]])?.first,
              let text = alternative["transcript"] as? String else { throw AIProviderError.invalidResponse }
        return text
    }
    public func stream(_ request: AISpeechRequest) async throws -> any AISpeechStreaming {
        let socket = http.session.webSocketTask(with: try query(request, streaming: true))
        let stream = DeepgramStream(socket: socket, sampleRate: request.sampleRate, http: http)
        try await stream.start(); return stream
    }
}

public struct DeepgramEventParser {
    private var ids: [Int: UInt64] = [:]
    private let sampleRate: Int
    public init(sampleRate: Int) { self.sampleRate = sampleRate }
    public mutating func parse(_ data: Data, finishing: Bool) throws -> AISpeechEvent? {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIProviderError.invalidResponse }
        if value["type"] as? String == "Error" { throw AIProviderError.invalidResponse }
        if value["type"] as? String == "Metadata", finishing { return .completed }
        guard value["type"] as? String == "Results",
              let channel = value["channel"] as? [String: Any], let alternative = (channel["alternatives"] as? [[String: Any]])?.first,
              let text = alternative["transcript"] as? String else { return nil }
        guard text.count < 100_000 else { throw AIProviderError.outputLimit }
        if value["is_final"] as? Bool != true { return .partial(text) }
        guard !text.isEmpty else { return .partial("") }
        let start = max(0, Int((value["start"] as? Double ?? 0) * Double(sampleRate)))
        let duration = max(0, value["duration"] as? Double ?? 0)
        let id = ids[start] ?? UInt64(ids.count + 1); ids[start] = id
        return .final(.init(id: id, text: text, startSample: start, endSample: max(start + 1, start + Int(duration * Double(sampleRate)))))
    }
}

private actor DeepgramStream: AISpeechStreaming {
    nonisolated let events: AsyncThrowingStream<AISpeechEvent, Error>
    private let continuation: AsyncThrowingStream<AISpeechEvent, Error>.Continuation
    private let socket: URLSessionWebSocketTask
    private let http: AIHTTP
    private var reader: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var closing = false
    private var parser: DeepgramEventParser
    init(socket: URLSessionWebSocketTask, sampleRate: Int, http: AIHTTP) {
        let pair = AsyncThrowingStream<AISpeechEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        events = pair.stream; continuation = pair.continuation; self.socket = socket; parser = .init(sampleRate: sampleRate)
        self.http = http
    }
    func start() async throws {
        continuation.onTermination = { [weak self] _ in Task { await self?.cancel() } }
        socket.resume()
        do {
            let socket = socket
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    socket.sendPing { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
                }
            } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
        } catch { socket.cancel(with: .goingAway, reason: nil); throw error }
        let socket = socket, output = continuation
        reader = Task.detached { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let owner = self else { throw CancellationError() }
                    if try await owner.accept(message) { return }
                }
                throw CancellationError()
            } catch { output.finish(throwing: error); socket.cancel(with: .goingAway, reason: nil); await self?.cancel() }
        }
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)); try Task.checkCancellation(); try await self?.ping() }
                catch { return }
            }
        }
    }
    private func ping() async throws { if !closing { try await socket.send(.string("{\"type\":\"KeepAlive\"}")) } }
    private func accept(_ message: URLSessionWebSocketTask.Message) throws -> Bool {
        let data: Data
        switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: throw AIProviderError.invalidResponse }
        guard data.count < 1_048_576 else { throw AIProviderError.outputLimit }
        if let event = try parser.parse(data, finishing: closing) {
            if case .dropped = continuation.yield(event) { throw AIProviderError.outputLimit }
            if case .completed = event { continuation.finish(); keepalive?.cancel(); socket.cancel(with: .normalClosure, reason: nil); return true }
        }
        return false
    }
    deinit { reader?.cancel(); keepalive?.cancel(); socket.cancel(with: .goingAway, reason: nil) }
    func send(_ pcm16: Data) async throws { guard !closing else { throw AIProviderError.interrupted }; try await socket.send(.data(pcm16)) }
    func finish() async throws {
        guard !closing else { return }; closing = true; keepalive?.cancel()
        try await socket.send(.string("{\"type\":\"CloseStream\"}"))
    }
    func cancel() { reader?.cancel(); keepalive?.cancel(); socket.cancel(with: .goingAway, reason: nil); continuation.finish(throwing: CancellationError()) }
}
