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
        @config  = config
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


      # ── Sequential ───────────────────────────────────────────────────


      def run_sequential(task)
        in_eps, out_eps = resolve_endpoints
        @pull, @push = build_pull_push(in_eps, out_eps)
        compile_expr
        @sock = @pull  # for eval instance_exec
        start_event_monitors if config.verbose >= 2
        wait_body = proc do
          Barrier do |barrier|
            barrier.async(annotation: "wait push peer") { @push.peer_connected.wait }
            barrier.async(annotation: "wait pull peer") { @pull.peer_connected.wait }
          end
        end

        if config.timeout
          Fiber.scheduler.with_timeout(config.timeout, &wait_body)
        else
          wait_body.call
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


      def build_pull_push(in_eps, out_eps)
        pull = OMQ::PULL.new(linger: config.linger, recv_timeout: config.timeout)
        push = OMQ::PUSH.new(linger: config.linger, send_timeout: config.timeout)
        apply_socket_options(pull)
        apply_socket_options(push)
        SocketSetup.attach_endpoints(pull, in_eps, verbose: config.verbose >= 1)
        SocketSetup.attach_endpoints(push, out_eps, verbose: config.verbose >= 1)
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
            @push.send(@fmt_out.compress(parts))
          end
          i += 1
          break if n && n > 0 && i >= n
        end
      end


      # ── Parallel ─────────────────────────────────────────────────────


      def run_parallel(task)
        OMQ.freeze_for_ractors!
        in_eps, out_eps = resolve_endpoints
        in_eps  = PipeWorker.preresolve_tcp(in_eps)
        out_eps = PipeWorker.preresolve_tcp(out_eps)
        log_port, log_thread = PipeWorker.start_log_consumer
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


      # ── Expression eval ──────────────────────────────────────────────


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


      # ── Event monitoring ─────────────────────────────────────────────


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
  end
end
