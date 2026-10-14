import Foundation
import Security
import XCTest
import AIProvidersAuth
import AIProvidersCore

final class ChatGPTVerificationTests: XCTestCase {
    private func encoded(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private func http() -> AIHTTP {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTP.self]
        return AIHTTP(session: URLSession(configuration: config))
    }
    private func fixture(nonce: String, audience: String = "issued-client", corrupt: Bool = false) throws -> (String, [String: String]) {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var offset = 1
        func length() -> Int {
            let byte = Int(der[offset]); offset += 1
            if byte < 128 { return byte }
            var count = 0
            for _ in 0..<(byte & 127) { count = count * 256 + Int(der[offset]); offset += 1 }
            return count
        }
        _ = length()
        func integer() -> Data {
            XCTAssertEqual(der[offset], 2); offset += 1
            let count = length(); var data = der.subdata(in: offset..<offset + count); offset += count
            if data.first == 0 { data.removeFirst() }; return data
        }
        let modulus = integer(), exponent = integer()
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-signing-key"])
        let body = try JSONSerialization.data(withJSONObject: ["iss": "https://auth.openai.com", "aud": audience,
            "exp": Date().timeIntervalSince1970 + 300, "sub": "verified-user", "nonce": nonce, "email": "test@example.invalid"])
        let input = encoded(header) + "." + encoded(body)
        var signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)) as Data
        if corrupt { signature[0] ^= 1 }
        return (input + "." + encoded(signature), ["kid": "test-signing-key", "kty": "RSA", "n": encoded(modulus), "e": encoded(exponent)])
    }
    private func run(audience: String = "issued-client", nonceOverride: String? = nil, corrupt: Bool = false) async throws -> ChatGPTSession {
        let auth = try ChatGPTAuthorization(hostID: "test-host", appName: "Test App", callback: URL(string: "http://127.0.0.1:43210/auth/callback")!)
        let (jwt, jwk) = try fixture(nonce: nonceOverride ?? auth.nonce, audience: audience, corrupt: corrupt)
        MockHTTP.handle = { request in
            let object: [String: Any]
            switch request.url!.path {
            case "/api/accounts/oauth/token": object = ["access_token": "test-access", "refresh_token": "test-refresh", "id_token": jwt, "token_type": "Bearer", "expires_in": 3600, "scope": "openid chatgpt.tokens.use.direct"]
            case "/.well-known/openid-configuration": object = ["issuer": "https://auth.openai.com", "jwks_uri": "https://auth.openai.com/test-jwks"]
            case "/test-jwks": object = ["keys": [jwk]]
            default: XCTFail("Unexpected authentication endpoint"); object = [:]
            }
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        let callback = URL(string: "http://127.0.0.1:43210/auth/callback?state=\(auth.state)&code=test-code&client_id=issued-client")!
        return try await auth.exchange(callback, http: http())
    }
    func testValidSignedIdentityEstablishesSession() async throws {
        let session = try await run()
        XCTAssertEqual(session.subject, "verified-user"); XCTAssertEqual(session.clientID, "issued-client")
        XCTAssertTrue(session.scopes.contains("chatgpt.tokens.use.direct"))
    }
    func testWrongAudienceIsRejected() async throws { do { _ = try await run(audience: "different-app"); XCTFail() } catch {} }
    func testWrongNonceIsRejected() async throws { do { _ = try await run(nonceOverride: "different-attempt"); XCTFail() } catch {} }
    func testTamperedSignatureIsRejected() async throws { do { _ = try await run(corrupt: true); XCTFail() } catch {} }
}
