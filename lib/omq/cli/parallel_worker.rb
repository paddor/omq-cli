# frozen_string_literal: true

module OMQ
  module CLI
    # Worker that runs inside a Ractor for parallel socket modes (-P).
    # Each worker owns its own Async reactor and socket instance.
    #
    # Supported socket types:
    #   - pull, gather  (recv-only)
    #   - rep           (recv-reply with echo/data/eval)
    #
    class ParallelWorker
      def initialize(config, socket_sym, endpoints, output_port, log_port)
        @config      = config
        @socket_sym  = socket_sym
        @endpoints   = endpoints
        @output_port = output_port
        @log_port    = log_port
      end


      def call
        Async do
          setup_socket
          log_endpoints
          start_monitors
          wait_for_peer
          compile_expr
          run_loop
          run_end_block
        ensure
          @sock&.close
        end
      end


      private


      def setup_socket
        @sock = OMQ.const_get(@socket_sym).new
        OMQ::CLI::SocketSetup.apply_options(@sock, @config)
        @sock.identity = @config.identity if @config.identity
        OMQ::CLI::SocketSetup.attach_endpoints(@sock, @endpoints, verbose: false)
      end


      def log_endpoints
        return unless @config.verbose >= 1
        @endpoints.each do |ep|
          @log_port.send(ep.bind? ? "Bound to #{ep.url}" : "Connecting to #{ep.url}")
        end
      end


      def start_monitors
        return unless @config.verbose >= 2
        trace = @config.verbose >= 3
        @sock.monitor(verbose: trace) do |event|
          @log_port.send(format_event(event))
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


      def wait_for_peer
        if @config.timeout
          Fiber.scheduler.with_timeout(@config.timeout) do
            @sock.peer_connected.wait
          end
        else
          @sock.peer_connected.wait
        end
      rescue IO::TimeoutError, Async::TimeoutError
        # Proceed anyway -- recv will timeout if no messages arrive
      end


      def compile_expr
        @begin_proc, @end_proc, @eval_proc =
          OMQ::CLI::ExpressionEvaluator.compile_inside_ractor(@config.recv_expr)
        @fmt = OMQ::CLI::Formatter.new(@config.format, compress: @config.compress)
        @ctx = Object.new
        @ctx.instance_exec(&@begin_proc) if @begin_proc
      end


      def run_loop
        case @config.type_name
        when "pull", "gather"
          run_recv_loop
        when "rep"
          run_rep_loop
        end
      end


      # -- Recv-only loop (PULL, GATHER) -----------------------------------


      def run_recv_loop
        n = @config.count
        i = 0
        loop do
          parts = @sock.receive
          break if parts.nil?
          parts = @fmt.decompress(parts)
          if @eval_proc
            parts = normalize(
              @ctx.instance_exec(parts, &@eval_proc)
            )
            next if parts.nil?
          end
          output(parts) unless parts.empty?
          i += 1
          break if n && n > 0 && i >= n
        end
      rescue IO::TimeoutError, Async::TimeoutError
        # recv timed out -- fall through to END block
      end


      # -- REP loop (recv request, process, send reply) --------------------


      def run_rep_loop
        n = @config.count
        i = 0
        loop do
          parts = @sock.receive
          break if parts.nil?
          parts = @fmt.decompress(parts)
          reply = compute_reply(parts)
          output(reply)
          @sock.send(@fmt.compress(reply))
          i += 1
          break if n && n > 0 && i >= n
        end
      rescue IO::TimeoutError, Async::TimeoutError
        # recv timed out -- fall through to END block
      end


      def compute_reply(parts)
        if @eval_proc
          normalize(@ctx.instance_exec(parts, &@eval_proc)) || [""]
        elsif @config.echo
          parts
        elsif @config.data
          @fmt.decode(@config.data + "\n")
        else
          parts
        end
      end


      # -- Output and helpers ----------------------------------------------


      def output(parts)
        return if @config.quiet || parts.nil?
        @output_port.send(@fmt.encode(parts))
      end


      def normalize(result)
        OMQ::CLI::ExpressionEvaluator.normalize_result(result)
      end


      def run_end_block
        return unless @end_proc
        out = normalize(@ctx.instance_exec(&@end_proc))
        output(out) if out && !out.empty?
      end
    end
  end
end
