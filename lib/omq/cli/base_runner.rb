# frozen_string_literal: true

module OMQ
  module CLI
    # Template runner base class for all socket-type CLI runners.
    # Subclasses override {#run_loop} to implement socket-specific behaviour.
    class BaseRunner
      # @return [Config] frozen CLI configuration
      # @return [Object] the OMQ socket instance
      attr_reader :config, :sock


      # @param config [Config] frozen CLI configuration
      # @param socket_class [Class] OMQ socket class to instantiate (e.g. OMQ::PUSH)
      def initialize(config, socket_class)
        @config = config
        @klass  = socket_class
        @fmt    = Formatter.new(config.format, compress: config.compress)
      end


      # Runs the full lifecycle: socket setup, peer wait, BEGIN/END blocks, and the main loop.
      #
      # @param task [Async::Task] the parent async task
      # @return [void]
      def call(task)
        setup_socket
        start_event_monitor if config.verbose >= 2
        maybe_start_transient_monitor(task)
        sleep(config.delay) if config.delay && config.recv_only?
        wait_for_peer if needs_peer_wait?
        run_begin_blocks
        run_loop(task)
        run_end_blocks
      ensure
        @sock&.close
      end


      private


      # Subclasses override this.
      def run_loop(task)
        raise NotImplementedError
      end


      # ── Socket creation ─────────────────────────────────────────────


      def setup_socket
        @sock = create_socket
        attach_endpoints unless config.parallel
        setup_curve
        setup_subscriptions
        compile_expr
      end


      def create_socket
        SocketSetup.build(@klass, config)
      end


      def attach_endpoints
        SocketSetup.attach(@sock, config, verbose: config.verbose >= 1)
      end


      # ── Transient disconnect monitor ────────────────────────────────


      def maybe_start_transient_monitor(task)
        return unless config.transient
        @transient_monitor = TransientMonitor.new(@sock, config, task, method(:log))
        Async::Task.current.yield  # let monitor start waiting
      end


      def transient_ready!
        @transient_monitor&.ready!
      end


      # ── BEGIN / END blocks ──────────────────────────────────────────


      def run_begin_blocks
        @sock.instance_exec(&@send_begin_proc) if @send_begin_proc
        @sock.instance_exec(&@recv_begin_proc) if @recv_begin_proc
      end


      def run_end_blocks
        @sock.instance_exec(&@send_end_proc) if @send_end_proc
        @sock.instance_exec(&@recv_end_proc) if @recv_end_proc
      end


      # ── Peer wait with grace period ─────────────────────────────────


      def needs_peer_wait?
        !config.recv_only? && (config.connects.any? || config.type_name == "router")
      end


      def wait_for_peer
        with_timeout(config.timeout) do
          @sock.peer_connected.wait
          log "Peer connected"
          wait_for_subscriber
          apply_grace_period
        end
      end


      def wait_for_subscriber
        return unless %w[pub xpub].include?(config.type_name)
        @sock.subscriber_joined.wait
        log "Subscriber joined"
      end


      # Grace period: when multiple peers may be connecting (bind or
      # multiple connect URLs), wait one reconnect interval so
      # latecomers finish their handshake before we start sending.
      def apply_grace_period
        return unless config.binds.any? || config.connects.size > 1
        ri = @sock.options.reconnect_interval
        sleep(ri.is_a?(Range) ? ri.begin : ri)
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
        SocketSetup.setup_subscriptions(@sock, config)
      end


      def setup_subscriptions_on(sock)
        SocketSetup.setup_subscriptions(sock, config)
      end


      def setup_curve
        SocketSetup.setup_curve(@sock, config)
      end


      # ── Shared loop bodies ──────────────────────────────────────────


      def run_send_logic
        n = config.count
        sleep(config.delay) if config.delay
        if config.interval
          run_interval_send(n)
        elsif config.data || config.file
          parts = eval_send_expr(read_next)
          send_msg(parts) if parts
        elsif stdin_ready?
          run_stdin_send(n)
        elsif @send_eval_proc
          parts = eval_send_expr(nil)
          send_msg(parts) if parts
        end
      end


      def run_interval_send(n)
        i = send_tick
        return if @send_tick_eof || (n && n > 0 && i >= n)
        Async::Loop.quantized(interval: config.interval) do
          i += send_tick
          break if @send_tick_eof || (n && n > 0 && i >= n)
        end
      end


      def run_stdin_send(n)
        i = 0
        loop do
          parts = read_next
          break unless parts
          parts = eval_send_expr(parts)
          send_msg(parts) if parts
          i += 1
          break if n && n > 0 && i >= n
        end
      end


      def send_tick
        raw = read_next_or_nil
        if raw.nil?
          if @send_eval_proc && !@stdin_ready
            # Pure generator mode: no stdin, eval produces output from nothing.
            parts = eval_send_expr(nil)
            send_msg(parts) if parts
            return 1
          end
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
        if config.interval
          run_interval_recv(n)
        else
          loop do
            parts = recv_msg
            break if parts.nil?
            parts = eval_recv_expr(parts)
            output(parts)
            i += 1
            break if n && n > 0 && i >= n
          end
        end
      end


      def run_interval_recv(n)
        i = recv_tick
        return if i == 0
        return if n && n > 0 && i >= n
        Async::Loop.quantized(interval: config.interval) do
          i += recv_tick
          break if @recv_tick_eof || (n && n > 0 && i >= n)
        end
      end


      def recv_tick
        parts = recv_msg
        if parts.nil?
          @recv_tick_eof = true
          return 0
        end
        parts = eval_recv_expr(parts)
        output(parts)
        1
      end


      # Parallel recv-eval: delegates to ParallelRecvRunner.
      #
      def run_parallel_recv(task)
        # @sock was created by call() before run_loop; close it now so it doesn't
        # steal messages from the N worker sockets ParallelRecvRunner creates.
        @sock&.close
        @sock = nil
        ParallelRecvRunner.new(@klass, config, @fmt, method(:output)).run(task)
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
        trace_send(parts)
        @sock.send(parts)
        transient_ready!
      end


      def recv_msg
        raw = @sock.receive
        return nil if raw.nil?
        parts = @fmt.decompress(raw)
        parts = Marshal.load(parts.first) if config.format == :marshal
        trace_recv(parts)
        transient_ready!
        parts
      end


      def recv_msg_raw
        msg = @sock.receive
        msg&.dup
      end


      def read_next
        config.data || config.file ? read_inline_data : read_stdin_input
      end


      def read_inline_data
        if config.data
          @fmt.decode(config.data + "\n")
        else
          @file_data ||= (config.file == "-" ? $stdin.read : File.read(config.file)).chomp
          @fmt.decode(@file_data + "\n")
        end
      end


      def read_stdin_input
        case config.format
        when :msgpack
          @fmt.decode_msgpack($stdin)
        when :marshal
          @fmt.decode_marshal($stdin)
        when :raw
          data = $stdin.read
          data.nil? || data.empty? ? nil : [data]
        else
          line = $stdin.gets
          line.nil? ? nil : @fmt.decode(line)
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
        elsif stdin_ready?
          read_stdin_input
        else
          nil
        end
      end


      def output(parts)
        return if config.quiet || parts.nil?
        $stdout.write(@fmt.encode(parts))
        $stdout.flush
      end


      # ── Eval ────────────────────────────────────────────────────────


      def compile_expr
        @send_evaluator = compile_evaluator(config.send_expr, fallback: OMQ.outgoing_proc)
        @recv_evaluator = compile_evaluator(config.recv_expr, fallback: OMQ.incoming_proc)
        assign_send_aliases
        assign_recv_aliases
      end


      def compile_evaluator(src, fallback:)
        ExpressionEvaluator.new(src, format: config.format, fallback_proc: fallback)
      end


      def assign_send_aliases
        # Keep ivar aliases — subclasses check these directly
        @send_begin_proc = @send_evaluator.begin_proc
        @send_eval_proc  = @send_evaluator.eval_proc
        @send_end_proc   = @send_evaluator.end_proc
      end


      def assign_recv_aliases
        @recv_begin_proc = @recv_evaluator.begin_proc
        @recv_eval_proc  = @recv_evaluator.eval_proc
        @recv_end_proc   = @recv_evaluator.end_proc
      end


      def eval_send_expr(parts)
        @send_evaluator.call(parts, @sock)
      end


      def eval_recv_expr(parts)
        @recv_evaluator.call(parts, @sock)
      end


      SENT = ExpressionEvaluator::SENT


      # ── Logging ─────────────────────────────────────────────────────


      def log(msg)
        $stderr.puts(msg) if config.verbose >= 1
      end


      # -vv: log connect/disconnect/retry/timeout events via Socket#monitor
      def start_event_monitor
        @sock.monitor do |event|
          ep = event.endpoint ? " #{event.endpoint}" : ""
          detail = event.detail ? " #{event.detail}" : ""
          $stderr.puts "omq: #{event.type}#{ep}#{detail}"
        end
      end


      # -vvv: log first 10 bytes of each message part
      def trace_send(parts)
        return unless config.verbose >= 3
        $stderr.puts "omq: >> #{msg_preview(parts)}"
      end


      def trace_recv(parts)
        return unless config.verbose >= 3
        $stderr.puts "omq: << #{msg_preview(parts)}"
      end


      def msg_preview(parts)
        parts.map { |p| preview_bytes(p) }.join(" | ")
      end


      def preview_bytes(str)
        bytes = str.b
        preview = bytes[0, 10].gsub(/[^[:print:]]/, ".")
        if bytes.bytesize > 10
          "#{preview}... (#{bytes.bytesize}B)"
        else
          preview
        end
      end
    end
  end
end
