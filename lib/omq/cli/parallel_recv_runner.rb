# frozen_string_literal: true

module OMQ
  module CLI
    # Manages N OMQ::Ractor workers for parallel recv-eval.
    #
    # Each worker gets its own input socket connecting to the external
    # endpoints; ZMQ distributes work naturally. Results are collected via
    # an inproc PULL back to the main task for output.
    #
    class ParallelRecvRunner
      # @param klass [Class] OMQ socket class for worker input sockets
      # @param config [Config] frozen CLI configuration
      # @param fmt [Formatter] message formatter
      # @param output_fn [Method] callable for writing output
      def initialize(klass, config, fmt, output_fn)
        @klass     = klass
        @config    = config
        @fmt       = fmt
        @output_fn = output_fn
      end


      # Spawns N Ractor workers, distributes incoming messages, and collects results.
      #
      # @param task [Async::Task] parent async task
      # @return [void]
      def run(task)
        cfg       = @config
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
          sock = SocketSetup.build(@klass, cfg)
          SocketSetup.setup_subscriptions(sock, cfg)
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
            begin_proc, end_proc, eval_proc =
              OMQ::CLI::ExpressionEvaluator.compile_inside_ractor(d[:recv_src])

            formatter = OMQ::CLI::Formatter.new(d[:fmt_sym], compress: d[:fmt_compr])
            # Use a dedicated context object so @ivar expressions in BEGIN/END/eval
            # work inside Ractors (self in a Ractor is shareable; Object.new is not).
            _ctx = Object.new
            _ctx.instance_exec(&begin_proc) if begin_proc

            if eval_proc
              loop do
                parts = pull_p.receive
                break if parts.nil?
                parts = OMQ::CLI::ExpressionEvaluator.normalize_result(
                  _ctx.instance_exec(formatter.decompress(parts), &eval_proc)
                )
                next if parts.nil?
                push_p << parts unless parts.empty?
              end
            else
              loop do
                parts = pull_p.receive
                break if parts.nil?
                push_p << formatter.decompress(parts)
              end
            end

            if end_proc
              out = OMQ::CLI::ExpressionEvaluator.normalize_result(
                _ctx.instance_exec(&end_proc)
              )
              push_p << out if out && !out.empty?
            end
          end
        end


        # Collect loop: drain inproc PULL → output
        n_count = cfg.count
        if n_count && n_count > 0
          n_count.times do
            parts = collector.receive
            break if parts.nil?
            @output_fn.call(parts)
          end
        else
          loop do
            parts = collector.receive
            break if parts.nil?
            @output_fn.call(parts)
          end
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


      private


      def with_timeout(seconds)
        if seconds
          Async::Task.current.with_timeout(seconds) { yield }
        else
          yield
        end
      end
    end
  end
end
