# Changes

## 0.2.1

- Add opt-in, metadata-only text request phase events and optional token usage.
- Correlate request-specific network metrics locally without trace headers.
- Retain cancellation, response limits and redirect refusal in traced transports.

## 0.2.0

- Add separate Featherless, OpenRouter and generic OpenAI-compatible Chat Completions clients; keep all compatible vendor model IDs and capability metadata.
- Add paginated Featherless server search, context/availability metadata and authenticated account checks distinct from public catalogs.
- Add optional AIProviderViews SwiftUI model browser with debouncing, paging, retry, stable current selection and generation-safe cancellation, localized in English and Russian.
- Accept canonical Dictator Base URLs or pasted operation URLs and verify BYOK access with a zero-duration WAV request.

## 0.1.2

- Read Responses streams from raw AsyncBytes, preserving blank SSE frame boundaries omitted by Foundation.lines.
- Preserve UTF-8 across byte boundaries, CR/LF/CRLF and BOM handling.
- Test full HTTP/SSE consumption, late quota failure and truncated response, rather than only isolated parser events.

## 0.1.1

- Cancel Deepgram connection establishment immediately with the owning task.
- Release WebSocket transports when their consumer is discarded.
- Disable redirects in the standalone Dictator BYOK initializer.

## 0.1.0

Initial shared text, speech, service and authentication clients for Apple platforms.
