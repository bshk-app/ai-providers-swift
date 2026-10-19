# AI Providers for Swift

Reusable Foundation clients for macOS 14+ and iOS 18+, plus an optional SwiftUI model browser.
The shared contracts have no Murmator, SwiftUI, MLX, microphone capture, shell, or agent runtime dependency.
The macOS sign-in helper uses AppKit and Network only when its auth product is imported.

A standalone package for `bshk-app/ai-providers-swift`. Import only the
SwiftPM products required by your application.

## Products

| Product | Responsibility |
| --- | --- |
| AIProvidersCore | Connection identity, model kind, operation capabilities, HTTP and provider contracts |
| AIProvidersAuth | App-scoped Keychain, ChatGPT registration/PKCE, verified ID tokens, refresh, macOS loopback sign-in |
| AITextProviders | OpenAI Responses (BYOK or ChatGPT plan), Anthropic Messages, OpenRouter / Featherless / generic Chat Completions (BYOK) |
| AISpeechProviders | Deepgram Nova WebSocket/file ASR, OpenAI file ASR (BYOK) |
| AIProviderViews | Optional searchable model sheet, debounce, paging, cancellation, English/Russian resources |
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

## Compatible providers and large catalogs

`CompatibleTextProvider(endpoint:service:http:credential:)` uses `/chat/completions`,
not OpenAI Responses. Select `.featherless`, `.openRouter`, or `.generic` for a
self-hosted/OpenAI-compatible endpoint. Model IDs are not restricted to GPT/o
names; explicit input/output modalities exclude non-text models. Incomplete,
refused and empty output is rejected rather than used as a correction.

`AIModelCatalogProviding.modelPage(query:cursor:)` returns an `AIModelPage` with
models, the next opaque cursor and an optional total. Its `models()` convenience
returns only the initial page. Featherless searches remotely in 100-model pages;
OpenRouter returns a complete catalog and filters by ID/name. Apps can cache the
smaller catalog in memory. Do not treat a first page as the entire catalog or
persist tens of thousands of models in preferences.

`verifyConnection()` checks Featherless `/plan` and OpenRouter `/key` separately
because their model catalogs can be public. Generic compatible endpoints expose
no universal authenticated probe; listing their models does not verify a key.

`AIProviderViews.AIModelBrowser` is an optional SwiftUI sheet. Inject a paged search
closure and explicit `onSelect`/`onCancel`. It owns no credentials or provider
settings and never selects a model automatically. Search is debounced, obsolete
answers are ignored, and the current model remains pinned above the results.

Dictator accepts a gateway base or a pasted documented operation URL via
`canonicalEndpoint`. `checkConnection()` makes one authenticated batch request
with a valid zero-duration WAV, no microphone/user audio or temporary key.
It validates batch access, not recognition quality, streaming or translation.

Contracts: [Featherless models](https://featherless.ai/docs/api-reference-models),
[Featherless Chat Completions](https://featherless.ai/docs/completions),
[Featherless plan](https://featherless.ai/docs/api-reference-plan),
[OpenRouter models](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties),
[OpenRouter key](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key).

## Request diagnostics

`AITextRequest` optionally accepts `requestID` and an `onProgress` callback.
Numeric events report credentials ready (including refresh waits), HTTP response
headers/status, first actual output text and completion. Times are cumulative,
monotonic seconds since `generate()` began. Token usage is optional and only
reported when present in the provider's response. Non-streaming providers report
first output after their complete JSON response is available.

`AINetworkMetrics.requestID` correlates DNS/connect/TLS/first-byte/total timing
with text requests. Correlation uses a task delegate; no trace header is sent to
the server. Other requests such as shared authentication refreshes can remain
unscoped. Connect includes TLS; first-byte time starts at requestStartDate, so
these intervals must not simply be added. Server queue/compute time cannot be
separated without provider-supplied telemetry.

No diagnostic event contains a prompt, model output, URL, header or credential.
The SDK neither logs nor stores these events; the application owns the callback.

## Per-model reasoning and server routing

`AISelection.options` optionally persists `AITextOptions` for one operation and
model. Old saved selections and catalogs still decode without options. Pass the
captured options into `AITextRequest`; changing preferences must affect the next
recording, not an in-flight correction or translation.

OpenRouter catalog reasoning metadata becomes `AIModel.reasoning`: use
`availableEfforts` for an effort picker and `fastestEffort` for an explicit fast
preset. Mandatory reasoning excludes `none`. Unknown model metadata does not
justify guessing an effort from its name or silently disabling reasoning.

```swift
let options = AITextOptions(
    reasoningEffort: .low,
    routing: .init(sort: .latency, only: ["groq"], allowFallbacks: false))
let text = try await router.generate(.init(
    model: modelID, instructions: instructions, text: transcript, options: options))
```

OpenRouter receives `reasoning.effort`, `reasoning.exclude`, and `provider`
preferences. Explicit effort requires parameter support, avoiding silent drops.
Direct compatible servers receive `reasoning_effort`; OpenAI Responses receives
`reasoning.effort` and explicit effort overrides the existing interactive preset.
Routing preferences on non-OpenRouter services are rejected before credential
reads. Anthropic does not expose this normalized control in this version.
No inference retry or implicit paid provider/model fallback is introduced.
