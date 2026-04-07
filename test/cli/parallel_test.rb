# frozen_string_literal: true

require_relative "support"
require "securerandom"

# ── Parallel execution (-P) ──────────────────────────────────────────
#
# FIB expression (iterative, no method definition):
#   n = Integer($F.first); a,b = 0,1; n.times { a,b = b,a+b }; [a.to_s]
#
# fib(1..10) = [1, 1, 2, 3, 5, 8, 13, 21, 34, 55]  sum = 143
#
FIB_EXPR = "n=Integer($F.first);a,b=0,1;n.times{a,b=b,a+b};[a.to_s]".freeze
FIB_1_10 = [1, 1, 2, 3, 5, 8, 13, 21, 34, 55].freeze


# Unique IPC abstract address per call to avoid cross-test interference.
def ipc_url(label) = "ipc://@omq-test-#{label}-#{SecureRandom.hex(4)}"


# Run PipeRunner in a dedicated thread so Ractor#join doesn't block the
# main thread's Async scheduler (which may still exist from prior tests).
def run_pipe_runner(cfg)
  Thread.new do
    Sync do |task|
      OMQ::CLI::PipeRunner.new(cfg).call(task)
    end
  end
end


describe "pipe -P parallel execution" do
  it "routes all messages through workers and produces correct fib results" do
    work_url    = ipc_url("pipe-work")
    results_url = ipc_url("pipe-results")
    n_msgs      = 10

    cfg = make_config(
      type_name:     "pipe",
      in_endpoints:  [OMQ::CLI::Endpoint.new(work_url,    false)],
      out_endpoints: [OMQ::CLI::Endpoint.new(results_url, false)],
      parallel:      2,
      recv_expr:     FIB_EXPR,
      timeout:       3,
    )

    io_thread = Thread.new do
      Sync do
        src  = OMQ::PUSH.new(linger: 1)
        src.bind(work_url)
        sink = OMQ::PULL.new(linger: 0, recv_timeout: 5)
        sink.bind(results_url)

        src.peer_connected.wait
        (1..n_msgs).each { |n| src.send([n.to_s]) }

        n_msgs.times.map { sink.receive&.first.to_i }.sort
      ensure
        src&.close
        sink&.close
      end
    end

    runner_thread = run_pipe_runner(cfg)
    runner_thread.join
    results = io_thread.value
    assert_equal FIB_1_10, results
  end

  it "applies BEGIN/END blocks once per worker" do
    work_url    = ipc_url("pipe-begin-work")
    results_url = ipc_url("pipe-begin-results")

    expr = "BEGIN{ @s=0 } @s += Integer($F.first); nil END{ [$_=@s.to_s] }"

    cfg = make_config(
      type_name:     "pipe",
      in_endpoints:  [OMQ::CLI::Endpoint.new(work_url,    false)],
      out_endpoints: [OMQ::CLI::Endpoint.new(results_url, false)],
      parallel:      2,
      recv_expr:     expr,
      timeout:       3,
    )

    io_thread = Thread.new do
      Sync do
        src  = OMQ::PUSH.new(linger: 1)
        src.bind(work_url)
        sink = OMQ::PULL.new(linger: 0, recv_timeout: 10)
        sink.bind(results_url)

        src.peer_connected.wait
        (1..10).each { |n| src.send([n.to_s]) }

        2.times.map { sink.receive&.first.to_i }.sum
      ensure
        src&.close
        sink&.close
      end
    end

    runner_thread = run_pipe_runner(cfg)
    runner_thread.join
    total = io_thread.value
    assert_equal 55, total
  end
end
