# frozen_string_literal: true

module OMQ
  module CLI
    # Parses and validates command-line arguments for the omq CLI.
    #
    class CliParser
      EXAMPLES = <<~'TEXT'
        -- Request / Reply ------------------------------------------

          +-----+  "hello"    +-----+
          | REQ |------------->| REP |
          |     |<-------------|     |
          +-----+  "HELLO"    +-----+

          # terminal 1: echo server
          omq rep --bind tcp://:5555 --recv-eval '$F.map(&:upcase)'

          # terminal 2: send a request
          echo "hello" | omq req --connect tcp://localhost:5555

          # or over IPC (unix socket, single machine)
          omq rep --bind ipc:///tmp/echo.sock --echo &
          echo "hello" | omq req --connect ipc:///tmp/echo.sock

        -- Publish / Subscribe --------------------------------------

          +-----+  "weather.nyc 72F"  +-----+
          | PUB |--------------------->| SUB | --subscribe "weather."
          +-----+                     +-----+

          # terminal 1: subscriber (all topics by default)
          omq sub --bind tcp://:5556

          # terminal 2: publisher (needs --delay for subscription to propagate)
          echo "weather.nyc 72F" | omq pub --connect tcp://localhost:5556 --delay 1

        -- Periodic Publish -------------------------------------------

          +-----+  "tick 1"    +-----+
          | PUB |--(every 1s)-->| SUB |
          +-----+              +-----+

          # terminal 1: subscriber
          omq sub --bind tcp://:5556

          # terminal 2: publish a tick every second (wall-clock aligned)
          omq pub --connect tcp://localhost:5556 --delay 1 \
            --data "tick" --interval 1

          # 5 ticks, then exit
          omq pub --connect tcp://localhost:5556 --delay 1 \
            --data "tick" --interval 1 --count 5

        -- Pipeline -------------------------------------------------

          +------+           +------+
          | PUSH |----------->| PULL |
          +------+           +------+

          # terminal 1: worker
          omq pull --bind tcp://:5557

          # terminal 2: send tasks
          echo "task 1" | omq push --connect tcp://localhost:5557

          # or over IPC (unix socket)
          omq pull --bind ipc:///tmp/pipeline.sock &
          echo "task 1" | omq push --connect ipc:///tmp/pipeline.sock

        -- Pipe (PULL -> eval -> PUSH) --------------------------------

          +------+         +------+         +------+
          | PUSH |--------->| pipe |--------->| PULL |
          +------+         +------+         +------+

          # terminal 1: producer
          echo -e "hello\nworld" | omq push --bind ipc://@work

          # terminal 2: worker -- uppercase each message
          omq pipe -c ipc://@work -c ipc://@sink -e '$F.map(&:upcase)'
          # terminal 3: collector
          omq pull --bind ipc://@sink

          # 4 Ractor workers in a single process (-P)
          omq pipe -c ipc://@work -c ipc://@sink -P4 -r./fib -e 'fib(Integer($_)).to_s'

          # exit when producer disconnects (--transient)
          omq pipe -c ipc://@work -c ipc://@sink --transient -e '$F.map(&:upcase)'

          # fan-in: multiple sources -> one sink
          omq pipe --in -c ipc://@work1 -c ipc://@work2 \
            --out -c ipc://@sink -e '$F.map(&:upcase)'

          # fan-out: one source -> multiple sinks (round-robin)
          omq pipe --in -b tcp://:5555 --out -c ipc://@sink1 -c ipc://@sink2 -e '$F'

        -- CLIENT / SERVER (draft) ----------------------------------

          +--------+  "hello"   +--------+
          | CLIENT |------------>| SERVER | --recv-eval '$F.map(&:upcase)'
          |        |<------------|        |
          +--------+  "HELLO"   +--------+

          # terminal 1: upcasing server
          omq server --bind tcp://:5555 --recv-eval '$F.map(&:upcase)'

          # terminal 2: client
          echo "hello" | omq client --connect tcp://localhost:5555

        -- Formats --------------------------------------------------

          # ascii (default) -- non-printable replaced with dots
          omq pull --bind tcp://:5557 --ascii

          # quoted -- lossless, round-trippable (uses String#dump escaping)
          omq pull --bind tcp://:5557 --quoted

          # JSON Lines -- structured, multipart as arrays
          echo '["key","value"]' | omq push --connect tcp://localhost:5557 --jsonl
          omq pull --bind tcp://:5557 --jsonl

          # multipart via tabs
          printf "routing-key\tpayload" | omq push --connect tcp://localhost:5557

        -- Compression ----------------------------------------------

          # both sides must use --compress
          omq pull --bind tcp://:5557 --compress &
          echo "compressible data" | omq push --connect tcp://localhost:5557 --compress

        -- CURVE Encryption -----------------------------------------

          # server (prints OMQ_SERVER_KEY=...)
          omq rep --bind tcp://:5555 --echo --curve-server

          # client (paste the server's key)
          echo "secret" | omq req --connect tcp://localhost:5555 \
            --curve-server-key '<key from server>'

        -- ROUTER / DEALER ------------------------------------------

          +--------+          +--------+
          | DEALER |---------->| ROUTER |
          | id=w1  |          |        |
          +--------+          +--------+

          # terminal 1: router shows identity + message
          omq router --bind tcp://:5555

          # terminal 2: dealer with identity
          echo "hello" | omq dealer --connect tcp://localhost:5555 --identity worker-1

        -- Ruby Eval ------------------------------------------------

          # filter incoming: only pass messages containing "error"
          omq pull -b tcp://:5557 --recv-eval '$F.first.include?("error") ? $F : nil'

          # transform incoming with gems
          omq sub -c tcp://localhost:5556 -rjson -e 'JSON.parse($F.first)["temperature"]'

          # require a local file, use its methods
          omq rep --bind tcp://:5555 --require ./transform.rb -e 'upcase_all($F)'

          # next skips, break stops -- regexps match against $_
          omq pull -b tcp://:5557 -e 'next if /^#/; break if /quit/; $F'

          # BEGIN/END blocks (like awk) -- accumulate and summarize
          omq pull -b tcp://:5557 -e 'BEGIN{@sum = 0} @sum += Integer($_); nil END{puts @sum}'

          # transform outgoing messages
          echo hello | omq push -c tcp://localhost:5557 --send-eval '$F.map(&:upcase)'

          # REQ: transform request and reply independently
          echo hello | omq req -c tcp://localhost:5555 -E '$F.map(&:upcase)' -e '$_'

        -- Script Handlers (-r) ------------------------------------

          # handler.rb -- register transforms from a file
          #   db = PG.connect("dbname=app")
          #   OMQ.incoming { |first_part, _| db.exec(first_part).values.flatten }
          #   at_exit { db.close }
          omq pull --bind tcp://:5557 -r./handler.rb

          # combine script handlers with inline eval
          omq req -c tcp://localhost:5555 -r./handler.rb -E '$F.map(&:upcase)'

          # OMQ.outgoing { |msg| ... }   -- registered outgoing transform
          # OMQ.incoming { |msg| ... }   -- registered incoming transform
          # CLI flags (-e/-E) override registered handlers
      TEXT


      DEFAULT_OPTS = {
        type_name:        nil,
        endpoints:        [],
        connects:         [],
        binds:            [],
        in_endpoints:     [],
        out_endpoints:    [],
        data:             nil,
        file:             nil,
        format:           :ascii,
        subscribes:       [],
        joins:            [],
        group:            nil,
        identity:         nil,
        target:           nil,
        interval:         nil,
        count:            nil,
        delay:            nil,
        timeout:          nil,
        linger:           5,
        reconnect_ivl:    nil,
        heartbeat_ivl:    nil,
        send_hwm:         nil,
        recv_hwm:         nil,
        sndbuf:           nil,
        rcvbuf:           nil,
        conflate:         false,
        compress:         false,
        compress_in:      false,
        compress_out:     false,
        send_expr:        nil,
        recv_expr:        nil,
        parallel:         nil,
        transient:        false,
        verbose:          0,
        quiet:            false,
        echo:             false,
        scripts:          [],
        recv_maxsz:       nil,
        curve_server:     false,
        curve_server_key: nil,
        crypto:     nil,
        ffi:              false,
      }.freeze


      # Parses +argv+ and returns a mutable options hash.
      #
      def self.parse(argv)
        new.parse(argv)
      end


      # Validates option combinations, aborting on bad combos.
      #
      def self.validate!(opts)
        new.validate!(opts)
      end


      # Validates option combinations that depend on socket type.
      #
      def self.validate_gems!(config)
        if config.recv_only? && (config.data || config.file)
          abort "--data/--file not valid for #{config.type_name} (receive-only)"
        end
      end


      # Parses +argv+ and returns a mutable options hash.
      #
      # @param argv [Array<String>] command-line arguments (mutated in place)
      # @return [Hash] parsed options
      def parse(argv)
        opts      = DEFAULT_OPTS.transform_values { |v| v.is_a?(Array) ? v.dup : v }
        pipe_side = nil  # nil = legacy positional mode; :in/:out = modal

        parser = OptionParser.new do |o|
          o.banner = "Usage: omq TYPE [options]\n\n" \
                     "Types:    req, rep, pub, sub, push, pull, pair, dealer, router\n" \
                     "Draft:    client, server, radio, dish, scatter, gather, channel, peer\n" \
                     "Virtual:  pipe (PULL -> eval -> PUSH)\n\n"

          o.separator "Connection:"
          o.on("-c", "--connect URL", "Connect to endpoint (repeatable)") { |v|
            ep = Endpoint.new(v, false)
            case pipe_side
            when :in
              opts[:in_endpoints] << ep
            when :out
              opts[:out_endpoints] << ep
            else
              opts[:endpoints] << ep
              opts[:connects]  << v
            end
          }
          o.on("-b", "--bind URL", "Bind to endpoint (repeatable)") { |v|
            ep = Endpoint.new(v, true)
            case pipe_side
            when :in
              opts[:in_endpoints] << ep
            when :out
              opts[:out_endpoints] << ep
            else
              opts[:endpoints] << ep
              opts[:binds]     << v
            end
          }
          o.on("--in",  "Pipe: subsequent -b/-c attach to input (PULL) side")  { pipe_side = :in }
          o.on("--out", "Pipe: subsequent -b/-c attach to output (PUSH) side") { pipe_side = :out }

          o.separator "\nData source (REP: reply source):"
          o.on(      "--echo",        "Echo received messages back (REP)")   { opts[:echo] = true }
          o.on("-D", "--data DATA",   "Message data (literal string)")      { |v| opts[:data] = v }
          o.on("-F", "--file FILE",   "Read message from file (- = stdin)") { |v| opts[:file] = v }

          o.separator "\nFormat (input + output):"
          o.on("-A", "--ascii",   "Tab-separated frames, safe ASCII (default)") { opts[:format] = :ascii }
          o.on("-Q", "--quoted",  "C-style quoted with escapes")                { opts[:format] = :quoted }
          o.on(      "--raw",     "Raw binary, no framing")                     { opts[:format] = :raw }
          o.on("-J", "--jsonl",   "JSON Lines (array of strings per line)")     { opts[:format] = :jsonl }
          o.on(      "--msgpack",  "MessagePack arrays (binary stream)")         { require "msgpack"; opts[:format] = :msgpack }
          o.on("-M", "--marshal", "Ruby Marshal stream (binary, Array<String>)") { opts[:format] = :marshal }

          o.separator "\nSubscription/groups:"
          o.on("-s", "--subscribe PREFIX", "Subscribe prefix (SUB, default all)")     { |v| opts[:subscribes] << v }
          o.on("-j", "--join GROUP",       "Join group (repeatable, DISH only)")      { |v| opts[:joins] << v }
          o.on("-g", "--group GROUP",      "Publish group (RADIO only)")              { |v| opts[:group] = v }

          o.separator "\nIdentity/routing:"
          o.on("--identity ID", "Set socket identity (DEALER/ROUTER)")                     { |v| opts[:identity] = v }
          o.on("--target ID",   "Target peer (ROUTER/SERVER/PEER, 0x prefix for binary)")  { |v| opts[:target] = v }

          o.separator "\nTiming:"
          o.on("-i", "--interval SECS", Float,   "Repeat interval")                   { |v| opts[:interval] = v }
          o.on("-n", "--count COUNT",   Integer,  "Max iterations (0=inf)")            { |v| opts[:count] = v }
          o.on("-d", "--delay SECS",    Float,   "Delay before first send")            { |v| opts[:delay] = v }
          o.on("-t", "--timeout SECS",  Float,   "Send/receive timeout")               { |v| opts[:timeout] = v }
          o.on("-l", "--linger SECS",   Float,   "Drain time on close (default 5)")   { |v| opts[:linger] = v }
          o.on("--reconnect-ivl IVL", "Reconnect interval: SECS or MIN..MAX (default 0.1)") { |v|
            opts[:reconnect_ivl] = if v.include?("..")
                                     lo, hi = v.split("..", 2)
                                     Float(lo)..Float(hi)
                                   else
                                     Float(v)
                                   end
          }
          o.on("--heartbeat-ivl SECS", Float, "ZMTP heartbeat interval (detects dead peers)") { |v| opts[:heartbeat_ivl] = v }
          o.on("--recv-maxsz SIZE", "Max inbound message size, e.g. 4096, 64K, 1M, 2G (default 1M, 0=unlimited; larger messages drop the connection)") { |v| opts[:recv_maxsz] = parse_byte_size(v) }
          o.on("--hwm N", Integer, "High water mark (default 64, 0=unbounded; modal with --in/--out)") do |v|
            case pipe_side
            when :in
              opts[:recv_hwm] = v
            when :out
              opts[:send_hwm] = v
            else
              opts[:send_hwm] = v
              opts[:recv_hwm] = v
            end
          end
          o.on("--sndbuf N", "SO_SNDBUF kernel buffer size (e.g. 4K, 1M)") { |v| opts[:sndbuf] = parse_byte_size(v) }
          o.on("--rcvbuf N", "SO_RCVBUF kernel buffer size (e.g. 4K, 1M)") { |v| opts[:rcvbuf] = parse_byte_size(v) }

          o.separator "\nDelivery:"
          o.on("--conflate", "Keep only last message per subscriber (PUB/RADIO)") { opts[:conflate] = true }

          o.separator "\nCompression:"
          o.on("-z", "--compress", "LZ4 compression per frame (modal with --in/--out)") do
            require "rlz4"
            case pipe_side
            when :in
              opts[:compress_in] = true
            when :out
              opts[:compress_out] = true
            else
              opts[:compress] = true
            end
          end

          o.separator "\nProcessing (-e = incoming, -E = outgoing):"
          o.on("-e", "--recv-eval EXPR", "Eval Ruby for each incoming message ($F = parts)") { |v| opts[:recv_expr] = v }
          o.on("-E", "--send-eval EXPR", "Eval Ruby for each outgoing message ($F = parts)") { |v| opts[:send_expr] = v }
          o.on("-r", "--require LIB",  "Require lib/file in Async context; use '-' for stdin. Scripts can register OMQ.outgoing/incoming") { |v|
            require "omq" unless defined?(OMQ::VERSION)
            opts[:scripts] << (v == "-" ? :stdin : (v.start_with?("./", "../") ? File.expand_path(v) : v))
          }
          o.on("-P", "--parallel N", Integer, "Parallel Ractor workers (max 16)") { |v|
            opts[:parallel] = [v, 16].min
          }

          o.separator "\nCURVE encryption (requires system libsodium):"
          o.on("--curve-server",         "Enable CURVE as server (generates keypair)") { opts[:curve_server] = true }
          o.on("--curve-server-key KEY", "Enable CURVE as client (server's Z85 public key)") { |v| opts[:curve_server_key] = v }
          o.on("--crypto BACKEND", "Crypto backend: rbnacl (default) or nuckle (pure Ruby, DANGEROUS)") { |v| opts[:crypto] = v }
          o.separator "  Install libsodium: apt install libsodium-dev / brew install libsodium"
          o.separator "  Env vars: OMQ_SERVER_KEY (client), OMQ_SERVER_PUBLIC + OMQ_SERVER_SECRET (server)"
          o.separator "            OMQ_CRYPTO (backend: rbnacl or nuckle)"

          o.separator "\nOther:"
          o.on("-v", "--verbose",   "Verbosity: -v endpoints, -vv events, -vvv messages, -vvvv timestamps") { opts[:verbose] += 1 }
          o.on("-q", "--quiet",     "Suppress message output")           { opts[:quiet] = true }
          o.on(      "--transient", "Exit when all peers disconnect")    { opts[:transient] = true }
          o.on(      "--ffi",       "Use libzmq FFI backend (requires omq-ffi gem + system libzmq 4.x)") do
            begin
              require "omq/ffi"
            rescue LoadError => e
              abort "omq: --ffi requires the omq-ffi gem and system libzmq 4.x (#{e.message})"
            end
            opts[:ffi] = true
          end
          o.on("-V", "--version") {
            if ENV["OMQ_DEV"]
              require_relative "../../../../omq/lib/omq/version"
            else
              require "omq/version"
            end
            puts "omq-cli #{OMQ::CLI::VERSION} (omq #{OMQ::VERSION})"
            exit
          }
          o.on("-h")             { puts o
                                   exit }
          o.on("--help")        { CLI.page "#{o}\n#{EXAMPLES}"
                                   exit }
          o.on("--examples")    { CLI.page EXAMPLES
                                   exit }

          o.separator "\nExit codes: 0 = success, 1 = error, 2 = timeout"
        end

        begin
          parser.parse!(argv)
        rescue OptionParser::ParseError => e
          abort e.message
        end

        type_name = argv.shift
        if type_name.nil?
          abort parser.to_s if opts[:scripts].empty?
          # bare script mode -- type_name stays nil
        elsif !SOCKET_TYPE_NAMES.include?(type_name.downcase)
          abort "Unknown socket type: #{type_name}. Known: #{SOCKET_TYPE_NAMES.join(', ')}"
        else
          opts[:type_name] = type_name.downcase
        end

        # Normalize shorthand hostnames to concrete addresses.
        #
        # Binds:    tcp://:PORT  → loopback (::1 if IPv6 available, else 127.0.0.1)
        #           tcp://*:PORT → 0.0.0.0 (all interfaces, IPv4)
        #           tcp://0.0.0.0:PORT, tcp://[::]:PORT → pass through
        #
        # Connects: tcp://:PORT  → localhost (Happy Eyeballs)
        #           tcp://*:PORT → localhost
        #
        # The hang on macOS (IPv6 connect(2) not getting ECONNREFUSED via
        # kqueue) is fixed by the connect timeout in Engine::Reconnect.
        loopback        = self.class.loopback_bind_host
        normalize_bind    = ->(url) { url.sub(%r{\Atcp://\*:}, "tcp://0.0.0.0:").sub(%r{\Atcp://:}, "tcp://#{loopback}:") }
        normalize_connect = ->(url) { url.sub(%r{\Atcp://(\*|):}, "tcp://localhost:") }
        normalize_ep      = ->(ep)  { Endpoint.new(ep.bind? ? normalize_bind.call(ep.url) : normalize_connect.call(ep.url), ep.bind?) }
        opts[:binds].map!(&normalize_bind)
        opts[:connects].map!(&normalize_connect)
        opts[:endpoints].map!(&normalize_ep)
        opts[:in_endpoints].map!(&normalize_ep)
        opts[:out_endpoints].map!(&normalize_ep)

        opts
      end


      # Parses a byte size string with an optional K/M/G suffix (binary,
      # i.e. 1K = 1024 bytes).
      #
      # @param str [String] e.g. "4096", "4K", "1M", "2G"
      # @return [Integer] size in bytes
      #
      def parse_byte_size(str)
        case str
        when /\A(\d+)[kK]\z/ then $1.to_i * 1024
        when /\A(\d+)[mM]\z/ then $1.to_i * 1024 * 1024
        when /\A(\d+)[gG]\z/ then $1.to_i * 1024 * 1024 * 1024
        when /\A\d+\z/       then str.to_i
        else
          abort "invalid byte size: #{str} (use e.g. 4096, 4K, 1M, 2G)"
        end
      end


      # Validates option combinations, aborting on invalid combos.
      #
      # @param opts [Hash] parsed options from {#parse}
      # @return [void]
      def validate!(opts)
        return if opts[:type_name].nil?  # bare script mode

        abort "-r- (stdin script) and -F- (stdin data) cannot both be used" if opts[:scripts]&.include?(:stdin) && opts[:file] == "-"

        type_name = opts[:type_name]

        if type_name == "pipe"
          has_in_out = opts[:in_endpoints].any? || opts[:out_endpoints].any?
          if has_in_out
            abort "pipe --in requires at least one endpoint"             if opts[:in_endpoints].empty?
            abort "pipe --out requires at least one endpoint"            if opts[:out_endpoints].empty?
            abort "pipe: don't mix --in/--out with bare -b/-c endpoints" unless opts[:endpoints].empty?
          else
            abort "pipe requires exactly 2 endpoints (pull-side and push-side), or use --in/--out" if opts[:endpoints].size != 2
          end
        else
          abort "--in/--out are only valid for pipe" if opts[:in_endpoints].any? || opts[:out_endpoints].any?
          abort "At least one --connect or --bind is required" if opts[:connects].empty? && opts[:binds].empty?
        end
        abort "--data and --file are mutually exclusive"        if opts[:data] && opts[:file]
        abort "--subscribe is only valid for SUB"               if !opts[:subscribes].empty? && type_name != "sub"
        abort "--join is only valid for DISH"                   if !opts[:joins].empty? && type_name != "dish"
        abort "--group is only valid for RADIO"                 if opts[:group] && type_name != "radio"
        abort "--identity is only valid for DEALER/ROUTER"      if opts[:identity] && !%w[dealer router].include?(type_name)
        abort "--target is only valid for ROUTER/SERVER/PEER"   if opts[:target] && !%w[router server peer].include?(type_name)
        abort "--conflate is only valid for PUB/RADIO"          if opts[:conflate] && !%w[pub radio].include?(type_name)
        abort "--recv-eval is not valid for send-only sockets (use --send-eval / -E)" if opts[:recv_expr] && SEND_ONLY.include?(type_name)
        abort "--send-eval is not valid for recv-only sockets (use --recv-eval / -e)" if opts[:send_expr] && RECV_ONLY.include?(type_name)
        abort "--send-eval is not valid for REP (the reply is the result of --recv-eval / -e)" if opts[:send_expr] && type_name == "rep"
        abort "--send-eval and --target are mutually exclusive"  if opts[:send_expr] && opts[:target]

        if opts[:parallel]
          parallel_types = %w[pipe pull gather rep]
          abort "-P/--parallel is only valid for #{parallel_types.join(", ")}" unless parallel_types.include?(type_name)
          abort "-P/--parallel must be 1..16" unless (1..16).include?(opts[:parallel])
          if type_name == "pipe"
            all_eps = opts[:in_endpoints] + opts[:out_endpoints] + opts[:endpoints]
          else
            all_eps = opts[:endpoints]
          end
          abort "-P/--parallel requires all endpoints to use --connect (not --bind)" if all_eps.any?(&:bind?)
        end

        (opts[:connects] + opts[:binds]).each do |url|
          abort "inproc not supported, use tcp:// or ipc://" if url.include?("inproc://")
        end

        all_urls = if type_name == "pipe"
                     (opts[:in_endpoints] + opts[:out_endpoints] + opts[:endpoints]).map(&:url)
                   else
                     opts[:connects] + opts[:binds]
                   end
        dups = all_urls.tally.select { |_, n| n > 1 }.keys
        abort "duplicate endpoint: #{dups.first}" if dups.any?
      end


      # Returns the loopback address for bind normalization.
      # Prefers IPv6 loopback ([::1]) when the host has at least one
      # non-loopback, non-link-local IPv6 address, otherwise 127.0.0.1.
      #
      def self.loopback_bind_host
        @loopback_bind_host ||= begin
          has_ipv6 = ::Socket.getifaddrs.any? { |ifa|
            addr = ifa.addr
            addr&.ipv6? && !addr.ipv6_loopback? && !addr.ipv6_linklocal?
          }
          has_ipv6 ? "[::1]" : "127.0.0.1"
        end
      end
    end
  end
end
