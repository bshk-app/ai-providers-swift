import Foundation

protocol StreamTransport: Sendable {
    func resume() async
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel() async
}
final class WebSocketTransport: StreamTransport, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(_ task: URLSessionWebSocketTask) { self.task = task }
    func resume() async { task.resume() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func cancel() async { task.cancel(with: .normalClosure, reason: nil) }
}

public actor DictatorStream {
    public nonisolated let events: AsyncThrowingStream<StreamEvent, Error>
    private let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    private let socket: any StreamTransport
    private var reader: Task<Void, Never>?
    private var ready = false
    private var closed = false
    private var failure: Error?

    init(socket: URLSessionWebSocketTask) {
        self.init(transport: WebSocketTransport(socket))
    }
    init(transport: any StreamTransport) {
        self.socket = transport
        var output: AsyncThrowingStream<StreamEvent, Error>.Continuation!
        events = AsyncThrowingStream(bufferingPolicy: .unbounded) { output = $0 }
        continuation = output
    }
    func start(key: String, options: StreamOptions) async throws {
        await socket.resume()
        var frame = ["op": "start", "api_key": key, "language": options.language, "tier": options.tier.rawValue.lowercased()]
        if let target = options.targetLanguage { frame["target_language"] = target }
        do {
            try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: frame), as: UTF8.self)))
            reader = Task { [weak self] in await self?.receive() }
            let deadline = Date().addingTimeInterval(max(1, min(options.readyTimeoutSeconds, 300)))
            while !ready {
                try Task.checkCancellation()
                if let failure { throw failure }
                if closed { throw DictatorError.connectionClosed }
                if Date() >= deadline { throw DictatorError.readinessTimeout }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            continuation.onTermination = { [weak self] _ in Task { await self?.close() } }
        } catch { await close(); throw error }
    }
    private func receive() async {
        do {
            while !closed {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: throw DictatorError.invalidResponse
                }
                let event = try JSONDecoder().decode(StreamEvent.self, from: data)
                if event.type == .ready { ready = true }
                if event.type == .error && !ready { throw DictatorError.rejected(status: event.code ?? 503, message: event.detail ?? "Stream refused") }
                continuation.yield(event)
                if event.type == .done { await close(); return }
            }
        } catch {
            failure = error
            if !closed { continuation.finish(throwing: error); await close() }
        }
    }
    public func sendAudio(_ pcm16: Data) async throws {
        guard ready && !closed else { throw DictatorError.notReady }
        guard pcm16.count % 2 == 0 && pcm16.count <= 1024 * 1024 else { throw DictatorError.invalidAudio }
        try await socket.send(.data(pcm16))
    }
    public func stop() async throws {
        guard ready && !closed else { throw DictatorError.notReady }
        try await socket.send(.string("{\"op\":\"stop\"}"))
    }
    public func close() async {
        guard !closed else { return }
        closed = true; reader?.cancel(); await socket.cancel()
        continuation.finish()
    }
}
