# Changelog

## 0.11.0 — 2026-04-10

### Added

- **`-vvvv` adds ISO8601 µs-precision timestamps** to every log line
  (endpoint attach, monitor events, message traces). Useful for
  debugging time-sensitive reconnect and handshake races where
  untimestamped `-vvv` output makes every event look instantaneous.
  `-v`/`-vv`/`-vvv` are unchanged.

- **YJIT enabled by default in `exe/omq`.** `RubyVM::YJIT.enable` is
  called before loading the CLI. Skipped if `RUBYOPT` is set (so users
  who pass `--disable-yjit` or similar keep their choice), if the
  interpreter lacks YJIT, or if YJIT is already on.

### Changed

- **Universal default HWM is now 64** (was 100 for most sockets, 16
  for pipe). 64 matches the recv pump's per-fairness-batch limit
  (one batch exactly fills a full queue). Removed the special-case
  `PipeRunner::PIPE_HWM = 16` override — pipe sockets now use the
  same default as everything else, eliminating the documented-but-
  surprising cliff.

- **`pipe` no longer waits for peers unless `--timeout` is set.** The
  previous unconditional `Barrier { pull.peer_connected + push.peer_connected }`
  gate served no correctness purpose: `PULL#receive` blocks naturally
  when no source is connected, and `PUSH` buffers up to `send_hwm` when
  no sink is connected, so the loop can start immediately. Concretely,
  `omq pipe -c ipc://@src -b ipc://@sink` started without a sink now
  drains the source until both sides' HWMs are full (recv_queue +
  send_queue = 2 × HWM) instead of silently blocking at 1 × HWM in the
  recv pump while the worker loop sat idle at the wait. When
  `--timeout` *is* set, the wait is preserved as a fail-fast starting
  gate.

- **Event formatting consolidated into `OMQ::CLI::Term`** — a new
  stateless module (`module_function`) with `format_attach`,
  `format_event`, `write_attach`, `write_event`, and `log_prefix`.
  Replaces four duplicated copies across `BaseRunner`, `PipeRunner`,
  `ParallelWorker`, and `PipeWorker` that had drifted apart — pipe-
  mode event lines were missing the `-vvvv` timestamp prefix because
  `PipeRunner` had its own copy of the formatter.

## 0.10.0 — 2026-04-09

### Changed

- **`--send-hwm` / `--recv-hwm` collapsed into a single `--hwm N`** option.
  Outside pipe modal mode it sets both send and recv HWM on the socket.
  Inside pipe modal mode it follows the current `--in` / `--out` side:
  `--in --hwm N` sets the input PULL's recv HWM, `--out --hwm N` sets
  the output PUSH's send HWM. Breaking CLI change — scripts must update
  from `--send-hwm`/`--recv-hwm` to `--hwm` (with `--in`/`--out` if they
  need per-side values in pipe).

## 0.9.0 — 2026-04-08

### Changed

- **`--recv-maxsz` defaults to 1 MiB in the CLI** — the underlying `omq`
  library no longer imposes a default (it's `nil`/unlimited as of this
  release), but the CLI keeps a conservative 1 MiB cap for safety when
  connecting to untrusted peers from a terminal. Pass `--recv-maxsz 0`
  to disable the cap explicitly, or `--recv-maxsz N` to raise it.
