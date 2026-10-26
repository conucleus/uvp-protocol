# @uvp-eth/canonical-json

Canonical JSON serialization and evidence hashing primitives. This package is
the single implementation of both facts:

- `canonicalize` / `canonicalJson` / `compareByCodePoint`: code-point key order,
  integer-only number vocabulary (float, `-0`, and integers beyond `2^53-1`
  are rejected loudly), stable UTF-8 output.
- `hashCanonicalJson`: `keccak256` of the canonical JSON bytes.
- `hashEvidenceBytes` / `hashEvidenceText` / `hashEvidenceJson`: evidence hash
  results (`algorithm`/`byteLength`/`source`) over bytes, UTF-8 text, and
  canonical JSON.

The cross-language authority corpus is
`uvp-core/fixtures/canonical/canonical.v1.json`; `compiler`, `protocol-bindings`,
`chain-services`, `uvp-client`, and `uvp-deploy` consume this package instead of
carrying their own canonicalizer. Domain-separated hashes (for example
`hashResourceManifest`) stay with the domain owner and only reuse
`canonicalJson`.
