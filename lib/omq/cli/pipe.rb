# frozen_string_literal: true

module OMQ
  module CLI
    # Runner for the virtual "pipe" socket type (PULL -> eval -> PUSH).
    # Supports sequential and parallel (Ractor-based) processing modes.
    class PipeRunner
      # @return [Config] frozen CLI configuration
      attr_reader :config


      # @param config [Config] frozen CLI configuration
      def initialize(config)
        @config = config
        @fmt    = Formatter.new(config.format, compress: config.compress)
        @fmt_in  = Formatter.new(config.format, compress: config.compress_in || config.compress)
        @fmt_out = Formatter.new(config.format, compress: config.compress_out || config.compress)
      end


      # Runs the pipe in sequential or parallel mode based on config.
      #
      # @param task [Async::Task] the parent async task
      # @return [void]
      def call(task)
        if config.parallel
          run_parallel(task)
        else
          run_sequential(task)
        end
      end


      private


      def resolve_endpoints
        if config.in_endpoints.any?
          [config.in_endpoints, config.out_endpoints]
        else
          [[config.endpoints[0]], [config.endpoints[1]]]
        end
      end


      def attach_endpoints(sock, endpoints)
        SocketSetup.attach_endpoints(sock, endpoints, verbose: config.verbose >= 1)
      end


      # ── Sequential ───────────────────────────────────────────────────


      def run_sequential(task)
        in_eps, out_eps = resolve_endpoints
        @pull, @push = build_pull_push(
          { linger: config.linger, recv_timeout: config.timeout },
          { linger: config.linger, send_timeout: config.timeout },
          in_eps, out_eps
        )
        compile_expr
        @sock = @pull  # for eval instance_exec
        start_event_monitors if config.verbose >= 2
        with_timeout(config.timeout) do
          Barrier do |barrier|
            barrier.async(annotation: "wait push peer") { @push.peer_connected.wait }
            barrier.async(annotation: "wait pull peer") { @pull.peer_connected.wait }
          end
        end
        setup_sequential_transient(task)
        @sock.instance_exec(&@recv_begin_proc) if @recv_begin_proc
        sequential_message_loop
        @sock.instance_exec(&@recv_end_proc) if @recv_end_proc
      ensure
        @pull&.close
        @push&.close
      end


      def apply_socket_options(sock)
        sock.reconnect_interval = config.reconnect_ivl if config.reconnect_ivl
        sock.heartbeat_interval = config.heartbeat_ivl if config.heartbeat_ivl
        sock.send_hwm           = config.send_hwm      if config.send_hwm
        sock.recv_hwm           = config.recv_hwm      if config.recv_hwm
        sock.sndbuf             = config.sndbuf        if config.sndbuf
        sock.rcvbuf             = config.rcvbuf        if config.rcvbuf
      end


      def build_pull_push(pull_opts, push_opts, in_eps, out_eps)
        pull = OMQ::PULL.new(**pull_opts)
        push = OMQ::PUSH.new(**push_opts)
        apply_socket_options(pull)
        apply_socket_options(push)
        attach_endpoints(pull, in_eps)
        attach_endpoints(push, out_eps)
        [pull, push]
      end


      def setup_sequential_transient(task)
        return unless config.transient
        task.async do
          @pull.all_peers_gone.wait
          @pull.reconnect_enabled = false
          @pull.close_read
        end
      end


      def sequential_message_loop
        n = config.count
        i = 0
        loop do
          parts = @pull.receive
          break if parts.nil?
          parts = @fmt_in.decompress(parts)
          parts = eval_recv_expr(parts)
          if parts && !parts.empty?
            out = @fmt_out.compress(parts)
            @push.send(out)
          end
          i += 1
          break if n && n > 0 && i >= n
        end
      end


      # ── Parallel ─────────────────────────────────────────────────────


      def run_parallel(task)
        OMQ.freeze_for_ractors!
        in_eps, out_eps = resolve_endpoints
        in_eps  = preresolve_tcp(in_eps)
        out_eps = preresolve_tcp(out_eps)
        log_port, log_thread = start_log_consumer
        workers = config.parallel.times.map do
          ::Ractor.new(config, in_eps, out_eps, log_port) do |cfg, ins, outs, lport|
            PipeWorker.new(cfg, ins, outs, lport).call
          end
        end
        workers.each do |w|
          w.join
        rescue ::Ractor::RemoteError => e
          $stderr.write("omq: Ractor error: #{e.cause&.message || e.message}\n")
        end
      ensure
        log_port.close
        log_thread.join
      end


      # ── Shared helpers ────────────────────────────────────────────────


      # Starts a Ractor::Port and a consumer thread that drains log
      # messages to stderr sequentially. Returns [port, thread].
      #
      def start_log_consumer
        port = Ractor::Port.new
        thread = Thread.new(port) do |p|
          loop do
            $stderr.write("#{p.receive}\n")
          rescue Ractor::ClosedError
            break
          end
        end
        [port, thread]
      end


      # Resolves TCP hostnames to IP addresses so Ractors don't touch
      # Resolv::DefaultResolver (which is not shareable).
      #
      def preresolve_tcp(endpoints)
        endpoints.flat_map do |ep|
          url = ep.url
          if url.start_with?("tcp://")
            host, port = OMQ::Transport::TCP.parse_endpoint(url)
            Addrinfo.getaddrinfo(host, port, nil, :STREAM).map do |addr|
              ip = addr.ip_address
              ip = "[#{ip}]" if ip.include?(":")
              Endpoint.new("tcp://#{ip}:#{addr.ip_port}", ep.bind?)
            end
          else
            ep
          end
        end
      end


      def with_timeout(seconds)
        if seconds
          Async::Task.current.with_timeout(seconds) { yield }
        else
          yield
        end
      end


      def compile_expr
        @recv_evaluator  = ExpressionEvaluator.new(config.recv_expr, format: config.format)
        @recv_begin_proc = @recv_evaluator.begin_proc
        @recv_eval_proc  = @recv_evaluator.eval_proc
        @recv_end_proc   = @recv_evaluator.end_proc
      end


      def eval_recv_expr(parts)
        result = @recv_evaluator.call(parts, @sock)
        result.equal?(ExpressionEvaluator::SENT) ? nil : result
      end


      def log(msg)
        $stderr.write("#{msg}\n") if config.verbose >= 1
      end


      def start_event_monitors
        verbose = config.verbose >= 3
        [@pull, @push].each do |sock|
          sock.monitor(verbose: verbose) do |event|
            case event.type
            when :message_sent
              $stderr.write("omq: >> #{msg_preview(event.detail[:parts])}\n")
            when :message_received
              $stderr.write("omq: << #{msg_preview(event.detail[:parts])}\n")
            else
              ep = event.endpoint ? " #{event.endpoint}" : ""
              detail = event.detail ? " #{event.detail}" : ""
              $stderr.write("omq: #{event.type}#{ep}#{detail}\n")
            end
          end
        end
      end


      def msg_preview(parts)
        parts.map { |p|
          bytes = p.b
          preview = bytes[0, 10].gsub(/[^[:print:]]/, ".")
          bytes.bytesize > 10 ? "#{preview}... (#{bytes.bytesize}B)" : preview
        }.join(" | ")
      end
    end


    # Worker that runs inside a Ractor for pipe -P parallel mode.
    # Each worker owns its own Async reactor, PULL socket, and PUSH socket.
    #
    class PipeWorker
      def initialize(config, in_eps, out_eps, log_port)
        @config   = config
        @in_eps   = in_eps
        @out_eps  = out_eps
        @log_port = log_port
      end


      def call
        Async do
          setup_sockets
          log_endpoints if @config.verbose >= 1
          start_monitors if @config.verbose >= 2
          wait_for_peers
          compile_expr
          run_message_loop
          run_end_block
        ensure
          @pull&.close
          @push&.close
        end
      end


      private


      def setup_sockets
        @pull = OMQ::PULL.new(linger: @config.linger)
        @push = OMQ::PUSH.new(linger: @config.linger)
        @pull.recv_timeout      = @config.timeout if @config.timeout
        @push.send_timeout      = @config.timeout if @config.timeout
        apply_socket_options(@pull)
        apply_socket_options(@push)
        OMQ::CLI::SocketSetup.attach_endpoints(@pull, @in_eps, verbose: false)
        OMQ::CLI::SocketSetup.attach_endpoints(@push, @out_eps, verbose: false)
      end


      def apply_socket_options(sock)
        sock.reconnect_interval = @config.reconnect_ivl if @config.reconnect_ivl
        sock.heartbeat_interval = @config.heartbeat_ivl if @config.heartbeat_ivl
        sock.send_hwm           = @config.send_hwm if @config.send_hwm
        sock.recv_hwm           = @config.recv_hwm if @config.recv_hwm
        sock.sndbuf             = @config.sndbuf if @config.sndbuf
        sock.rcvbuf             = @config.rcvbuf if @config.rcvbuf
      end


      def log_endpoints
        @in_eps.each { |ep| @log_port.send(ep.bind? ? "Bound to #{ep.url}" : "Connecting to #{ep.url}") }
        @out_eps.each { |ep| @log_port.send(ep.bind? ? "Bound to #{ep.url}" : "Connecting to #{ep.url}") }
      end


      def start_monitors
        trace = @config.verbose >= 3
        [@pull, @push].each do |sock|
          sock.monitor(verbose: trace) do |event|
            @log_port.send(format_event(event))
          end
        end
      end


      def format_event(event)
        case event.type
        when :message_sent
          "omq: >> #{msg_preview(event.detail[:parts])}"
        when :message_received
          "omq: << #{msg_preview(event.detail[:parts])}"
        else
          ep = event.endpoint ? " #{event.endpoint}" : ""
          detail = event.detail ? " #{event.detail}" : ""
          "omq: #{event.type}#{ep}#{detail}"
        end
      end


      def msg_preview(parts)
        parts.map { |p|
          bytes = p.b
          preview = bytes[0, 10].gsub(/[^[:print:]]/, ".")
          bytes.bytesize > 10 ? "#{preview}... (#{bytes.bytesize}B)" : preview
        }.join(" | ")
      end


      def wait_for_peers
        Barrier do |barrier|
          barrier.async { @pull.peer_connected.wait }
          barrier.async { @push.peer_connected.wait }
        end
      end


      def compile_expr
        @begin_proc, @end_proc, @eval_proc =
          OMQ::CLI::ExpressionEvaluator.compile_inside_ractor(@config.recv_expr)
        @fmt_in  = OMQ::CLI::Formatter.new(@config.format, compress: @config.compress_in || @config.compress)
        @fmt_out = OMQ::CLI::Formatter.new(@config.format, compress: @config.compress_out || @config.compress)
        @ctx = Object.new
        @ctx.instance_exec(&@begin_proc) if @begin_proc
      end


      def run_message_loop
        n = @config.count
        if @eval_proc
          if n && n > 0
            n.times do
              parts = @pull.receive
              break if parts.nil?
              parts = OMQ::CLI::ExpressionEvaluator.normalize_result(
                @ctx.instance_exec(@fmt_in.decompress(parts), &@eval_proc)
              )
              next if parts.nil?
              @push << @fmt_out.compress(parts) unless parts.empty?
            end
          else
            loop do
              parts = @pull.receive
              break if parts.nil?
              parts = OMQ::CLI::ExpressionEvaluator.normalize_result(
                @ctx.instance_exec(@fmt_in.decompress(parts), &@eval_proc)
              )
              next if parts.nil?
              @push << @fmt_out.compress(parts) unless parts.empty?
            end
          end
        else
          if n && n > 0
            n.times do
              parts = @pull.receive
              break if parts.nil?
              @push << @fmt_out.compress(@fmt_in.decompress(parts))
            end
          else
            loop do
              parts = @pull.receive
              break if parts.nil?
              @push << @fmt_out.compress(@fmt_in.decompress(parts))
            end
          end
        end
      rescue IO::TimeoutError, Async::TimeoutError
        # recv timed out — fall through to END block
      end


      def run_end_block
        return unless @end_proc
        out = OMQ::CLI::ExpressionEvaluator.normalize_result(
          @ctx.instance_exec(&@end_proc)
        )
        @push << @fmt_out.compress(out) if out && !out.empty?
      end
    end
  end
end
