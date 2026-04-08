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
          wait_for_peers
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
        @pull = OMQ::PULL.new
        @push = OMQ::PUSH.new
        OMQ::CLI::SocketSetup.apply_options(@pull, @config)
        OMQ::CLI::SocketSetup.apply_options(@push, @config)
        @pull.recv_hwm = PipeRunner::PIPE_HWM unless @config.recv_hwm
        @push.send_hwm = PipeRunner::PIPE_HWM unless @config.send_hwm
        OMQ::CLI::SocketSetup.attach_endpoints(@pull, @in_eps, verbose: false)
        OMQ::CLI::SocketSetup.attach_endpoints(@push, @out_eps, verbose: false)
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
          "omq: >> #{OMQ::CLI::Formatter.preview(event.detail[:parts])}"
        when :message_received
          "omq: << #{OMQ::CLI::Formatter.preview(event.detail[:parts])}"
        else
          ep = event.endpoint ? " #{event.endpoint}" : ""
          detail = event.detail ? " #{event.detail}" : ""
          "omq: #{event.type}#{ep}#{detail}"
        end
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
        # recv timed out -- fall through to END block
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
