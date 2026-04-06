# frozen_string_literal: true

module OMQ
  module CLI
    class BaseRunner
      attr_reader :config, :sock


      def initialize(config, socket_class)
        @config = config
        @klass  = socket_class
        @fmt    = Formatter.new(config.format, compress: config.compress)
      end


      def call(task)
        @sock = create_socket
        attach_endpoints unless config.parallel
        setup_curve
        setup_subscriptions
        compile_expr

        if config.transient
          start_disconnect_monitor(task)
          Async::Task.current.yield  # let monitor start waiting
        end

        sleep(config.delay) if config.delay && config.recv_only?
        wait_for_peer if needs_peer_wait?

        @sock.instance_exec(&@send_begin_proc) if @send_begin_proc
        @sock.instance_exec(&@recv_begin_proc) if @recv_begin_proc
        run_loop(task)
        @sock.instance_exec(&@send_end_proc) if @send_end_proc
        @sock.instance_exec(&@recv_end_proc) if @recv_end_proc
      ensure
        @sock&.close
      end


      private


      # Subclasses override this.
      def run_loop(task)
        raise NotImplementedError
      end

      # ── Socket creation ─────────────────────────────────────────────


      def create_socket
        sock_opts              = { linger: config.linger }
        sock_opts[:conflate]   = true if config.conflate && %w[pub radio].include?(config.type_name)
        sock                   = @klass.new(**sock_opts)
        sock.recv_timeout      = config.timeout if config.timeout
        sock.send_timeout      = config.timeout if config.timeout
        sock.max_message_size  = config.recv_maxsz if config.recv_maxsz
        sock.reconnect_interval  = config.reconnect_ivl if config.reconnect_ivl
        sock.heartbeat_interval  = config.heartbeat_ivl if config.heartbeat_ivl
        sock.identity            = config.identity if config.identity
        sock.router_mandatory  = true if config.type_name == "router"
        sock
      end


      def attach_endpoints
        config.binds.each do |url|
          @sock.bind(url)
          log "Bound to #{@sock.last_endpoint}"
        end
        config.connects.each do |url|
          @sock.connect(url)
          log "Connecting to #{url}"
        end
      end

      # ── Peer wait with grace period ─────────────────────────────────


      def needs_peer_wait?
        !config.recv_only? && (config.connects.any? || config.type_name == "router")
      end


      def wait_for_peer
        with_timeout(config.timeout) do
          @sock.peer_connected.wait
          log "Peer connected"
          if %w[pub xpub].include?(config.type_name)
            @sock.subscriber_joined.wait
            log "Subscriber joined"
          end

          # Grace period: when multiple peers may be connecting (bind or
          # multiple connect URLs), wait one reconnect interval so
          # latecomers finish their handshake before we start sending.
          if config.binds.any? || config.connects.size > 1
            ri = @sock.options.reconnect_interval
            sleep(ri.is_a?(Range) ? ri.begin : ri)
          end
        end
      end

      # ── Transient disconnect monitor ────────────────────────────────


      def start_disconnect_monitor(task)
        @transient_barrier = Async::Promise.new
        task.async do
          @transient_barrier.wait
          @sock.all_peers_gone.wait unless @sock.connection_count == 0
          log "All peers disconnected, exiting"
          @sock.reconnect_enabled = false
          if config.send_only?
            task.stop
          else
            @sock.close_read
          end
        end
      end


      def transient_ready!
        if config.transient && !@transient_barrier.resolved?
          @transient_barrier.resolve(true)
        end
      end

      # ── Timeout helper ──────────────────────────────────────────────


      def with_timeout(seconds)
        if seconds
          Async::Task.current.with_timeout(seconds) { yield }
        else
          yield
        end
      end

      # ── Socket setup ────────────────────────────────────────────────


      def setup_subscriptions
        setup_subscriptions_on(@sock)
      end


      def setup_subscriptions_on(sock)
        case config.type_name
        when "sub"
          prefixes = config.subscribes.empty? ? [""] : config.subscribes
          prefixes.each { |p| sock.subscribe(p) }
        when "dish"
          config.joins.each { |g| sock.join(g) }
        end
      end


      def setup_curve
        server_key_z85 = config.curve_server_key || ENV["OMQ_SERVER_KEY"]
        server_mode    = config.curve_server || (ENV["OMQ_SERVER_PUBLIC"] && ENV["OMQ_SERVER_SECRET"])

        return unless server_key_z85 || server_mode

        crypto = CLI.load_curve_crypto(config.curve_crypto || ENV["OMQ_CURVE_CRYPTO"], verbose: config.verbose)
        require "protocol/zmtp/mechanism/curve"

        if server_key_z85
          server_key = Protocol::ZMTP::Z85.decode(server_key_z85)
          client_key = crypto::PrivateKey.generate
          @sock.mechanism = Protocol::ZMTP::Mechanism::Curve.client(
            client_key.public_key.to_s, client_key.to_s,
            server_key: server_key, crypto: crypto
          )
        elsif server_mode
          if ENV["OMQ_SERVER_PUBLIC"] && ENV["OMQ_SERVER_SECRET"]
            server_pub = Protocol::ZMTP::Z85.decode(ENV["OMQ_SERVER_PUBLIC"])
            server_sec = Protocol::ZMTP::Z85.decode(ENV["OMQ_SERVER_SECRET"])
          else
            key        = crypto::PrivateKey.generate
            server_pub = key.public_key.to_s
            server_sec = key.to_s
          end
          @sock.mechanism = Protocol::ZMTP::Mechanism::Curve.server(
            server_pub, server_sec, crypto: crypto
          )
          $stderr.puts "OMQ_SERVER_KEY='#{Protocol::ZMTP::Z85.encode(server_pub)}'"
        end
      end


      # ── Shared loop bodies ──────────────────────────────────────────


      def run_send_logic
        n = config.count
        i = 0
        sleep(config.delay) if config.delay
        if config.interval
          i += send_tick
          unless @send_tick_eof || (n && n > 0 && i >= n)
            Async::Loop.quantized(interval: config.interval) do
              i += send_tick
              break if @send_tick_eof || (n && n > 0 && i >= n)
            end
          end
        elsif config.data || config.file
          parts = eval_send_expr(read_next)
          send_msg(parts) if parts
        elsif stdin_ready?
          loop do
            parts = read_next
            break unless parts
            parts = eval_send_expr(parts)
            send_msg(parts) if parts
            i += 1
            break if n && n > 0 && i >= n
          end
        elsif @send_eval_proc
          parts = eval_send_expr(nil)
          send_msg(parts) if parts
        end
      end


      def send_tick
        raw = read_next_or_nil
        if raw.nil? && !@send_eval_proc
          @send_tick_eof = true
          return 0
        end
        parts = eval_send_expr(raw)
        send_msg(parts) if parts
        1
      end


      def run_recv_logic
        n = config.count
        i = 0
        loop do
          parts = recv_msg
          break if parts.nil?
          parts = eval_recv_expr(parts)
          output(parts)
          i += 1
          break if n && n > 0 && i >= n
        end
      end


      # Parallel recv-eval: N OMQ::Ractor workers each with their own
      # input socket connecting to the external endpoints, plus a shared
      # inproc collector feeding results back to main for output().
      #
      def run_parallel_recv(task)
        # @sock was created and connected by call() before run_loop; close it now
        # so it doesn't steal messages from the N worker sockets we're about to create.
        @sock&.close; @sock = nil

        cfg       = config
        n_workers = cfg.parallel
        inproc    = "inproc://omq-out-#{object_id}"

        # Pack worker config into a shareable Hash passed via omq.data —
        # Ruby 4.0 forbids Ractor blocks from closing over outer locals.
        worker_data = ::Ractor.make_shareable({
          recv_src:  cfg.recv_expr,
          fmt_sym:   cfg.format,
          fmt_compr: cfg.compress,
        })

        # Create N input sockets in the main Async context
        input_socks = n_workers.times.map do
          sock = create_socket
          setup_subscriptions_on(sock)
          cfg.connects.each { |url| sock.connect(url) }
          sock
        end

        with_timeout(cfg.timeout) { input_socks.each { |s| s.peer_connected.wait } }

        # Inproc collector: one bound PULL to receive all worker output
        collector = OMQ::PULL.new(linger: cfg.linger)
        collector.recv_timeout = cfg.timeout if cfg.timeout
        collector.bind(inproc)

        # N output sockets connecting to the collector
        output_socks = n_workers.times.map do
          s = OMQ::PUSH.new(linger: cfg.linger)
          s.connect(inproc)
          s
        end

        workers = n_workers.times.map do |i|
          OMQ::Ractor.new(input_socks[i], output_socks[i], serialize: false, data: worker_data) do |omq|
            pull_p, push_p = omq.sockets
            d = omq.data

            # Re-compile expression inside Ractor (Procs are not shareable)
            begin_proc = end_proc = eval_proc = nil
            recv_src = d[:recv_src]
            if recv_src
              extract = ->(src, kw) {
                s2 = src.index(/#{kw}\s*\{/)
                return [src, nil] unless s2
                ci = src.index("{", s2); d2 = 1; j = ci + 1
                while j < src.length && d2 > 0
                  d2 += 1 if src[j] == "{"; d2 -= 1 if src[j] == "}"
                  j += 1
                end
                [src[0...s2] + src[j..], src[(ci + 1)..(j - 2)]]
              }
              expr, begin_body = extract.(recv_src, "BEGIN")
              expr, end_body   = extract.(expr,     "END")
              begin_proc = eval("proc { #{begin_body} }") if begin_body
              end_proc   = eval("proc { #{end_body} }")   if end_body
              if expr && !expr.strip.empty?
                ractor_expr = expr.gsub(/\$F\b/, "__F")
                eval_proc   = eval("proc { |__F| $_ = __F&.first; #{ractor_expr} }")
              end
            end

            formatter = OMQ::CLI::Formatter.new(d[:fmt_sym], compress: d[:fmt_compr])
            # Use a dedicated context object so @ivar expressions in BEGIN/END/eval
            # work inside Ractors (self in a Ractor is shareable; Object.new is not).
            _ctx = Object.new
            _ctx.instance_exec(&begin_proc) if begin_proc

            loop do
              parts = pull_p.receive
              break if parts.nil?
              parts = formatter.decompress(parts)
              if eval_proc
                result = _ctx.instance_exec(parts, &eval_proc)
                parts = case result
                        when nil    then next
                        when Array  then result
                        when String then [result]
                        else             [result.to_s]
                        end
              end
              push_p << parts unless parts.empty?
            end

            if end_proc
              result = _ctx.instance_exec(&end_proc)
              out = case result
                    when nil    then nil
                    when Array  then result
                    when String then [result]
                    else             [result.to_s]
                    end
              push_p << out if out && !out.empty?
            end
          end
        end

        # Collect loop: drain inproc PULL → output
        n_count = cfg.count
        i = 0
        loop do
          parts = collector.receive
          break if parts.nil?
          output(parts)
          i += 1
          break if n_count && n_count > 0 && i >= n_count
        end

        # Inject nil into each worker's input port so it exits its loop
        # without waiting for recv_timeout (workers don't self-terminate
        # when the collect loop exits on count).
        workers.each do |w|
          w.close
        rescue Ractor::RemoteError => e
          $stderr.puts "omq: Ractor error: #{e.cause&.message || e.message}"
        end
      ensure
        input_socks&.each(&:close)
        output_socks&.each(&:close)
        collector&.close
      end


      def wait_for_loops(receiver, sender)
        if config.data || config.file || config.send_expr || config.recv_expr || config.target
          sender.wait
          receiver.stop
        elsif config.count && config.count > 0
          receiver.wait
          sender.stop
        else
          sender.wait
          receiver.stop
        end
      end

      # ── Message I/O ─────────────────────────────────────────────────


      def send_msg(parts)
        return if parts.empty?
        parts = [Marshal.dump(parts)] if config.format == :marshal
        parts = @fmt.compress(parts)
        @sock.send(parts)
        transient_ready!
      end


      def recv_msg
        raw = @sock.receive
        return nil if raw.nil?
        parts = @fmt.decompress(raw)
        parts = Marshal.load(parts.first) if config.format == :marshal
        transient_ready!
        parts
      end


      def recv_msg_raw
        msg = @sock.receive
        msg&.dup
      end


      def read_next
        if config.data
          @fmt.decode(config.data + "\n")
        elsif config.file
          @file_data ||= (config.file == "-" ? $stdin.read : File.read(config.file)).chomp
          @fmt.decode(@file_data + "\n")
        elsif config.format == :msgpack
          @fmt.decode_msgpack($stdin)
        elsif config.format == :marshal
          @fmt.decode_marshal($stdin)
        elsif config.format == :raw
          data = $stdin.read
          return nil if data.nil? || data.empty?
          [data]
        else
          line = $stdin.gets
          return nil if line.nil?
          @fmt.decode(line)
        end
      end


      def stdin_ready?
        return @stdin_ready unless @stdin_ready.nil?

        @stdin_ready = !$stdin.closed? &&
                       !config.stdin_is_tty &&
                       IO.select([$stdin], nil, nil, 0.01) &&
                       !$stdin.eof?
      end


      def read_next_or_nil
        if config.data || config.file
          read_next
        elsif @send_eval_proc
          nil
        else
          read_next
        end
      end


      def output(parts)
        return if config.quiet || parts.nil?
        $stdout.write(@fmt.encode(parts))
        $stdout.flush
      end

      # ── Routing helpers ─────────────────────────────────────────────


      def display_routing_id(id)
        if id.bytes.all? { |b| b >= 0x20 && b <= 0x7E }
          id
        else
          "0x#{id.unpack1("H*")}"
        end
      end


      def resolve_target(target)
        if target.start_with?("0x")
          [target[2..].delete(" ")].pack("H*")
        else
          target
        end
      end

      # ── Eval ────────────────────────────────────────────────────────


      def compile_expr
        compile_one_expr(:send, config.send_expr)
        compile_one_expr(:recv, config.recv_expr)
        @send_eval_proc ||= wrap_registered_proc(OMQ.outgoing_proc)
        @recv_eval_proc ||= wrap_registered_proc(OMQ.incoming_proc)
      end


      def wrap_registered_proc(block)
        return unless block
        proc do |msg|
          $_ = msg&.first
          block.call(msg)
        end
      end


      def compile_one_expr(direction, src)
        return unless src
        expr, begin_body, end_body = extract_blocks(src)
        instance_variable_set(:"@#{direction}_begin_proc", eval("proc { #{begin_body} }")) if begin_body
        instance_variable_set(:"@#{direction}_end_proc",   eval("proc { #{end_body} }"))   if end_body
        if expr && !expr.strip.empty?
          instance_variable_set(:"@#{direction}_eval_proc", eval("proc { $_ = $F&.first; #{expr} }"))
        end
      end


      def extract_blocks(expr)
        begin_body = end_body = nil
        expr, begin_body = extract_block(expr, "BEGIN")
        expr, end_body   = extract_block(expr, "END")
        [expr, begin_body, end_body]
      end


      def extract_block(expr, keyword)
        start = expr.index(/#{keyword}\s*\{/)
        return [expr, nil] unless start

        # Find the opening brace
        i = expr.index("{", start)
        depth = 1
        j     = i + 1
        while j < expr.length && depth > 0
          case expr[j]
          when "{" then depth += 1
          when "}" then depth -= 1
          end
          j += 1
        end

        body    = expr[(i + 1)..(j - 2)]
        trimmed = expr[0...start] + expr[j..]
        [trimmed, body]
      end


      SENT = Object.new.freeze # sentinel: eval already sent the reply

      def eval_send_expr(parts)
        return parts unless @send_eval_proc
        run_eval(@send_eval_proc, parts)
      end


      def eval_recv_expr(parts)
        return parts unless @recv_eval_proc
        run_eval(@recv_eval_proc, parts)
      end


      def run_eval(eval_proc, parts)
        $F = parts
        result = @sock.instance_exec(parts, &eval_proc)
        return nil if result.nil?
        return SENT if result.equal?(@sock)
        return [result] if config.format == :marshal
        case result
        when Array  then result
        when String then [result]
        else             [result.to_str]
        end
      rescue => e
        $stderr.puts "omq: eval error: #{e.message} (#{e.class})"
        exit 3
      end

      # ── Logging ─────────────────────────────────────────────────────


      def log(msg)
        $stderr.puts(msg) if config.verbose
      end
    end
  end
end
