# frozen_string_literal: true

require_relative "support"

# ── Validation ───────────────────────────────────────────────────────

describe "OMQ::CLI::CliParser.validate!" do
  def base_opts(type_name)
    {
      type_name:      type_name,
      endpoints:      [OMQ::CLI::Endpoint.new("tcp://localhost:5555", false)],
      connects:       ["tcp://localhost:5555"],
      binds:          [],
      in_endpoints:   [],
      out_endpoints:  [],
      data:           nil,
      file:           nil,
      subscribes:     [],
      joins:          [],
      group:          nil,
      identity:       nil,
      target:         nil,
    }
  end

  it "passes with valid options" do
    OMQ::CLI::CliParser.validate!(base_opts("req"))
  end

  it "rejects missing connect and bind" do
    opts = base_opts("req").merge(connects: [], binds: [])
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "rejects --data and --file together" do
    opts = base_opts("req").merge(data: "hello", file: "test.txt")
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "rejects --subscribe on non-SUB" do
    opts = base_opts("pull").merge(subscribes: ["topic"])
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "allows --subscribe on SUB" do
    OMQ::CLI::CliParser.validate!(base_opts("sub").merge(subscribes: ["topic"]))
  end

  it "rejects --join on non-DISH" do
    opts = base_opts("pull").merge(joins: ["group1"])
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "allows --join on DISH" do
    OMQ::CLI::CliParser.validate!(base_opts("dish").merge(joins: ["group1"]))
  end

  it "rejects --group on non-RADIO" do
    opts = base_opts("pub").merge(group: "weather")
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "allows --group on RADIO" do
    OMQ::CLI::CliParser.validate!(base_opts("radio").merge(group: "weather"))
  end

  it "rejects --identity on non-DEALER/ROUTER" do
    opts = base_opts("req").merge(identity: "my-id")
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "allows --identity on DEALER" do
    OMQ::CLI::CliParser.validate!(base_opts("dealer").merge(identity: "my-id"))
  end

  it "allows --identity on ROUTER" do
    OMQ::CLI::CliParser.validate!(base_opts("router").merge(identity: "my-id"))
  end

  it "rejects --target on non-ROUTER/SERVER/PEER" do
    opts = base_opts("dealer").merge(target: "peer-1")
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "allows --target on ROUTER" do
    OMQ::CLI::CliParser.validate!(base_opts("router").merge(target: "peer-1"))
  end

  it "allows --target on SERVER" do
    OMQ::CLI::CliParser.validate!(base_opts("server").merge(target: "0xdeadbeef"))
  end

  it "allows --target on PEER" do
    OMQ::CLI::CliParser.validate!(base_opts("peer").merge(target: "0xdeadbeef"))
  end

  it "rejects inproc URLs" do
    opts = base_opts("req").merge(connects: ["inproc://test"])
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  # ── --recv-eval / --send-eval validation ──────────────────────────

  it "rejects --recv-eval on send-only sockets" do
    %w[push pub scatter radio].each do |type|
      opts = base_opts(type).merge(recv_expr: "$F")
      assert_raises(SystemExit, "expected --recv-eval to be rejected for #{type}") {
        quietly { OMQ::CLI::CliParser.validate!(opts) }
      }
    end
  end

  it "rejects --send-eval on recv-only sockets" do
    %w[pull sub gather dish].each do |type|
      opts = base_opts(type).merge(send_expr: "$F")
      assert_raises(SystemExit, "expected --send-eval to be rejected for #{type}") {
        quietly { OMQ::CLI::CliParser.validate!(opts) }
      }
    end
  end

  it "rejects --send-eval combined with --target" do
    %w[router server peer].each do |type|
      opts = base_opts(type).merge(send_expr: "$F", target: "peer-1")
      assert_raises(SystemExit, "expected --send-eval + --target to be rejected for #{type}") {
        quietly { OMQ::CLI::CliParser.validate!(opts) }
      }
    end
  end

  it "allows --recv-eval on recv-only sockets" do
    %w[pull sub gather dish].each do |type|
      OMQ::CLI::CliParser.validate!(base_opts(type).merge(recv_expr: "$F"))
    end
  end

  it "allows --send-eval on send-only sockets" do
    %w[push pub scatter radio].each do |type|
      OMQ::CLI::CliParser.validate!(base_opts(type).merge(send_expr: "$F"))
    end
  end

  it "allows --send-eval on ROUTER without --target" do
    OMQ::CLI::CliParser.validate!(base_opts("router").merge(send_expr: '["id", $_]'))
  end

  it "allows both --send-eval and --recv-eval on bidirectional sockets" do
    %w[req rep pair dealer router client server peer channel].each do |type|
      next if %w[rep].include?(type) # REP send-eval may not apply but validation doesn't block it
      OMQ::CLI::CliParser.validate!(base_opts(type).merge(send_expr: "$F", recv_expr: "$F"))
    end
  end

  # ── pipe --in/--out validation ──────────────────────────────────

  def pipe_opts(**overrides)
    {
      type_name:      "pipe",
      endpoints:      [],
      connects:       [],
      binds:          [],
      in_endpoints:   [],
      out_endpoints:  [],
      data:           nil,
      file:           nil,
      subscribes:     [],
      joins:          [],
      group:          nil,
      identity:       nil,
      target:         nil,
    }.merge(overrides)
  end

  it "allows pipe with --in/--out endpoints" do
    opts = pipe_opts(
      in_endpoints:  [OMQ::CLI::Endpoint.new("ipc://@a", false)],
      out_endpoints: [OMQ::CLI::Endpoint.new("ipc://@b", false)],
    )
    OMQ::CLI::CliParser.validate!(opts)
  end

  it "allows pipe with multiple --in endpoints" do
    opts = pipe_opts(
      in_endpoints:  [OMQ::CLI::Endpoint.new("ipc://@a", false), OMQ::CLI::Endpoint.new("ipc://@b", false)],
      out_endpoints: [OMQ::CLI::Endpoint.new("ipc://@c", false)],
    )
    OMQ::CLI::CliParser.validate!(opts)
  end

  it "rejects pipe --in without --out" do
    opts = pipe_opts(in_endpoints: [OMQ::CLI::Endpoint.new("ipc://@a", false)])
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "rejects pipe --out without --in" do
    opts = pipe_opts(out_endpoints: [OMQ::CLI::Endpoint.new("ipc://@a", false)])
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "rejects pipe mixing --in/--out with bare endpoints" do
    opts = pipe_opts(
      in_endpoints: [OMQ::CLI::Endpoint.new("ipc://@a", false)],
      out_endpoints: [OMQ::CLI::Endpoint.new("ipc://@b", false)],
      endpoints: [OMQ::CLI::Endpoint.new("ipc://@c", false)],
    )
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "rejects --in/--out on non-pipe sockets" do
    opts = base_opts("req").merge(in_endpoints: [OMQ::CLI::Endpoint.new("ipc://@a", false)], out_endpoints: [])
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "allows legacy pipe with exactly 2 positional endpoints" do
    eps = [OMQ::CLI::Endpoint.new("ipc://@a", false), OMQ::CLI::Endpoint.new("ipc://@b", false)]
    opts = pipe_opts(endpoints: eps)
    OMQ::CLI::CliParser.validate!(opts)
  end

  it "passes for bare script mode (type_name nil)" do
    OMQ::CLI::CliParser.validate!(type_name: nil, scripts: ["./myscript.rb"])
  end

  it "rejects -r- combined with -F-" do
    opts = base_opts("pull").merge(scripts: [:stdin], file: "-")
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "allows -P on pipe" do
    eps = [OMQ::CLI::Endpoint.new("ipc://@a", false), OMQ::CLI::Endpoint.new("ipc://@b", false)]
    opts = pipe_opts(endpoints: eps).merge(parallel: 4)
    OMQ::CLI::CliParser.validate!(opts)
  end

  it "allows -P 1 on pipe" do
    eps = [OMQ::CLI::Endpoint.new("ipc://@a", false), OMQ::CLI::Endpoint.new("ipc://@b", false)]
    opts = pipe_opts(endpoints: eps).merge(parallel: 1)
    OMQ::CLI::CliParser.validate!(opts)
  end

  it "rejects -P 0" do
    eps = [OMQ::CLI::Endpoint.new("ipc://@a", false), OMQ::CLI::Endpoint.new("ipc://@b", false)]
    opts = pipe_opts(endpoints: eps).merge(parallel: 0)
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "rejects -P > 16" do
    eps = [OMQ::CLI::Endpoint.new("ipc://@a", false), OMQ::CLI::Endpoint.new("ipc://@b", false)]
    opts = pipe_opts(endpoints: eps).merge(parallel: 17)
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.validate!(opts) } }
  end

  it "rejects -P on non-pipe socket types" do
    %w[push pull pub sub req rep dealer router pair].each do |type|
      opts = base_opts(type).merge(parallel: 4)
      assert_raises(SystemExit, "expected rejection for #{type}") { quietly { OMQ::CLI::CliParser.validate!(opts) } }
    end
  end
