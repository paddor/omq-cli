# frozen_string_literal: true

require_relative "support"

# -- Output ----------------------------------------------------------

describe "output" do
  before do
    @runner = OMQ::CLI::PullRunner.new(
      make_config(type_name: "pull"),
      OMQ::PULL
    )
  end

  it "skips nil parts" do
    out = StringIO.new
    $stdout = out
    @runner.send(:output, nil)
    $stdout = STDOUT
    assert_equal "", out.string
  end

  it "prints message parts" do
    out = StringIO.new
    $stdout = out
    @runner.send(:output, ["hello"])
    $stdout = STDOUT
    assert_equal "hello\n", out.string
  end
end


# -- Grace period with Range reconnect_interval ---------------------

describe "wait_for_peer grace period with range reconnect_ivl" do
  it "uses Range#begin for the grace sleep" do
    Sync do
      push = OMQ::PUSH.new(linger: 0)
      push.reconnect_interval = 0.05..1.0
      push.bind("tcp://127.0.0.1:0")
      port = push.last_tcp_port

      pull = OMQ::PULL.new(linger: 0)
      pull.connect("tcp://127.0.0.1:#{port}")

      config = make_config(
        type_name: "push",
        reconnect_ivl: 0.05..1.0,
        binds: ["tcp://127.0.0.1:#{port}"],
      )
      runner = OMQ::CLI::PushRunner.new(config, OMQ::PUSH)
      runner.instance_variable_set(:@sock, push)

      # Should not raise TypeError from sleep(Range)
      runner.send(:wait_for_peer)
    ensure
      push&.close
      pull&.close
    end
  end
end

# -- Config ----------------------------------------------------------

describe "OMQ::CLI::Config" do
  it "is frozen" do
    config = make_config(type_name: "push")
    assert config.frozen?
  end

  it "knows send-only types" do
    assert make_config(type_name: "push").send_only?
    assert make_config(type_name: "pub").send_only?
    assert make_config(type_name: "scatter").send_only?
    assert make_config(type_name: "radio").send_only?
    refute make_config(type_name: "pull").send_only?
  end

  it "knows recv-only types" do
    assert make_config(type_name: "pull").recv_only?
    assert make_config(type_name: "sub").recv_only?
    assert make_config(type_name: "gather").recv_only?
    assert make_config(type_name: "dish").recv_only?
    refute make_config(type_name: "push").recv_only?
  end
end
