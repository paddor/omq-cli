# frozen_string_literal: true

require_relative "support"

describe OMQ::CLI::Formatter do

  # -- ASCII format -------------------------------------------------

  describe "ascii" do
    before { @fmt = OMQ::CLI::Formatter.new(:ascii) }

    it "encodes single-frame message" do
      assert_equal "hello\n", @fmt.encode(["hello"])
    end

    it "encodes multipart as tab-separated" do
      assert_equal "frame1\tframe2\tframe3\n", @fmt.encode(["frame1", "frame2", "frame3"])
    end

    it "replaces non-printable bytes with dots" do
      assert_equal "hel.o\n", @fmt.encode(["hel\x00o"])
      assert_equal "ab..cd\n", @fmt.encode(["ab\x01\x02cd"])
    end

    it "preserves tabs in output" do
      assert_equal "a\tb\n", @fmt.encode(["a\tb"])
    end

    it "encodes empty message" do
      assert_equal "\n", @fmt.encode([""])
    end

    it "decodes single-frame message" do
      assert_equal ["hello"], @fmt.decode("hello\n")
    end

    it "decodes tab-separated into multipart" do
      assert_equal ["frame1", "frame2"], @fmt.decode("frame1\tframe2\n")
    end

    it "decodes empty line as empty array" do
      assert_equal [], @fmt.decode("\n")
    end

    it "round-trips printable text" do
      parts = ["hello", "world"]
      assert_equal parts, @fmt.decode(@fmt.encode(parts))
    end
  end

  # -- Quoted format ------------------------------------------------

  describe "quoted" do
    before { @fmt = OMQ::CLI::Formatter.new(:quoted) }

    it "encodes printable text unchanged" do
      assert_equal "hello world\n", @fmt.encode(["hello world"])
    end

    it "escapes newlines" do
      assert_equal "line1\\nline2\n", @fmt.encode(["line1\nline2"])
    end

    it "escapes carriage returns" do
      assert_equal "a\\rb\n", @fmt.encode(["a\rb"])
    end

    it "escapes tabs" do
      assert_equal "a\\tb\n", @fmt.encode(["a\tb"])
    end

    it "escapes backslashes" do
      assert_equal "a\\\\b\n", @fmt.encode(["a\\b"])
    end

    it "hex-escapes other non-printable bytes" do
      assert_equal "\\x00\\x01\\x7F\n", @fmt.encode(["\x00\x01\x7f"])
    end

    it "encodes multipart as tab-separated" do
      assert_equal "part1\tpart2\n", @fmt.encode(["part1", "part2"])
    end

    it "decodes escaped newlines" do
      assert_equal ["line1\nline2"], @fmt.decode("line1\\nline2\n")
    end

    it "decodes escaped carriage returns" do
      assert_equal ["a\rb"], @fmt.decode("a\\rb\n")
    end

    it "decodes escaped tabs" do
      assert_equal ["a\tb"], @fmt.decode("a\\tb\n")
    end

    it "decodes escaped backslashes" do
      assert_equal ["a\\b"], @fmt.decode("a\\\\b\n")
    end

    it "decodes hex escapes" do
      assert_equal ["\x00\xff".b], @fmt.decode("\\x00\\xFF\n").map(&:b)
    end

    it "round-trips text with special characters" do
      parts = ["line1\nline2\ttab\\back"]
      assert_equal parts, @fmt.decode(@fmt.encode(parts))
    end

    it "round-trips binary data" do
      binary = (0..255).map(&:chr).join.b
      encoded = @fmt.encode([binary])
      decoded = @fmt.decode(encoded).first.b
      assert_equal binary, decoded
    end
  end

  # -- Raw format ---------------------------------------------------

  describe "raw" do
    before { @fmt = OMQ::CLI::Formatter.new(:raw) }

    it "encodes as ZMTP frames" do
      encoded = @fmt.encode(["hello", "world"])
      assert_equal "\x01\x05hello\x00\x05world".b, encoded
    end

    it "encodes empty message" do
      assert_equal "\x00\x00".b, @fmt.encode([""])
    end

    it "decodes line as single-element array" do
      assert_equal ["hello\n"], @fmt.decode("hello\n")
    end

    it "preserves binary data" do
      binary = "\x00\x01\xff".b
      assert_equal [binary], @fmt.decode(binary)
    end
  end

  # -- JSONL format -------------------------------------------------

  describe "jsonl" do
    before { @fmt = OMQ::CLI::Formatter.new(:jsonl) }

    it "encodes as JSON array" do
      assert_equal "[\"hello\"]\n", @fmt.encode(["hello"])
    end

    it "encodes multipart as JSON array" do
      assert_equal "[\"a\",\"b\",\"c\"]\n", @fmt.encode(["a", "b", "c"])
    end

    it "encodes empty parts" do
      assert_equal "[\"\"]\n", @fmt.encode([""])
    end

    it "decodes JSON array" do
      assert_equal ["hello"], @fmt.decode("[\"hello\"]\n")
    end

    it "decodes multipart JSON array" do
      assert_equal ["a", "b"], @fmt.decode("[\"a\",\"b\"]\n")
    end

    it "round-trips multipart messages" do
      parts = ["frame1", "frame2", "frame3"]
      assert_equal parts, @fmt.decode(@fmt.encode(parts))
    end

    it "handles special JSON characters" do
      parts = ["line\nnew", "tab\there", "quote\"end"]
      assert_equal parts, @fmt.decode(@fmt.encode(parts))
    end
  end

  # -- MessagePack format ------------------------------------------

  describe "msgpack" do
    before { @fmt = OMQ::CLI::Formatter.new(:msgpack) }

    it "encodes as MessagePack" do
      encoded = @fmt.encode(["hello"])
      assert_equal ["hello"], MessagePack.unpack(encoded)
    end

    it "encodes multipart" do
      encoded = @fmt.encode(["a", "b", "c"])
      assert_equal ["a", "b", "c"], MessagePack.unpack(encoded)
    end

    it "decodes from IO stream" do
      data   = MessagePack.pack(["hello", "world"])
      io     = StringIO.new(data)
      result = @fmt.decode_msgpack(io)
      assert_equal ["hello", "world"], result
    end

    it "decodes multiple messages from stream" do
      data = MessagePack.pack(["msg1"]) + MessagePack.pack(["msg2"])
      io   = StringIO.new(data)
      assert_equal ["msg1"], @fmt.decode_msgpack(io)
      assert_equal ["msg2"], @fmt.decode_msgpack(io)
    end

    it "returns nil at EOF" do
      io = StringIO.new("")
      assert_nil @fmt.decode_msgpack(io)
    end
  end

  # -- Preview -----------------------------------------------------

  describe "preview" do
    it "renders a single printable frame" do
      assert_equal "(3B) foo", OMQ::CLI::Formatter.preview(["foo"])
    end

    it "renders an empty frame as empty string marker" do
      assert_equal "(0B) ''", OMQ::CLI::Formatter.preview([""])
    end

    it "renders REP-style envelope with leading empty delimiter (no leading pipe)" do
      # ConnSendPump emits wire-level parts [empty_delimiter, body] for REP.
      assert_equal "(1B 2F) ''|1", OMQ::CLI::Formatter.preview(["", "1"])
    end

    it "joins multiple frames with |" do
      assert_equal "(6B 2F) foo|bar", OMQ::CLI::Formatter.preview(["foo", "bar"])
    end

    it "truncates long printable frames" do
      preview = OMQ::CLI::Formatter.preview(["abcdefghijklmnop"])
      assert_equal "(16B) abcdefghijkl…", preview
    end

    it "shows byte length for binary frames" do
      assert_equal "(4B) [4B]", OMQ::CLI::Formatter.preview(["\x00\x01\x02\x03"])
    end

    it "indicates trailing parts when more than 3" do
      preview = OMQ::CLI::Formatter.preview(["a", "b", "c", "d", "e"])
      assert_equal "(5B 5F) a|b|c|…", preview
    end
  end
end
