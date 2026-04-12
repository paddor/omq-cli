# frozen_string_literal: true

module OMQ
  module CLI
    # Worker that runs inside a Ractor for pipe -P parallel mode.
    # Each worker owns its own Async reactor, PULL socket, and PUSH socket.
    #
    class PipeWorker
      def initialize(config, in_eps, out_eps, log_port, error_port = nil)
        @config     = config
        @in_eps     = in_eps
        @out_eps    = out_eps
        @log_port   = log_port
        @error_port = error_port
      end


      def call
        Async do
          setup_sockets
          log_endpoints if @config.verbose >= 1
          start_monitors if @config.verbose >= 2
          wait_for_peers_with_timeout if @config.timeout
          compile_expr
          run_message_loop
          run_end_block
        rescue OMQ::CLI::DecompressError => e
          @error_port&.send(e.message)
        ensure
          @pull&.close
          @push&.close
        end
      end


      private


      def setup_sockets
        kwargs = @config.ffi ? { backend: :ffi } : {}
        @pull = OMQ::PULL.new(**kwargs)
        @push = OMQ::PUSH.new(**kwargs)
        OMQ::CLI::SocketSetup.apply_options(@pull, @config)
        OMQ::CLI::SocketSetup.apply_options(@push, @config)
        OMQ::CLI::SocketSetup.attach_endpoints(@pull, @in_eps, verbose: 0)
        OMQ::CLI::SocketSetup.attach_endpoints(@push, @out_eps, verbose: 0)
      end


      def log_endpoints
        (@in_eps + @out_eps).each do |ep|
          @log_port.send(OMQ::CLI::Term.format_attach(ep.bind? ? :bind : :connect, ep.url, @config.timestamps))
        end
      end


      def start_monitors
        # When compress is on, messages are traced explicitly in
        # run_message_loop post-decompression; keep engine-level
        # traces off to avoid showing compressed bytes.
        compress = @config.compress || @config.compress_in || @config.compress_out
        trace    = @config.verbose >= 3 && !compress
        [@pull, @push].each do |sock|
          sock.monitor(verbose: trace) do |event|
            @log_port.send(OMQ::CLI::Term.format_event(event, @config.timestamps))
          end
        end
      end


      def trace_in(parts, wire)
        return unless @config.verbose >= 3 && (@config.compress || @config.compress_in)
        @log_port.send("#{OMQ::CLI::Term.log_prefix(@config.timestamps)}omq: << #{OMQ::CLI::Formatter.preview(parts, wire_size: wire.sum(&:bytesize))}")
      end


      def trace_out(parts, wire)
        return unless @config.verbose >= 3 && (@config.compress || @config.compress_out)
        @log_port.send("#{OMQ::CLI::Term.log_prefix(@config.timestamps)}omq: >> #{OMQ::CLI::Formatter.preview(parts, wire_size: wire.sum(&:bytesize))}")
      end


      # With --timeout set, fail fast if peers never show up. Without
      # it, there's no point waiting: PULL#receive blocks naturally
      # and PUSH buffers up to send_hwm when no peer is present.
      def wait_for_peers_with_timeout
        Fiber.scheduler.with_timeout(@config.timeout) do
          Barrier do |barrier|
            barrier.async { @pull.peer_connected.wait }
            barrier.async { @push.peer_connected.wait }
          end
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
            n.times { break unless process_one_eval }
          else
            loop { break unless process_one_eval }
          end
        else
          if n && n > 0
            n.times { break unless process_one_passthrough }
          else
            loop { break unless process_one_passthrough }
          end
        end
      rescue IO::TimeoutError, Async::TimeoutError
        # recv timed out -- fall through to END block
      end


      def process_one_eval
        wire_in = @pull.receive
        return false if wire_in.nil?
        parts_in = @fmt_in.decompress(wire_in)
        trace_in(parts_in, wire_in)
        parts_out = OMQ::CLI::ExpressionEvaluator.normalize_result(
          @ctx.instance_exec(parts_in, &@eval_proc), format: @config.format
        )
        return true if parts_out.nil? || parts_out.empty?
        wire_out = @fmt_out.compress(parts_out)
        trace_out(parts_out, wire_out)
        @push << wire_out
        true
      end


      def process_one_passthrough
        wire_in = @pull.receive
        return false if wire_in.nil?
        parts_in = @fmt_in.decompress(wire_in)
        trace_in(parts_in, wire_in)
        wire_out = @fmt_out.compress(parts_in)
        trace_out(parts_in, wire_out)
        @push << wire_out
        true
      end


      def run_end_block
        return unless @end_proc
        out = OMQ::CLI::ExpressionEvaluator.normalize_result(
          @ctx.instance_exec(&@end_proc), format: @config.format
        )
        @push << @fmt_out.compress(out) if out && !out.empty?
      end
    end
  end
end
