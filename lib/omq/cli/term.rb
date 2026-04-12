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


      # Returns a stderr log line prefix with a UTC ISO8601 timestamp
      # at the requested precision (:s/:ms/:us), or "" when nil.
      #
      # @param timestamps [Symbol, nil] :s, :ms, :us, or nil (disabled)
      # @return [String]
      def log_prefix(timestamps)
        case timestamps
        when nil then ""
        when :s  then "#{Time.now.utc.strftime("%FT%T")}Z "
        when :ms then "#{Time.now.utc.strftime("%FT%T.%3N")}Z "
        when :us then "#{Time.now.utc.strftime("%FT%T.%6N")}Z "
        end
      end


      # Formats one OMQ::MonitorEvent into a single log line (no
      # trailing newline).
      #
      # @param event [OMQ::MonitorEvent]
      # @param timestamps [Symbol, nil]
      # @return [String]
      def format_event(event, timestamps)
        prefix = log_prefix(timestamps)
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
      # @param timestamps [Symbol, nil]
      # @return [String]
      def format_attach(kind, url, timestamps)
        verb = kind == :bind ? "Bound to" : "Connecting to"
        "#{log_prefix(timestamps)}omq: #{verb} #{url}"
      end


      # Writes one formatted event line to +io+ (default $stderr).
      #
      # @param event [OMQ::MonitorEvent]
      # @param timestamps [Symbol, nil]
      # @param io [#write] writable sink, default $stderr
      # @return [void]
      def write_event(event, timestamps, io: $stderr)
        io.write("#{format_event(event, timestamps)}\n")
      end


      # Writes one "Bound to / Connecting to" line to +io+
      # (default $stderr).
      #
      # @param kind [:bind, :connect]
      # @param url [String]
      # @param timestamps [Symbol, nil]
      # @param io [#write]
      # @return [void]
      def write_attach(kind, url, timestamps, io: $stderr)
        io.write("#{format_attach(kind, url, timestamps)}\n")
      end
    end
  end
end
