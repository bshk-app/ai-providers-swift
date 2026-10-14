The original PROVENANCE.json describes the imported dictator-saas 0.1.0 snapshot.
It does not describe local changes made after extraction.

Local extension: `DictatorClient.init(gatewayURL:apiKey:session:)` supplies the
user's key directly to the gateway. `cloudAccess()` returns that key without
calling mobile capabilities, login, or temporary-key issuance. The original
account/session initializer remains for the existing separately selected mobile
account integration. Parent package tests cover direct-key routing and refusal
without retries. The shared parent package exposes these sources exactly once.
