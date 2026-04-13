# omq — ZeroMQ CLI

[![Gem Version](https://img.shields.io/gem/v/omq-cli?color=e9573f)](https://rubygems.org/gems/omq-cli)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%203.3-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)

Command-line tool for sending and receiving ZeroMQ messages on any socket type.
Like `nngcat` from libnng, but with Ruby eval, Ractor parallelism, and message handlers.

Built on [omq](https://github.com/zeromq/omq) — pure Ruby ZeroMQ, no C dependencies.

## Install

```sh
gem install omq-cli
```

## Quick Start

```sh
# Echo server
omq rep -b tcp://:5555 --echo

# Client
echo "hello" | omq req -c tcp://localhost:5555

# Upcase server — -e evals Ruby on each incoming message
omq rep -b tcp://:5555 -e 'it.map(&:upcase)'
```

```
Usage: omq TYPE [options]

Types:    req, rep, pub, sub, push, pull, pair, dealer, router
Draft:    client, server, radio, dish, scatter, gather, channel, peer
Virtual:  pipe (PULL → eval → PUSH)
```

## Connection

Every socket needs at least one `--bind` or `--connect`:

```sh
omq pull --bind tcp://:5557          # listen on port 5557
omq push --connect tcp://host:5557   # connect to host
omq pull -b ipc:///tmp/feed.sock     # IPC (unix socket)
omq push -c@work                     # IPC abstract namespace (@name → ipc://@name)
```

Multiple endpoints are allowed — `omq pull -b tcp://:5557 -b tcp://:5558` binds both.
Pipe takes two positional endpoints (input, output) or uses `--in`/`--out` for multiple per side.

## Socket types

### Unidirectional (send-only / recv-only)

| Send | Recv | Pattern |
|------|------|---------|
| `push` | `pull` | Pipeline — round-robin to workers |
| `pub` | `sub` | Publish/subscribe — fan-out with topic filtering |
| `scatter` | `gather` | Pipeline (draft, single-frame only) |
| `radio` | `dish` | Group messaging (draft, single-frame only) |

Send-only sockets read from stdin (or `--data`/`--file`) and send. Recv-only sockets receive and write to stdout.

```sh
echo "task" | omq push -c tcp://worker:5557
omq pull -b tcp://:5557
```

### Bidirectional (request-reply)

| Type | Behavior |
|------|----------|
| `req` | Sends a request, waits for reply, prints reply |
| `rep` | Receives request, sends reply (from `--echo`, `-e`, `--data`, `--file`, or stdin) |
| `client` | Like `req` (draft, single-frame) |
| `server` | Like `rep` (draft, single-frame, routing-ID aware) |

```sh
# echo server
omq rep -b tcp://:5555 --echo

# upcase server
omq rep -b tcp://:5555 -e 'it.map(&:upcase)'

# client
echo "hello" | omq req -c tcp://localhost:5555
```

### Bidirectional (concurrent send + recv)

| Type | Behavior |
|------|----------|
| `pair` | Exclusive 1-to-1 — concurrent send and recv tasks |
| `dealer` | Like `pair` but round-robin send to multiple peers |
| `channel` | Like `pair` (draft, single-frame) |

These spawn two concurrent tasks: a receiver (prints incoming) and a sender (reads stdin).
`-e` transforms incoming, `-E` transforms outgoing.

### Routing sockets

| Type | Behavior |
|------|----------|
| `router` | Receives with peer identity prepended; sends to peer by identity |
| `server` | Like `router` but draft, single-frame, uses routing IDs |
| `peer` | Like `server` (draft, single-frame) |

```sh
# monitor mode — just print what arrives
omq router -b tcp://:5555

# reply to specific peer
omq router -b tcp://:5555 --target worker-1 -D "reply"

# dynamic routing via send-eval (first element = identity)
omq router -b tcp://:5555 -E '["worker-1", it.first.upcase]'
```

`--target` and `--send-eval` are mutually exclusive on routing sockets.

### Pipe (virtual)

Pipe creates an internal PULL → eval → PUSH pipeline:

```sh
omq pipe -c@work -c@sink -e 'it.map(&:upcase)'

# with Ractor workers for CPU parallelism (-P0 = nproc)
omq pipe -c@work -c@sink -P0 -r./fib.rb -e 'fib(Integer(it.first)).to_s'
```

The first endpoint is the pull-side (input), the second is the push-side (output).
Both must use `-c`.

## Eval: -e and -E

`-e` (alias `--recv-eval`) runs a Ruby expression for each **incoming** message.
`-E` (alias `--send-eval`) runs a Ruby expression for each **outgoing** message.

### Variables

| Variable | Value |
|----------|-------|
| `it` | Message parts (`Array<String>`) — Ruby's default block variable |

### Block parameters

Expressions support Ruby block parameter syntax. A single parameter receives
the whole parts array; use `|(a, b)|` to destructure:

```sh
# single param = parts array
omq pull -b tcp://:5557 -e '|msg| msg.map(&:upcase)'

# destructure multipart messages
omq pull -b tcp://:5557 -e '|(key, value)| "#{key}=#{value}"'
```

### Return value

| Return | Effect |
|--------|--------|
| `Array` | Used as the message parts |
| `String` | Wrapped in `[result]` |
| `nil` | Message is skipped (filtered) |
| `self` (the socket) | Signals "I already sent" (REP only) |

### Control flow

```sh
# skip messages matching a pattern
omq pull -b tcp://:5557 -e 'next if it.first.start_with?("#"); it'

# stop on "quit"
omq pull -b tcp://:5557 -e 'break if it.first == "quit"; it'
```

### BEGIN/END blocks

Like awk — `BEGIN{}` runs once before the message loop, `END{}` runs after:

```sh
omq pull -b tcp://:5557 -e 'BEGIN{ @sum = 0 } @sum += Integer(it.first); next END{ puts @sum }'
```

Local variables won't work to share state between the blocks. Use `@ivars` instead.

### Which sockets accept which flag

| Socket | `-E` (send) | `-e` (recv) |
|--------|-------------|-------------|
| push, pub, scatter, radio | transforms outgoing | error |
| pull, sub, gather, dish | error | transforms incoming |
| req, client | transforms request | transforms reply |
| rep, server (reply mode) | error | transforms request → return = reply |
| pair, dealer, channel | transforms outgoing | transforms incoming |
| router, server, peer (monitor) | routes outgoing (first element = identity) | transforms incoming |
| pipe | error | transforms in pipeline |

### Examples

```sh
# upcase echo server
omq rep -b tcp://:5555 -e 'it.map(&:upcase)'

# transform before sending
echo hello | omq push -c tcp://localhost:5557 -E 'it.map(&:upcase)'

# filter incoming
omq pull -b tcp://:5557 -e 'it.first.include?("error") ? it : nil'

# REQ: different transforms per direction
echo hello | omq req -c tcp://localhost:5555 \
  -E 'it.map(&:upcase)' -e 'it.map(&:reverse)'

# generate messages without stdin
omq pub -c tcp://localhost:5556 -E 'Time.now.to_s' -i 1

# use gems
omq sub -c tcp://localhost:5556 -s "" -rjson -e 'JSON.parse(it.first)["temperature"]'
```

## Script handlers (-r)

For non-trivial transforms, put the logic in a Ruby file and load it with `-r`:

```ruby
# handler.rb
db = PG.connect("dbname=app")

OMQ.outgoing { |msg| msg.map(&:upcase) }
OMQ.incoming { |msg| db.exec(msg.first).values.flatten }

at_exit { db.close }
```

```sh
omq req -c tcp://localhost:5555 -r./handler.rb
```

### Registration API

| Method | Effect |
|--------|--------|
| `OMQ.outgoing { \|msg\| ... }` | Register outgoing message transform |
| `OMQ.incoming { \|msg\| ... }` | Register incoming message transform |

- use explicit block variable (like `msg`) or `it`
- Setup: use local variables and closures at the top of the script
- Teardown: use Ruby's `at_exit { ... }`
- CLI flags (`-e`/`-E`) override script-registered handlers for the same direction
- A script can register one direction while the CLI handles the other:

```sh
# handler.rb registers recv_eval, CLI adds send_eval
omq req -c tcp://localhost:5555 -r./handler.rb -E 'it.map(&:upcase)'
```

### Script handler examples

```ruby
# count.rb — count messages, print total on exit
count = 0
OMQ.incoming { |msg| count += 1; msg }
at_exit { $stderr.puts "processed #{count} messages" }
```

```ruby
# json_transform.rb — parse JSON, extract field
require "json"
OMQ.incoming { |first_part, _| [JSON.parse(first_part)["value"]] }
```

```ruby
# rate_limit.rb — skip messages arriving too fast
last = 0

OMQ.incoming do |msg|
  now = Async::Clock.now # monotonic clock

  if now - last >= 0.1
    last = now
    msg
  end
end
```

```ruby
# enrich.rb — add timestamp to outgoing messages
OMQ.outgoing { |msg| [*msg, Time.now.iso8601] }
```

## Data sources

| Flag | Behavior |
|------|----------|
| (stdin) | Read lines from stdin, one message per line |
| `-D "text"` | Send literal string (one-shot or repeated with `-i`) |
| `-F file` | Read message from file (`-F -` reads stdin as blob) |
| `--echo` | Echo received messages back (REP only) |

`-D` and `-F` are mutually exclusive.

## Formats

| Flag | Format |
|------|--------|
| `-A` / `--ascii` | Tab-separated frames, non-printable → dots (default) |
| `-Q` / `--quoted` | C-style escapes, lossless round-trip |
| `--raw` | Raw ZMTP binary (pipe to `hexdump -C` for debugging) |
| `-J` / `--jsonl` | JSON Lines — `["frame1","frame2"]` per line |
| `--msgpack` | MessagePack arrays (binary stream) |
| `-M` / `--marshal` | Ruby Marshal (binary stream of `Array<String>` objects) |

Multipart messages: in ASCII/quoted mode, frames are tab-separated. In JSONL mode,
each message is a JSON array.

```sh
# send multipart via tabs
printf "key\tvalue" | omq push -c tcp://localhost:5557

# JSONL
echo '["key","value"]' | omq push -c tcp://localhost:5557 -J
omq pull -b tcp://:5557 -J
```

## Timing

| Flag | Effect |
|------|--------|
| `-i SECS` | Repeat send every N seconds (wall-clock aligned) |
| `-n COUNT` | Max messages to send/receive (0 = unlimited) |
| `-d SECS` | Delay before first send |
| `-t SECS` | Send/receive timeout |
| `-l SECS` | Linger time on close (default 5s) |
| `--reconnect-ivl` | Reconnect interval: `SECS` or `MIN..MAX` (default 0.1) |
| `--heartbeat-ivl SECS` | ZMTP heartbeat interval (detects dead peers) |

```sh
# publish a tick every second, 10 times
omq pub -c tcp://localhost:5556 -D "tick" -i 1 -n 10 -d 1

# receive with 5s timeout
omq pull -b tcp://:5557 -t 5
```

## Compression

Set `--compress` (`-z`) on either or both sides. The flag enables
ZMTP-Zstd (provided by `omq-rfc-zstd`), a wire-protocol extension
that negotiates Zstandard compression during the ZMTP handshake via
an `X-Compression` READY metadata field. If both peers advertise it,
each side compresses its outgoing frames; if only one side does, the
connection stays plaintext (no error). The extension uses the
auto-trained dictionary mode: the sender feeds the first messages
into a dictionary trainer, ships the trained dictionary over a
ZDICT command frame, then switches to dict-bound compression for
the rest of the connection.

```sh
omq push -c tcp://remote:5557 -z < data.txt
omq pull -b tcp://:5557 -z
```

## Key generation

Generate a persistent CURVE keypair:

```sh
omq keygen
# OMQ_SERVER_PUBLIC='...'
# OMQ_SERVER_SECRET='...'

omq keygen --crypto nuckle   # pure Ruby backend (DANGEROUS — not audited)
```

Export the vars, then use `--curve-server` (server) or `--curve-server-key` (client).

## CURVE encryption

End-to-end encryption using CurveZMQ. Requires system libsodium:

```sh
apt install libsodium-dev    # Debian/Ubuntu
brew install libsodium       # macOS
```

To use nuckle (pure Ruby, DANGEROUS — not audited) instead:

```sh
omq rep -b tcp://:5555 --echo --curve-server --crypto nuckle
# or: OMQ_CRYPTO=nuckle omq rep -b tcp://:5555 --echo --curve-server
```

```sh
# server (prints OMQ_SERVER_KEY=...)
omq rep -b tcp://:5555 --echo --curve-server

# client (paste the key)
echo "secret" | omq req -c tcp://localhost:5555 \
  --curve-server-key '<key from server>'
```

Persistent keys via env vars: `OMQ_SERVER_PUBLIC` + `OMQ_SERVER_SECRET` (server), `OMQ_SERVER_KEY` (client).

## Subscription and groups

```sh
# subscribe to topic prefix
omq sub -b tcp://:5556 -s "weather."

# subscribe to all (default)
omq sub -b tcp://:5556

# multiple subscriptions
omq sub -b tcp://:5556 -s "weather." -s "sports."

# RADIO/DISH groups
omq dish -b tcp://:5557 -j "weather" -j "sports"
omq radio -c tcp://localhost:5557 -g "weather" -D "72F"
```

## Identity and routing

```sh
# DEALER with identity
echo "hello" | omq dealer -c tcp://localhost:5555 --identity worker-1

# ROUTER receives identity + message as tab-separated
omq router -b tcp://:5555

# ROUTER sends to specific peer
omq router -b tcp://:5555 --target worker-1 -D "reply"

# ROUTER dynamic routing via -E (first element = routing identity)
omq router -b tcp://:5555 -E '["worker-1", it.first.upcase]'

# binary routing IDs (0x prefix)
omq router -b tcp://:5555 --target 0xdeadbeef -D "reply"
```

## Pipe

Pipe creates an in-process PULL → eval → PUSH pipeline:

```sh
# basic pipe (positional: first = input, second = output)
omq pipe -c@work -c@sink -e 'it.map(&:upcase)'

# parallel Ractor workers (-P0 = nproc, also combinable: -P0zvv)
omq pipe -c@work -c@sink -P0 -r./fib.rb -e 'fib(Integer(it.first)).to_s'

# fixed number of workers
omq pipe -c@work -c@sink -P4 -e 'it.map(&:upcase)'

# exit when producer disconnects
omq pipe -c@work -c@sink --transient -e 'it.map(&:upcase)'
```

### Multi-peer pipe with `--in`/`--out`

Use `--in` and `--out` to attach multiple endpoints per side. These are modal switches — subsequent
`-b`/`-c` flags attach to the current side:

```sh
# fan-in: 2 producers → 1 consumer
omq pipe --in -c@work1 -c@work2 --out -c@sink -e 'it'

# fan-out: 1 producer → 2 consumers (round-robin)
omq pipe --in -b tcp://:5555 --out -c@sink1 -c@sink2 -e 'it'

# bind on input, connect on output
omq pipe --in -b tcp://:5555 -b tcp://:5556 --out -c tcp://sink:5557 -e 'it'

# parallel workers with fan-in (all must be -c)
omq pipe --in -c@a -c@b --out -c@sink -P4 -e 'it'
```

`-P`/`--parallel` requires all endpoints to be `--connect`. In parallel mode, each Ractor worker
gets its own PULL/PUSH pair connecting to all endpoints.

## Transient mode

`--transient` makes the socket exit when all peers disconnect. Useful for pipeline workers and sinks:

```sh
# worker exits when producer is done
omq pipe -c@work -c@sink --transient -e 'it.map(&:upcase)'

# sink exits when all workers disconnect
omq pull -b tcp://:5557 --transient
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (connection, argument, runtime) |
| 2 | Timeout |
| 3 | Eval error (`-e`/`-E` expression raised) |

## License

[ISC](LICENSE)
