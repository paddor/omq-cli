# Changelog

## Unreleased

### Refactored

- **Extract `RoutingHelper` module** — `display_routing_id`, `resolve_target`,
  and a `send_targeted_or_eval` template method (calling a `send_to_peer` hook)
  extracted from `RouterRunner` and `ServerRunner` into a shared module.
  `display_routing_id` and `resolve_target` removed from `BaseRunner`, which
  never used them directly.
- **Extract `SocketSetup`** — socket construction (`SocketSetup.build`),
  endpoint attachment (`SocketSetup.attach` for URL lists,
  `SocketSetup.attach_endpoints` for `Endpoint` objects), subscription/group
  setup (`SocketSetup.setup_subscriptions`), and CURVE configuration
  (`SocketSetup.setup_curve`) extracted from `BaseRunner` into a stateless
  module. `PipeRunner#attach_endpoints` now delegates to the shared module.
- **Extract `ExpressionEvaluator`** — expression compilation (`extract_block`,
  `extract_blocks`, BEGIN/END parsing, proc wrapping) and result normalisation
  live in `OMQ::CLI::ExpressionEvaluator`. Removes duplicate code from
  `BaseRunner`, `PipeRunner`, and both Ractor worker blocks. A shared
  `ExpressionEvaluator.compile_inside_ractor` class method replaces the
  identical inline parse lambdas that previously appeared in each Ractor block.

### Added (OMQ::Ractor integration)

- **`-P` extended to recv-only socket types** (`pull`, `sub`, `gather`,
  `dish`) when combined with `--recv-eval`. Each worker gets its own
  socket connecting to the external endpoint; ZMQ distributes work
  naturally. Results are collected via an inproc PULL back to main for
  output. Requires all endpoints to use `--connect`.
- **`omq-ractor` dependency** — `OMQ::Ractor` is now used for all
  parallel worker management.

### Changed

- **`pipe -P` rewritten using `OMQ::Ractor`** — workers no longer
  create their own Async reactor internally. Sockets are created and
  peer-waited in the main Async context, then passed to
  `OMQ::Ractor.new`; worker blocks contain only pure computation.
  Semantics are unchanged.

### Fixed

- **`-P` recv-only: stale round-robin entry** — the initial socket
  created by `call()` was connecting to the upstream endpoint before
  `run_parallel_recv` closed it, leaving a dead entry in the PUSH
  peer's round-robin cycle and silently dropping 1 in every N+1
  messages. Fixed by skipping `attach_endpoints` when `config.parallel`
  is set.
- **`-P` BEGIN/END blocks in Ractor workers** — `@ivar` expressions in
  BEGIN/END/eval blocks raised `Ractor::IsolationError` because `self`
  inside a Ractor is a shareable object. All three procs now execute via
  `instance_exec` on a per-worker `Object.new` context.
- **`-P` END block result forwarded** — the return value of an END block
  was discarded rather than forwarded to the output socket. Now captured
  and pushed to `push_p`, enabling patterns like
  `BEGIN{@s=0} @s+=Integer($F.first);nil END{[@s.to_s]}` to emit once
  per worker on exit.

---

### Added

- **`-r` defers loading to inside the Async reactor** — scripts now run
  within the event loop and may use async APIs, OMQ sockets, etc.
- **Bare script mode (`omq -r FILE`)** — omitting the socket type runs the
  script directly inside `Async{}` with free reign. The `OMQ` module is
  included into the top-level namespace so scripts can write `PUSH.new`
  instead of `OMQ::PUSH.new`.
- **`-r -` / `-r-`** — reads and evals the script from stdin, useful for
  quick copy-paste invocations. Cannot be combined with `-F -`.
- **`--recv-maxsz COUNT`** — sets the ZMQ `max_message_size` socket option;
  the socket discards incoming messages exceeding `COUNT` bytes and drops
  the peer connection before allocation.

### Fixed

- `Protocol::ZMTP::Codec::Frame` was referenced as bare `ZMTP::Codec::Frame`
  in the formatter (`--raw` format). Fixed the constant path.

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