- **Default HWM lowered to 100** (from libzmq's 1000) for both send and
  recv. The CLI is typically used interactively or for short pipelines
  where a smaller in-flight queue keeps memory bounded and surfaces
  backpressure earlier. Users who want the old behavior can pass
  `--send-hwm 1000 --recv-hwm 1000` (or `0` for unbounded). Pipe worker
  sockets are unaffected — they still override to `PIPE_HWM` internally.
- **Compression codec: Zstandard → LZ4 frame format (BREAKING on the wire).**
  `--compress` now uses the new [`rlz4`](../rlz4) gem (Rust extension over
  `lz4_flex`) instead of `zstd-ruby`. Motivation: `zstd-ruby` is the only
  existing Ractor-safe compressor gem, but LZ4 is a better fit for the
  per-message-part workload (smaller frames, lower CPU). `rlz4` is
  Ractor-safe by construction, so parallel `-P` workers now use the same
  codec as the sequential path. **Wire format is incompatible** with prior
  omq-cli versions when `--compress` is in use — both ends must upgrade.

### Added

- **`--ffi` flag** — opt-in libzmq backend for any socket runner. Builds
  sockets with `backend: :ffi`, so the CLI can drive native libzmq instead
  of the pure-Ruby engine. Requires the optional `omq-ffi` gem and a
  system libzmq 4.x; missing dependencies abort with a clear error.
  Propagated through all socket construction sites: `BaseRunner`,
  `PipeRunner`, `PipeWorker`, and `ParallelWorker`.

### Fixed

- **`--send-eval` / `-E` on REP** — now rejected at validation time. REP
  derives its reply from `--recv-eval` / `-e`, so `-E` was silently
  ignored and the runner fell through to reading stdin, hanging the
  request-reply cycle.
- **`-vvv` preview of REP/REQ envelopes** — empty delimiter frames now
  render as `[0B]` instead of an empty string, so a REP reply with wire
  parts `["", "1"]` previews as `(1B) [0B]|1` instead of the misleading
  `(1B) |1` with a dangling leading pipe.

## 0.8.2 — 2026-04-08

### Fixed

- **`DecompressError` handling** — decompression failures now raise a proper
  `DecompressError` instead of calling `abort`. In parallel mode (`-P`),
  errors are sent through a dedicated `Ractor::Port` with a consumer thread
  that aborts cleanly (exit code 1, one error message). Previously, `Async do`
  swallowed the exception and the process exited silently.
- **Pipe memory growth** — pipe sockets now pass `recv_hwm` / `send_hwm` via
  constructor kwargs so the engine captures them before internal queue sizing.
  Previously, setters were called after the engine was initialized and had no
  effect on staging queue capacity.

### Changed

- **`-P N` mandatory argument** — `-P` now requires an explicit worker count.
  Previously, `-Pq` silently consumed `-q` as the argument to `-P`, making
  `-q` (quiet) ineffective.
- **Pipe default HWM lowered to 16** — reduced from 64 to further bound memory
  with large messages in pipeline stages.

## 0.8.1 — 2026-04-08

### Fixed

- **Binary frame preview** — compressed or binary message frames now show
  `[NB]` instead of unreadable dot-filled strings in `-vvv` monitor output.
  Frames where less than half the sample bytes are printable ASCII are detected
  as binary.

## 0.8.0 — 2026-04-08

### Added

- **`-P` for pull, gather, and rep** — parallel Ractor workers for recv-only
  and request-reply socket types. Output serialized through `Ractor::Port`
  to avoid scrambled stdout.
- **`RactorHelpers` module** — shared Ractor infrastructure: `preresolve_tcp`,
  `start_log_consumer`, `start_output_consumer` with `SHUTDOWN` sentinel for
  clean consumer shutdown.
- **`ParallelWorker` class** — general Ractor worker for parallel socket modes.
- **Process titles** — all runners set descriptive `proctitle`
  (`omq TYPE [-z] [-PN] ENDPOINTS`). Pipe shows `omq pipe [-z] [-PN] IN -> OUT`.
  Bare script mode shows `omq script`.

### Changed

- **ASCII-only source** — replaced all Unicode special characters (em-dashes,
  box-drawing, arrows) with ASCII equivalents in lib/ and test/.
- **Pipe default HWM** — pipe sockets now default to HWM of 64 (instead of
  the socket default 1000) to bound memory with large messages in pipeline
  stages. Override with `--send-hwm` / `--recv-hwm`.
- **Message preview** — total byte count first, 12 chars per part, max 3 parts
  shown (`(1234B) frame1|frame2|frame3|...(5 parts)`).
- **`SocketSetup.apply_options`** — extracted shared socket option setup,
  used by `BaseRunner`, `PipeRunner`, `PipeWorker`, and `ParallelWorker`.
- **`Formatter.preview`** — extracted from duplicated `msg_preview` methods.
- **Pipe/PipeWorker** — use bare `.new` for sockets, `SocketSetup.apply_options`
  for configuration, `RactorHelpers` for Ractor infrastructure.

## 0.7.2 — 2026-04-07

### Changed

- **Cleaned up pipe.rb** — removed unused `@fmt` formatters, dead `log` method,
  and `with_timeout` wrapper. Moved `preresolve_tcp` and `start_log_consumer` to
  `PipeWorker` class methods.
- **Guard `with_timeout(nil)`** — `Fiber.scheduler.with_timeout(nil)` fires
  immediately in Async; peer-wait and pipe sequential mode now skip the timeout
  wrapper when `config.timeout` is nil.

## 0.7.1 — 2026-04-07

### Fixed

- **Pipe `-P` preresolves TCP hostnames** — DNS resolution happens on the
  main thread before spawning Ractors, avoiding `Ractor::IsolationError`
  on `Resolv::DefaultResolver`. All resolved addresses (IPv4 + IPv6) are
  passed to workers.

## 0.7.0 — 2026-04-07

### Changed

- **`-P` restricted to pipe only** — parallel Ractor workers are no longer
  available on recv-only socket types (pull, sub, gather, dish). Pipe workers
  now use bare Ractors with their own Async reactors and OMQ sockets, removing
  the `omq-ractor` dependency entirely.
- **`-P` range capped to 1..16** — default is still `nproc`, clamped to 16.
  `-P 1` is valid (single Ractor worker, no sockets on main thread).
- **Removed `omq-ractor` dependency** — no longer needed.
- **Removed `ParallelRecvRunner`** — the Ractor bridge infrastructure for
  non-pipe socket types has been deleted.

### Fixed

- **Pipe `-P` END blocks execute after timeout** — worker recv loops now
  catch `IO::TimeoutError` so BEGIN/END expressions run to completion.

## 0.6.0 — 2026-04-07

### Added

- **Modal `--compress` for pipe `--in`/`--out`** — `--compress` after `--in`
  decompresses input, after `--out` compresses output. Enables mixed pipelines
  like plain input → compressed output:
  `omq pipe --in -c src --out --compress -c dst`.
  Without `--in`/`--out`, `--compress` applies to both directions as before.

### Fixed

- **Abort with clear message on decompression failure** — receiving an
  uncompressed message with `--compress` now prints a hint instead of
  silently killing the Async task with exit code 0.

## 0.5.4 — 2026-04-07

### Fixed

- **Fix `--compress` crash** — `Zstd` constant was uninitialized because
  `zstd-ruby` was no longer required at startup. Now required when `-z` is parsed.
- **Fix `--msgpack` crash** — same issue. Now required when `--msgpack` is parsed.

## 0.5.3 — 2026-04-07

### Fixed

- **HTTPS debug endpoint uses localhost.rb** — `OMQ_DEBUG_URI=https://...` now
  uses `Localhost::Authority` for self-signed TLS, fixing "no shared cipher"
  errors when accessing the async-debug web UI in a browser.

## 0.5.2 — 2026-04-07

### Fixed

- **Guard async-debug behind `OMQ_DEV`** — the Gemfile still caused the
  openssl conflict on CI even after removing it from the gemspec.

## 0.5.1 — 2026-04-07

### Fixed

- **Move async-debug from runtime to dev dependency** — async-debug depends on
  `openssl >= 3.0` which conflicts with Ruby's default openssl gem on CI.
  Now only loaded when `OMQ_DEBUG_URI` is set, with a `LoadError` guard and
  install hint.

## 0.5.0 — 2026-04-07

### Changed

- **rbnacl, zstd-ruby, and msgpack are now fixed dependencies** —
  no more runtime detection or conditional test guards.
- **`--curve-crypto` renamed to `--crypto`** — applies to CURVE and future
  mechanisms (e.g. BLAKE3ZMQ). Env var renamed from `OMQ_CURVE_CRYPTO` to
  `OMQ_CRYPTO`.
- **CURVE requires system libsodium** — rbnacl is bundled but needs libsodium
  installed (`apt install libsodium-dev` / `brew install libsodium`). nuckle
  (pure Ruby) is available via `--crypto nuckle` but marked as DANGEROUS.

### Removed

- **`has_zstd` / `has_msgpack` config fields** — no longer needed since both
  gems are fixed dependencies.

## 0.4.0 — 2026-04-07

### Added

- **`--sndbuf` / `--rcvbuf` options** — set `SO_SNDBUF` and `SO_RCVBUF` kernel
  buffer sizes. Accepts plain bytes or suffixed values (`4K`, `1M`).
- **Pipe FIFO ordering system test** — verifies sequential source batches are
  never interleaved through a pipe.
- **Pipe producer-first system test** — verifies messages are delivered when
  the producer finishes before the consumer connects.

### Changed

- **Message traces moved to monitor events** — `-vvv` traces now use
  `Socket#monitor(verbose: true)` instead of inline `trace_send`/`trace_recv`
  calls, ensuring correct ordering with connection lifecycle events.

### Fixed

- **Test helper `make_config`** — added missing `send_hwm`, `recv_hwm`,
  `sndbuf`, `rcvbuf` fields and changed `verbose` default from `false` to `0`.

## 0.3.1 — 2026-04-07

### Added

- **`--send-hwm` / `--recv-hwm` options** — set send and receive high water
  marks from the command line (default 1000, 0 = unbounded).
- **`OMQ_DEBUG` env var** — starts async-debug web UI on
  `https://localhost:5050` (or custom port via `OMQ_DEBUG=PORT`).
- **Multi-level verbosity** — `-v` prints endpoints, `-vv` logs all
  connection events (connect/disconnect/retry/timeout) via socket monitor,
  `-vvv` also traces first 10 bytes of every sent/received message.

### Fixed

- **`omq pipe` slow reconnection** — sequential `peer_connected.wait` calls
  blocked receiving until both PULL and PUSH peers connected in order. Now
  waits concurrently using `Kernel#Barrier`.
- **`-i` on recv-only sockets** — `pull -i 0.2` rate-limits receiving to
  one message every 200 ms using `Async::Loop.quantized`. Works on all
  recv-only socket types (pull, sub, gather, dish).
- **`--send-eval` with `-i` and piped stdin** — `seq 5 | omq push -E '…' -i 1`
  ignored stdin and produced no output. `#read_next_or_nil` now reads
  stdin when available; `#send_tick` distinguishes generator mode (no
  stdin, eval only) from stdin-exhausted EOF.

## 0.3.0 — 2026-04-07

### Fixed

- **Fix broken Gemfile** — remove deleted `omq-draft`, add all RFC gems
  with `OMQ_DEV` path resolution.
- **Fix CURVE API calls** — `Curve.server` and `Curve.client` now use
  keyword arguments to match the updated protocol-zmtp API.
- **Replace `require "omq/draft/all"`** with explicit RFC requires
  (`omq/rfc/clientserver`, `radiodish`, `scattergather`, `channel`, `p2p`).

### Changed

- YARD documentation on all public methods and classes.
- Code style: two blank lines between methods and constants.

### Refactored

- **`req_rep.rb` + `pair.rb` method extraction** — `ReqRunner#run_loop` (23 lines)
  gains `wait_for_interval`; `RepRunner#run_loop` (27 lines) gains
  `handle_rep_request`; `PairRunner#run_loop` (20 lines) gains `recv_async`.
  Each `run_loop` shrinks to ~10 lines.

- **`BaseRunner` method extraction** — `call` (23 lines), `wait_for_peer` (18),
  `read_next` (20), `run_send_logic` (29), and `compile_expr` (13) each
  decomposed into focused helpers: `setup_socket`, `maybe_start_transient_monitor`,
  `run_begin_blocks`, `run_end_blocks`, `wait_for_subscriber`, `apply_grace_period`,
  `read_inline_data`, `read_stdin_input`, `run_interval_send`, `run_stdin_send`,
  `compile_evaluator`, `assign_send_aliases`, `assign_recv_aliases`.
  Every public-facing method is now ≤10 lines.

- **`RoutingHelper`: extract `async_send_loop`, `interval_send_loop`, `stdin_send_loop`** —
  the sender `task.async` block was identical in `RouterRunner#run_loop` and
  `ServerRunner#monitor_loop`. Moved to `RoutingHelper` and split into three
  focused helpers. Both callers reduced to a 3-line orchestration.
  `ServerRunner#reply_loop` gained `handle_server_request` to hold the 3-branch
  dispatch, leaving the loop itself at ~8 lines.

- **`pipe.rb` method extraction** — `run_sequential` (50 lines) and `run_parallel`
  (105 lines) decomposed into focused helpers: `build_pull_push`,
  `apply_socket_intervals`, `setup_sequential_transient`, `sequential_message_loop`,
  `build_socket_pairs`, `wait_for_pairs`, `setup_parallel_transient`,
  `build_worker_data`, `spawn_workers`, `join_workers`. Each caller shrinks to
  ~8 lines.

- **Hoist `eval_proc` + `Integer#times` in Ractor worker loops** — in both
  `ParallelRecvRunner` and `pipe.rb#spawn_workers`, `if eval_proc` was checked
  on every message despite being invariant. Now a pre-loop branch splits into
  two (or four, combined with `n_count`) separate loops. Count limits use
  `n.times` instead of a manual `i` counter, eliminating the `n && n > 0`
  check from every iteration.

- **`ExpressionEvaluator.normalize_result`** — the `case result when nil/Array/String/else`
  block appeared in both Ractor worker bodies (`ParallelRecvRunner` and `pipe.rb`).
  Extracted to a class method and both callers updated to use it.

- **Extract `ParallelRecvRunner`** — `BaseRunner#run_parallel_recv` (107 lines
  of Ractor worker management) moved into `OMQ::CLI::ParallelRecvRunner` in
  `lib/omq/cli/parallel_recv_runner.rb`. Constructor takes `klass, config, fmt,
  output_fn`; `BaseRunner#run_parallel_recv` becomes a 4-line delegator.
  `BaseRunner` shrinks from 426 to ~325 lines.

- **Extract `CliParser`** — `parse_options` (178 lines), `validate!` (48 lines),
  `validate_gems!`, `DEFAULT_OPTS`, and the `EXAMPLES` heredoc (184 lines) moved
  from the `OMQ::CLI` module into a dedicated `OMQ::CLI::CliParser` class in
  `lib/omq/cli/cli_parser.rb`. `CLI.build_config` now calls `CliParser.parse`
  and `CliParser.validate!`; `CLI.run_socket` calls `CliParser.validate_gems!`.
  `cli.rb` shrinks from 674 to ~200 lines.

- **`ReqRunner#run_loop` deduplication** — the interval and non-interval
  branches were identical loops; merged into one with a trailing
  `sleep(wait)` gated on `config.interval`.
- **Remove empty runner subclasses** — `DealerRunner`, `ChannelRunner`,
  `ClientRunner`, and `PeerRunner` were empty class bodies that added no
  behaviour. `RUNNER_MAP` now points directly at `PairRunner`, `ReqRunner`,
  and `ServerRunner` for those socket types. `channel.rb` and `peer.rb`
  deleted; empty bodies removed from `router_dealer.rb` and
  `client_server.rb`.
- **Extract `TransientMonitor`** — `start_disconnect_monitor`,
  `transient_ready!`, and `@transient_barrier` removed from `BaseRunner`
  into `OMQ::CLI::TransientMonitor`. `BaseRunner` holds a single
  `@transient_monitor` collaborator; `transient_ready!` delegates to
  `monitor.ready!`.
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
