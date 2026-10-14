import AuthenticationServices
import CryptoKit
import Foundation
import DictatorCore

/// The host supplies a presentation window; the package does not create an app UI.
@MainActor
public final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let client: DictatorClient
    private let anchor: ASPresentationAnchor
    private var completion: CheckedContinuation<String, Error>?
    private var controller: ASAuthorizationController?
    private var activeOperation: UUID?
    public init(client: DictatorClient, presentationAnchor: ASPresentationAnchor) {
        self.client = client; self.anchor = presentationAnchor
    }
    public func signIn(linkToExistingAccount: Bool = false) async throws -> AuthenticationResult {
        guard activeOperation == nil else { throw DictatorError.rejected(status: 409, message: "Apple sign-in already in progress") }
        let operation = UUID(); activeOperation = operation
        defer { activeOperation = nil }
        let challenge = try await client.appleChallenge()
        try Task.checkCancellation()
        let identityToken = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.email, .fullName]
                request.nonce = SHA256.hash(data: Data(challenge.nonce.utf8)).map { String(format: "%02x", $0) }.joined()
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self; controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: { Task { @MainActor [weak self] in
            if self?.activeOperation == operation { self?.finish(.failure(CancellationError())) }
        } }
        try Task.checkCancellation()
        return try await client.authenticateApple(identityToken: identityToken, challenge: challenge, link: linkToExistingAccount)
    }
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { anchor }
    public func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
            finish(.failure(DictatorError.invalidResponse)); return
        }
        finish(.success(token))
    }
    public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }
        finish(.failure(error))
    }
    private func finish(_ result: Result<String, Error>) {
        let callback = completion; completion = nil; controller = nil
        callback?.resume(with: result)
    }
}
