# frozen_string_literal: true

module OMQ
  module CLI
    class PipeRunner
      attr_reader :config


      def initialize(config)
        @config = config
        @fmt    = Formatter.new(config.format, compress: config.compress)
      end


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
        endpoints.each { |ep| ep.bind? ? sock.bind(ep.url) : sock.connect(ep.url) }
      end


      def run_sequential(task)
        in_eps, out_eps = resolve_endpoints

        @pull = OMQ::PULL.new(linger: config.linger, recv_timeout: config.timeout)
        @push = OMQ::PUSH.new(linger: config.linger, send_timeout: config.timeout)
        @pull.reconnect_interval  = config.reconnect_ivl if config.reconnect_ivl
        @push.reconnect_interval  = config.reconnect_ivl if config.reconnect_ivl
        @pull.heartbeat_interval  = config.heartbeat_ivl if config.heartbeat_ivl
        @push.heartbeat_interval  = config.heartbeat_ivl if config.heartbeat_ivl

        attach_endpoints(@pull, in_eps)
        attach_endpoints(@push, out_eps)

        compile_expr
        @sock = @pull  # for eval instance_exec

        with_timeout(config.timeout) do
          @push.peer_connected.wait
          @pull.peer_connected.wait
        end

        if config.transient
          task.async do
            @pull.all_peers_gone.wait
            @pull.reconnect_enabled = false
            @pull.close_read
          end
        end

        @sock.instance_exec(&@recv_begin_proc) if @recv_begin_proc

        n = config.count
        i = 0
        loop do
          parts = @pull.receive
          break if parts.nil?
          parts = @fmt.decompress(parts)
          parts = eval_recv_expr(parts)
          if parts && !parts.empty?
            @push.send(@fmt.compress(parts))
          end
          i += 1
          break if n && n > 0 && i >= n
        end

        @sock.instance_exec(&@recv_end_proc) if @recv_end_proc
      ensure
        @pull&.close
        @push&.close
      end


      def run_parallel(task)
        cfg      = config
        n_workers = cfg.parallel
        in_eps, out_eps = resolve_endpoints
        pull_opts = { linger: cfg.linger }
        push_opts = { linger: cfg.linger }
        pull_opts[:recv_timeout] = cfg.timeout if cfg.timeout
        push_opts[:send_timeout] = cfg.timeout if cfg.timeout

        # Create N PULL+PUSH socket pairs in the main Async context.
        # Each worker gets its own pair; ZMQ distributes work across the
        # N PULL connections and fans results in from the N PUSH connections.
        pairs = n_workers.times.map do
          pull = OMQ::PULL.new(**pull_opts)
          push = OMQ::PUSH.new(**push_opts)
          pull.reconnect_interval = cfg.reconnect_ivl if cfg.reconnect_ivl
          push.reconnect_interval = cfg.reconnect_ivl if cfg.reconnect_ivl
          pull.heartbeat_interval = cfg.heartbeat_ivl if cfg.heartbeat_ivl
          push.heartbeat_interval = cfg.heartbeat_ivl if cfg.heartbeat_ivl
          in_eps.each  { |ep| pull.connect(ep.url) }
          out_eps.each { |ep| push.connect(ep.url) }
          [pull, push]
        end

        # Wait for peer connections before spawning workers.
        # peer_connected.wait requires the Async context (not available inside Ractors).
        with_timeout(cfg.timeout) do
          pairs.each do |pull, push|
            push.peer_connected.wait
            pull.peer_connected.wait
          end
        end

        if cfg.transient
          task.async do
            pairs[0][0].all_peers_gone.wait
            pairs.each { |pull, _| pull.reconnect_enabled = false; pull.close_read }
          end
        end

        # Pack worker config into a shareable Hash passed via omq.data —
        # Ruby 4.0 forbids Ractor blocks from closing over outer locals.
        worker_data = ::Ractor.make_shareable({
          recv_src:   cfg.recv_expr,
          fmt_format: cfg.format,
          fmt_compr:  cfg.compress,
          n_count:    cfg.count,
        })

        workers = pairs.map do |pull, push|
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
            i = 0
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
              push_p << formatter.compress(parts) if parts && !parts.empty?
              i += 1
              break if n_count && n_count > 0 && i >= n_count
            end

            if end_proc
              result = _ctx.instance_exec(&end_proc)
              out = case result
                    when nil    then nil
                    when Array  then result
                    when String then [result]
                    else             [result.to_s]
                    end
              push_p << formatter.compress(out) if out && !out.empty?
            end
          end
        end

        workers.each do |w|
          w.value
        rescue Ractor::RemoteError => e
          $stderr.puts "omq: Ractor error: #{e.cause&.message || e.message}"
        end
      ensure
        pairs&.each { |pull, push| pull&.close; push&.close }
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
        $stderr.puts(msg) if config.verbose
      end
    end
  end
end