end

# ── Option parsing ───────────────────────────────────────────────────

describe "OMQ::CLI::CliParser.parse" do
  it "parses socket type" do
    opts = OMQ::CLI::CliParser.parse(["req", "-c", "tcp://localhost:5555"])
    assert_equal "req", opts[:type_name]
  end

  it "parses socket type case-insensitively" do
    opts = OMQ::CLI::CliParser.parse(["REQ", "-c", "tcp://localhost:5555"])
    assert_equal "req", opts[:type_name]
  end

  it "collects multiple connects" do
    opts = OMQ::CLI::CliParser.parse(["push", "-c", "tcp://a:1", "-c", "tcp://b:2"])
    assert_equal ["tcp://a:1", "tcp://b:2"], opts[:connects]
  end

  it "collects multiple binds" do
    opts = OMQ::CLI::CliParser.parse(["pull", "-b", "tcp://:1", "-b", "tcp://:2"])
    assert_equal ["tcp://localhost:1", "tcp://localhost:2"], opts[:binds]
  end

  it "expands tcp://*:PORT to 0.0.0.0" do
    opts = OMQ::CLI::CliParser.parse(["pull", "-b", "tcp://*:1234"])
    assert_equal ["tcp://0.0.0.0:1234"], opts[:binds]
  end

  it "expands tcp://:PORT to localhost for connects" do
    opts = OMQ::CLI::CliParser.parse(["push", "-c", "tcp://:1234"])
    assert_equal ["tcp://localhost:1234"], opts[:connects]
  end

  it "parses format flags" do
    assert_equal :quoted, OMQ::CLI::CliParser.parse(["req", "-c", "tcp://x:1", "-Q"])[:format]
    assert_equal :raw,    OMQ::CLI::CliParser.parse(["req", "-c", "tcp://x:1", "--raw"])[:format]
    assert_equal :jsonl,  OMQ::CLI::CliParser.parse(["req", "-c", "tcp://x:1", "-J"])[:format]
  end

  it "parses draft type names" do
    %w[client server radio dish scatter gather channel peer].each do |type|
      opts = OMQ::CLI::CliParser.parse([type, "-c", "tcp://x:1"])
      assert_equal type, opts[:type_name]
    end
  end

  it "parses --join and --group" do
    opts = OMQ::CLI::CliParser.parse(["dish", "-b", "tcp://:1", "-j", "g1", "-j", "g2"])
    assert_equal ["g1", "g2"], opts[:joins]

    opts = OMQ::CLI::CliParser.parse(["radio", "-c", "tcp://x:1", "-g", "weather"])
    assert_equal "weather", opts[:group]
  end

  it "exits on unknown socket type" do
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.parse(["bogus", "-c", "tcp://x:1"]) } }
  end

  it "exits with no arguments" do
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.parse([]) } }
  end

  it "parses --reconnect-ivl as a fixed value" do
    opts = OMQ::CLI::CliParser.parse(["req", "-c", "tcp://x:1", "--reconnect-ivl", "0.5"])
    assert_equal 0.5, opts[:reconnect_ivl]
  end

  it "parses --reconnect-ivl as a range" do
    opts = OMQ::CLI::CliParser.parse(["req", "-c", "tcp://x:1", "--reconnect-ivl", "0.1..2"])
    assert_equal 0.1..2.0, opts[:reconnect_ivl]
  end

  it "parses -e as --recv-eval" do
    opts = OMQ::CLI::CliParser.parse(["pull", "-b", "tcp://:1", "-e", "$F.map(&:upcase)"])
    assert_equal "$F.map(&:upcase)", opts[:recv_expr]
    assert_nil opts[:send_expr]
  end

  it "parses -E as --send-eval" do
    opts = OMQ::CLI::CliParser.parse(["push", "-c", "tcp://x:1", "-E", "$F.map(&:upcase)"])
    assert_equal "$F.map(&:upcase)", opts[:send_expr]
    assert_nil opts[:recv_expr]
  end

  it "parses --recv-eval long form" do
    opts = OMQ::CLI::CliParser.parse(["pull", "-b", "tcp://:1", "--recv-eval", "$_"])
    assert_equal "$_", opts[:recv_expr]
  end

  it "parses --send-eval long form" do
    opts = OMQ::CLI::CliParser.parse(["push", "-c", "tcp://x:1", "--send-eval", "$_"])
    assert_equal "$_", opts[:send_expr]
  end

  it "parses both -e and -E together" do
    opts = OMQ::CLI::CliParser.parse(["req", "-c", "tcp://x:1", "-E", "build($_)", "-e", "parse($_)"])
    assert_equal "build($_)",  opts[:send_expr]
    assert_equal "parse($_)", opts[:recv_expr]
  end

  it "parses --in/--out modal endpoints for pipe" do
    opts = OMQ::CLI::CliParser.parse(["pipe", "--in", "-c", "ipc://@a", "-c", "ipc://@b", "--out", "-c", "ipc://@c"])
    assert_equal 2, opts[:in_endpoints].size
    assert_equal 1, opts[:out_endpoints].size
    assert_equal "ipc://@a", opts[:in_endpoints][0].url
    assert_equal "ipc://@b", opts[:in_endpoints][1].url
    assert_equal "ipc://@c", opts[:out_endpoints][0].url
    assert_empty opts[:endpoints]
  end

  it "parses --in with bind and --out with connect" do
    opts = OMQ::CLI::CliParser.parse(["pipe", "--in", "-b", "tcp://:5555", "--out", "-c", "tcp://x:5556"])
    assert opts[:in_endpoints][0].bind?
    refute opts[:out_endpoints][0].bind?
  end

  it "parses legacy pipe with bare -c (no --in/--out)" do
    opts = OMQ::CLI::CliParser.parse(["pipe", "-c", "ipc://@a", "-c", "ipc://@b"])
    assert_equal 2, opts[:endpoints].size
    assert_empty opts[:in_endpoints]
    assert_empty opts[:out_endpoints]
  end

  it "parses --crypto" do
    opts = OMQ::CLI::CliParser.parse(["req", "-c", "tcp://x:1", "--crypto", "nuckle"])
    assert_equal "nuckle", opts[:crypto]
  end

  it "defaults crypto to nil" do
    opts = OMQ::CLI::CliParser.parse(["req", "-c", "tcp://x:1"])
    assert_nil opts[:crypto]
  end

  it "parses --compress as global" do
    opts = OMQ::CLI::CliParser.parse(["push", "-c", "tcp://x:1", "--compress"])
    assert opts[:compress]
    refute opts[:compress_in]
    refute opts[:compress_out]
  end

  it "parses --compress after --in as compress_in" do
    opts = OMQ::CLI::CliParser.parse(["pipe", "--in", "-c", "tcp://x:1", "--compress", "--out", "-c", "tcp://x:2"])
    refute opts[:compress]
    assert opts[:compress_in]
    refute opts[:compress_out]
  end

  it "parses --compress after --out as compress_out" do
    opts = OMQ::CLI::CliParser.parse(["pipe", "--in", "-c", "tcp://x:1", "--out", "-c", "tcp://x:2", "--compress"])
    refute opts[:compress]
    refute opts[:compress_in]
    assert opts[:compress_out]
  end

  it "parses --compress on both sides" do
    opts = OMQ::CLI::CliParser.parse(["pipe", "--in", "-c", "tcp://x:1", "--compress", "--out", "-c", "tcp://x:2", "--compress"])
    refute opts[:compress]
    assert opts[:compress_in]
    assert opts[:compress_out]
  end

  it "parses -r as a deferred script path" do
    opts = OMQ::CLI::CliParser.parse(["-r", "./myscript.rb", "pull", "-b", "tcp://:1"])
    assert_includes opts[:scripts], File.expand_path("./myscript.rb")
    assert_nil opts[:send_expr]
  end

  it "parses -r- as a stdin script sentinel" do
    opts = OMQ::CLI::CliParser.parse(["-r-", "pull", "-b", "tcp://:1"])
    assert_includes opts[:scripts], :stdin
  end

  it "parses bare script mode (no socket type) when -r is given" do
    opts = OMQ::CLI::CliParser.parse(["-r", "./myscript.rb"])
    assert_nil opts[:type_name]
    assert_includes opts[:scripts], File.expand_path("./myscript.rb")
  end

  it "exits with no arguments and no scripts" do
    assert_raises(SystemExit) { quietly { OMQ::CLI::CliParser.parse(["-v"]) } }
  end

  it "parses --recv-maxsz as an integer" do
    opts = OMQ::CLI::CliParser.parse(["pull", "-b", "tcp://:1", "--recv-maxsz", "65536"])
    assert_equal 65536, opts[:recv_maxsz]
  end

  it "defaults recv_maxsz to nil" do
    opts = OMQ::CLI::CliParser.parse(["pull", "-b", "tcp://:1"])
    assert_nil opts[:recv_maxsz]
  end
end
