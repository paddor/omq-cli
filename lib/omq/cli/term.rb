# frozen_string_literal: true

module OMQ
  module CLI
    # Stateless terminal formatting and stderr writing helpers shared
    # by every code path that emits verbose-driven log lines (event
    # monitor callbacks in BaseRunner / PipeRunner, SocketSetup attach
    # helpers, parallel/pipe Ractor workers).
    #
    # Pure module functions: no state, no instance, safe to call from
    # any thread or Ractor. Errors and abort messages do *not* go
    # through this module — they aren't logs.
    #
    module Term
      module_function


      # Returns a stderr log line prefix. At verbose >= 4, prepends an
      # ISO8601 UTC timestamp with µs precision so log traces become
      # time-correlatable. Otherwise returns the empty string.
      #
      # @param verbose [Integer]
      # @return [String]
      def log_prefix(verbose)
        return "" unless verbose && verbose >= 4
        "#{Time.now.utc.strftime("%FT%T.%6N")}Z "
      end


      # Formats one OMQ::MonitorEvent into a single log line (no
      # trailing newline).
      #
      # @param event [OMQ::MonitorEvent]
      # @param verbose [Integer]
      # @return [String]
      def format_event(event, verbose)
        prefix = log_prefix(verbose)
        case event.type
        when :message_sent
          "#{prefix}omq: >> #{Formatter.preview(event.detail[:parts])}"
        when :message_received
          "#{prefix}omq: << #{Formatter.preview(event.detail[:parts])}"
        else
          ep     = event.endpoint ? " #{event.endpoint}" : ""
          detail = event.detail ? " #{event.detail}" : ""
          "#{prefix}omq: #{event.type}#{ep}#{detail}"
        end
      end


      # Formats an "attached endpoint" log line (Bound to / Connecting to).
      #
      # @param kind [:bind, :connect]
      # @param url [String]
      # @param verbose [Integer]
      # @return [String]
      def format_attach(kind, url, verbose)
        verb = kind == :bind ? "Bound to" : "Connecting to"
        "#{log_prefix(verbose)}omq: #{verb} #{url}"
      end


      # Writes one formatted event line to +io+ (default $stderr).
      #
      # @param event [OMQ::MonitorEvent]
      # @param verbose [Integer]
      # @param io [#write] writable sink, default $stderr
      # @return [void]
      def write_event(event, verbose, io: $stderr)
        io.write("#{format_event(event, verbose)}\n")
      end


      # Writes one "Bound to / Connecting to" line to +io+
      # (default $stderr).
      #
      # @param kind [:bind, :connect]
      # @param url [String]
      # @param verbose [Integer]
      # @param io [#write]
      # @return [void]
      def write_attach(kind, url, verbose, io: $stderr)
        io.write("#{format_attach(kind, url, verbose)}\n")
      end
    end
  end
end
