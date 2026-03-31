# Changelog

## 0.2.0 — 2026-03-31

### Added

- **`omq keygen`** — generates a persistent CURVE keypair (Z85-encoded
  env vars). Supports `--curve-crypto rbnacl|nuckle` and the
  `OMQ_CURVE_CRYPTO` env var.
- **`--curve-crypto BACKEND`** — explicit crypto backend selection for
  CURVE encryption. Defaults to rbnacl if installed; no silent fallback
  to nuckle.
- **`-v` logs crypto backend** — `omq keygen -v` and socket commands
  with `-v` log which CURVE backend was loaded.

### Changed

- **CURVE uses protocol-zmtp** — replaces the old omq-curve gem with
  `Protocol::ZMTP::Mechanism::Curve` and a pluggable `crypto:` backend.
- **`load_curve_crypto` is a CLI module method** — shared between
  `omq keygen` and socket runners.

## 0.1.0 — 2026-03-31

Initial release — CLI extracted from the omq gem (v0.8.0).
