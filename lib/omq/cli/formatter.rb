# frozen_string_literal: true

module OMQ
  module CLI
    # Raised when Zstandard decompression fails.
    class DecompressError < RuntimeError; end

    # Handles encoding/decoding messages in the configured format,
    # plus optional Zstandard compression.
    class Formatter
      # @param format [Symbol] wire format (:ascii, :quoted, :raw, :jsonl, :msgpack, :marshal)
      # @param compress [Boolean] whether to apply Zstandard compression per frame
      def initialize(format, compress: false)
        @format   = format
        @compress = compress
      end


      # Encodes message parts into a printable string for output.
      #
      # @param parts [Array<String>] message frames
      # @return [String] formatted output line
      def encode(parts)
        case @format
        when :ascii
          parts.map { |p| p.b.gsub(/[^[:print:]\t]/, ".") }.join("\t") + "\n"
        when :quoted
          parts.map { |p| p.b.dump[1..-2] }.join("\t") + "\n"
        when :raw
          parts.each_with_index.map do |p, i|
            Protocol::ZMTP::Codec::Frame.new(p.to_s, more: i < parts.size - 1).to_wire
          end.join
        when :jsonl
          JSON.generate(parts) + "\n"
        when :msgpack
          MessagePack.pack(parts)
        when :marshal
          parts.map(&:inspect).join("\t") + "\n"
        end
      end


      # Decodes a formatted input line into message parts.
      #
      # @param line [String] input line (newline-terminated)
      # @return [Array<String>] message frames
      def decode(line)
        case @format
        when :ascii, :marshal
          line.chomp.split("\t")
        when :quoted
          line.chomp.split("\t").map { |p| "\"#{p}\"".undump }
        when :raw
          [line]
        when :jsonl
          arr = JSON.parse(line.chomp)
          abort "JSON Lines input must be an array of strings" unless arr.is_a?(Array) && arr.all? { |e| e.is_a?(String) }
          arr
        end
      end


      # Decodes one Marshal object from the given IO stream.
      #
      # @param io [IO] input stream
      # @return [Object, nil] deserialized object, or nil on EOF
      def decode_marshal(io)
        Marshal.load(io)
      rescue EOFError, TypeError
        nil
      end


      # Decodes one MessagePack object from the given IO stream.
      #
      # @param io [IO] input stream
      # @return [Object, nil] deserialized object, or nil on EOF
      def decode_msgpack(io)
        @msgpack_unpacker ||= MessagePack::Unpacker.new(io)
        @msgpack_unpacker.read
      rescue EOFError
        nil
      end


      # Compresses each frame with Zstandard if compression is enabled.
      #
      # @param parts [Array<String>] message frames
      # @return [Array<String>] optionally compressed frames
      def compress(parts)
        @compress ? parts.map { |p| Zstd.compress(p) } : parts
      end


      # Decompresses each frame with Zstandard if compression is enabled.
      #
      # @param parts [Array<String>] possibly compressed message frames
      # @return [Array<String>] decompressed frames
      def decompress(parts)
        @compress ? parts.map { |p| Zstd.decompress(p) } : parts
      rescue
        raise DecompressError, "decompression failed (did the sender use --compress?)"
      end


      # Formats message parts for human-readable preview (logging).
      #
      # @param parts [Array<String>] message frames
      # @return [String] truncated preview of each frame joined by |
      def self.preview(parts)
        total = parts.sum(&:bytesize)
        shown = parts.first(3).map { |p| preview_frame(p) }
        tail = parts.size > 3 ? "|...(#{parts.size} parts)" : ""
        "(#{total}B) #{shown.join("|")}#{tail}"
      end


      def self.preview_frame(part)
        bytes = part.b
        sample = bytes[0, 12]
        printable = sample.count("\x20-\x7e")
        if printable < sample.bytesize / 2
          "[#{bytes.bytesize}B]"
        elsif bytes.bytesize > 12
          "#{sample.gsub(/[^[:print:]]/, ".")}..."
        else
          sample.gsub(/[^[:print:]]/, ".")
        end
      end
    end
  end
end
