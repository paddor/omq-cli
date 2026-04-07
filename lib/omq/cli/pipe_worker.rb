# frozen_string_literal: true

module OMQ
  module CLI
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
