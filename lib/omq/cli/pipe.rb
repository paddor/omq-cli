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
        SocketSetup.attach_endpoints(sock, endpoints, verbose: config.verbose)
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
        with_timeout(config.timeout) do
          @push.peer_connected.wait
          @pull.peer_connected.wait
        end
        setup_sequential_transient(task)
        @sock.instance_exec(&@recv_begin_proc) if @recv_begin_proc
        sequential_message_loop
        @sock.instance_exec(&@recv_end_proc) if @recv_end_proc
      ensure
        @pull&.close
        @push&.close
      end


      def apply_socket_intervals(sock)
        sock.reconnect_interval = config.reconnect_ivl if config.reconnect_ivl
        sock.heartbeat_interval = config.heartbeat_ivl if config.heartbeat_ivl
      end


      def build_pull_push(pull_opts, push_opts, in_eps, out_eps)
        pull = OMQ::PULL.new(**pull_opts)
        push = OMQ::PUSH.new(**push_opts)
        apply_socket_intervals(pull)
        apply_socket_intervals(push)
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
          parts = @fmt.decompress(parts)
          parts = eval_recv_expr(parts)
          @push.send(@fmt.compress(parts)) if parts && !parts.empty?
          i += 1
          break if n && n > 0 && i >= n
        end
      end


      # ── Parallel ─────────────────────────────────────────────────────


      def run_parallel(task)
        in_eps, out_eps = resolve_endpoints
        pairs = build_socket_pairs(config.parallel, in_eps, out_eps)
        wait_for_pairs(pairs)
        setup_parallel_transient(task, pairs)
        workers = spawn_workers(pairs, build_worker_data)
        join_workers(workers)
      ensure
        pairs&.each do |pull, push|
          pull&.close
          push&.close
        end
      end


      def build_socket_pairs(n_workers, in_eps, out_eps)
        pull_opts = { linger: config.linger }
        push_opts = { linger: config.linger }
        pull_opts[:recv_timeout] = config.timeout if config.timeout
        push_opts[:send_timeout] = config.timeout if config.timeout
        n_workers.times.map { build_pull_push(pull_opts, push_opts, in_eps, out_eps) }
      end


      def wait_for_pairs(pairs)
        with_timeout(config.timeout) do
          pairs.each do |pull, push|
            push.peer_connected.wait
            pull.peer_connected.wait
          end
        end
      end


      def setup_parallel_transient(task, pairs)
        return unless config.transient
        task.async do
          pairs[0][0].all_peers_gone.wait
          pairs.each do |pull, _|
            pull.reconnect_enabled = false
            pull.close_read
          end
        end
      end


      def build_worker_data
        # Pack worker config into a shareable Hash passed via omq.data —
        # Ruby 4.0 forbids Ractor blocks from closing over outer locals.
        ::Ractor.make_shareable({
          recv_src:   config.recv_expr,
          fmt_format: config.format,
          fmt_compr:  config.compress,
          n_count:    config.count,
        })
      end


      def spawn_workers(pairs, worker_data)
        pairs.map do |pull, push|
          OMQ::Ractor.new(pull, push, serialize: false, data: worker_data) do |omq|
            pull_p, push_p = omq.sockets
            d = omq.data

            # Re-compile expression inside Ractor (Procs are not shareable)
            begin_proc, end_proc, eval_proc =
              OMQ::CLI::ExpressionEvaluator.compile_inside_ractor(d[:recv_src])

            formatter = OMQ::CLI::Formatter.new(d[:fmt_format], compress: d[:fmt_compr])
            # Use a dedicated context object so @ivar expressions in BEGIN/END/eval
            # work inside Ractors (self in a Ractor is shareable; Object.new is not).
            _ctx = Object.new
            _ctx.instance_exec(&begin_proc) if begin_proc

            n_count = d[:n_count]
            if eval_proc
              if n_count && n_count > 0
                n_count.times do
                  parts = pull_p.receive
                  break if parts.nil?
                  parts = OMQ::CLI::ExpressionEvaluator.normalize_result(
                    _ctx.instance_exec(formatter.decompress(parts), &eval_proc)
                  )
                  next if parts.nil?
                  push_p << formatter.compress(parts) unless parts.empty?
                end
              else
                loop do
                  parts = pull_p.receive
                  break if parts.nil?
                  parts = OMQ::CLI::ExpressionEvaluator.normalize_result(
                    _ctx.instance_exec(formatter.decompress(parts), &eval_proc)
                  )
                  next if parts.nil?
                  push_p << formatter.compress(parts) unless parts.empty?
                end
              end
            else
              if n_count && n_count > 0
                n_count.times do
                  parts = pull_p.receive
                  break if parts.nil?
                  push_p << formatter.compress(formatter.decompress(parts))
                end
              else
                loop do
                  parts = pull_p.receive
                  break if parts.nil?
                  push_p << formatter.compress(formatter.decompress(parts))
                end
              end
            end

            if end_proc
              out = OMQ::CLI::ExpressionEvaluator.normalize_result(
                _ctx.instance_exec(&end_proc)
              )
              push_p << formatter.compress(out) if out && !out.empty?
            end
          end
        end
      end


      def join_workers(workers)
        workers.each do |w|
          w.value
        rescue Ractor::RemoteError => e
          $stderr.puts "omq: Ractor error: #{e.cause&.message || e.message}"
        end
      end


      # ── Shared helpers ────────────────────────────────────────────────


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
        $stderr.puts(msg) if config.verbose
      end
    end
  end
end
