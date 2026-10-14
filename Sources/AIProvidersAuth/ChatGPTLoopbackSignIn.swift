#if os(macOS)
import Foundation
import AppKit
import Network
import AIProvidersCore

/// The system browser handles account credentials. This listener accepts only
/// the exact loopback callback; state/nonce/JWKS checks happen before persistence.
@MainActor public final class ChatGPTLoopbackSignIn {
    private var listener: NWListener?
    private var timeout: Task<Void, Never>?
    private var pending: CheckedContinuation<URL, Error>?
    private var authorization: ChatGPTAuthorization?
    public init() {}
    public func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<URL, Error>) {
        listener?.cancel(); listener = nil; timeout?.cancel(); timeout = nil
        if case .failure = result { authorization = nil }
        let continuation = pending; pending = nil; continuation?.resume(with: result)
    }
    public func authorize(hostID: String, appName: String, existing: ChatGPTSession? = nil) async throws -> ChatGPTSession {
        guard pending == nil else { throw AIProviderError.invalidResponse }
        authorization = nil
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        let returned = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                pending = continuation
                server.stateUpdateHandler = { [weak self, weak server] state in Task { @MainActor in
                    guard let self, self.pending != nil else { return }
                    if case .ready = state {
                        do {
                            guard let port = server?.port else { throw AIProviderError.invalidResponse }
                            let callback = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                            let auth = try ChatGPTAuthorization(hostID: hostID, appName: appName, callback: callback, existing: existing)
                            self.authorization = auth
                            guard NSWorkspace.shared.open(auth.url) else { throw AIProviderError.invalidResponse }
                        } catch { self.finish(.failure(error)) }
                    } else if case .failed = state { self.finish(.failure(AIProviderError.interrupted)) }
                } }
                server.newConnectionHandler = { [weak self] connection in Task { @MainActor in
                    guard let self else { connection.cancel(); return }; connection.start(queue: .main); self.receive(connection, bytes: Data())
                } }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)); try Task.checkCancellation() } catch { return }
                    self?.finish(.failure(AIProviderError.interrupted))
                }
                server.start(queue: .main)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        guard let auth = authorization else { throw AIProviderError.invalidResponse }; authorization = nil
        let session = try await auth.exchange(returned)
        guard existing == nil || existing?.subject == session.subject else { throw AIProviderError.missingCredential }
        return session
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in Task { @MainActor in
            guard let self, let auth = self.authorization, self.pending != nil else { connection.cancel(); return }
            let buffer = bytes + (data ?? Data())
            guard error == nil, buffer.count <= 8192 else { connection.cancel(); return }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, bytes: buffer) }; return
            }
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/auth/callback?"),
                  let url = URL(string: "http://127.0.0.1:\(auth.callback.port!)" + parts[1]),
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value == auth.state else { connection.cancel(); return }
            let body = "Authorization received. You can return to the app."
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            self.finish(.success(url))
        } }
    }
}
#endif
