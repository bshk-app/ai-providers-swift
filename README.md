# AI Providers for Swift

Reusable Foundation clients for macOS 14+ and iOS 18+. No Murmator, SwiftUI,
MLX, microphone capture, shell, or agent runtime dependency in the shared contracts.
The macOS sign-in helper uses AppKit and Network only when its auth product is imported.

A standalone package for `bshk-app/ai-providers-swift`. Import only the
SwiftPM products required by your application.

## Products

| Product | Responsibility |
| --- | --- |
| AIProvidersCore | Connection identity, model kind, operation capabilities, HTTP and provider contracts |
| AIProvidersAuth | App-scoped Keychain, ChatGPT registration/PKCE, verified ID tokens, refresh, macOS loopback sign-in |
| AITextProviders | OpenAI Responses (BYOK or ChatGPT plan), Anthropic Messages (BYOK) |
| AISpeechProviders | Deepgram Nova WebSocket/file ASR, OpenAI file ASR (BYOK) |
| AIServiceProviders | Dictator BYOK ASR, streaming and text translation |
| DictatorCore | Canonical Dictator service client; direct API key or separately selected legacy account mode |
| DictatorAppleAuth | Optional legacy account/Apple sign-in helpers |

Apps import only the products they need. Provider is not model: an API connection
contains a provider identifier, endpoint, auth route and unique account/key identity.
`AISelection` binds a stage to a connection and model. Dictator `fast/hybrid/quality`
are server profiles, not concrete neural model IDs. Catalog visibility does not
prove account entitlement or successful inference.

```swift
import AIProvidersCore
import AITextProviders

let editor = OpenAITextProvider(credential: { try vault.token(connectionID) })
let models = try await editor.models()
let text = try await editor.generate(.init(
    model: selectedModelID,
    instructions: correctionInstructions,
    text: finalTranscript))
```

The same client can be used behind Tishina's language-model adapter. Inject the
application's own credential vault; sharing library code does not grant access
to another application's credentials. UI, microphone capture and transcript
validation remain caller responsibilities.

## Completion and authentication

- OpenAI plan inference uses public Responses, `store:false`, `stream:true`,
  developer instructions and the account's catalog. Audio is BYOK only.
- Dynamic ChatGPT registration uses the app's own name/host ID, fresh state,
  nonce and PKCE. ID-token RS256 signature/JWKS, issuer, audience, expiration,
  nonce and identity are validated before saving tokens. No imported Codex
  identity or private Codex credential files are used.
- macOS provides system-browser/loopback sign-in. A mobile sign-in callback has
  not been implemented; iOS supports BYOK. Paid/hosted distribution eligibility
  must follow the current OpenAI registration requirements.
- Claude subscription login is not offered. Anthropic uses the user's API key.
- A partial Responses stream is rejected without `response.completed`, including
  quota/error events received after text deltas. Native HTTP never retries an
  inference request automatically. Error bodies and credentials are not logged.
- Deepgram completes after user `CloseStream` and final metadata; model speech
  boundaries never trigger application insertion. Dictator requires `done`.
- Translation access depends on Dictator's server policy. No Dictator LLM
  correction endpoint is claimed by this client.

## Verification

`swift test` from this repository. Tests use fake credentials and HTTP/WebSocket
fixtures. Live account access, quotas, latency and recognition quality require
separate user-authorized qualification. No user audio is included in this package.

Official contracts used: [OpenAI plan inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
[OpenAI registration](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
[Deepgram CloseStream](https://developers.deepgram.com/docs/close-stream).
