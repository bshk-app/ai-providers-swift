# Dictator Swift SDK

Swift Package for iOS 16+ and macOS 13+. `DictatorCore` uses URLSession and
async/await for cloud transcription, ordered dictation events, translation and
the existing web-purchased organization balance. `DictatorAppleAuth` adds native
Apple identity and Keychain storage. There are no purchase or checkout APIs.

For a local integration, add `.package(path: "/path/to/dictator-saas/packages/swift-sdk")`
and the `DictatorCore` / `DictatorAppleAuth` products to the host app's target.
The app's existing recorder supplies audio files or PCM16 little-endian mono
16 kHz frames. It does not need to bundle any cloud model weights.

```swift
import DictatorCore
import DictatorAppleAuth

let client = try DictatorClient(controlURL: URL(string: "https://dictator.bshk.app")!)
let credentials = StoredAuthentication(client: client,
    store: KeychainSessionStore(service: "dictator.bshk.app"))
try await credentials.restore()
let account = try await client.account()
let capabilities = try await client.capabilities()
let result = try await client.transcribe(audio: audioData,
    options: .init(language: "ru", tier: .quality, targetLanguage: "en"))
// Render result.text even when result.translationError is present.
let translated = try await client.translate(text: "Добрый день", from: "ru", to: "en")
```

## Authentication

Use `credentials.signIn(email:password:)` to sign in to the existing web account.
If it returns `.requiresSecondFactor`, call `credentials.verifyTOTP(code)`;
only the completed signed session enters Keychain. No email is sent by these
SDK methods. `verifyOTP` and `verifyBackupCode` also support the existing second
factors. Only an explicit `client.requestSecondFactorOTP()` asks the service to
send its email code; this is never triggered automatically. Registration remains
invitation-only.

To link Apple, sign in to the existing account first, then create
`AppleSignIn(client:presentationAnchor:)` on the main actor and call
`signIn(linkToExistingAccount: true)`. For subsequent sign-ins, use `signIn()`
and pass its result to `credentials.saveIfSignedIn`. Handle the same second-factor
state. Apple private relay email does not create or merge a second account.
The host app must enable its Sign in with Apple capability; the server's exact
Bundle ID audience allowlist must include the host.

Use `client.organizations()` and `client.selectOrganization(id)` when the account
belongs to multiple organizations. Selection invalidates the cached cloud key;
already-running operations retain their original organization.

```swift
let stream = try await client.stream(options:
    .init(language: "ru", targetLanguage: "en", readyTimeoutSeconds: 240))
let receiver = Task {
    for try await event in stream.events {
        // .partial is never translated; .translation references a .final segment.
        // .translationError leaves the original .final text intact.
        consume(event)
    }
}
try await stream.sendAudio(pcm16Data)
try await stream.stop() // Keep receiving until .done.
try await receiver.value
await stream.close()
```

`stream` returns after protocol readiness or fails at its deadline. `stop`
finalizes audio; `close` abandons the connection. Cancellation stops waiting,
but cannot undo work already accepted by the server. Paid calls are never
automatically retried. Each text translation carries one operation UUID;
reusing it is refused before another model execution.

Rates, supported pairs and limits come from `capabilities`. Unset tariffs are
unavailable, while an explicit zero is free/included. Fees use Unicode code
points rather than UTF-16 units. Audio-attached translation is one reservation
even when split internally into up to 16 model chunks: any failed chunk releases
the entire translation quote. The input limit is per model chunk; standalone
text requests are bounded to one chunk. Original audio is billed independently.

## Verification and later mobile billing

Run `swift test --package-path packages/swift-sdk` from the monorepo root.
The sample under Examples consumes the existing balance without presenting a
purchase action. SDK HTTP fixtures and WebSocket protocol tests do not spend
cloud credits or start GPU workers. A real-device Apple authorization still
requires the host app's Apple capability and configured backend audience.

Future native purchases will use an optional RevenueCat module and the same
Autumn customer ID. They will not change the Core API or create a second wallet.
App Store release eligibility for a web-service companion must be assessed by
the host app; the SDK does not guarantee App Review acceptance.
