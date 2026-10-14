# Changes

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
