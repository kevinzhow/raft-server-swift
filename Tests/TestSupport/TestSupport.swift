// Test-only seams for the production types, kept out of `Sources/`.
//
// Seams are implemented as `extension EmailLoginDirectory` / `extension OAuthLedger`
// members written against `@testable import RaftHTTP`, with the same names and
// signatures the tests already call. No production target may depend on this
// module; it needs a debug build (`-enable-testing`), like the test targets.
