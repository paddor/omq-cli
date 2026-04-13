# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/omq/cli"
require "json"
require "stringio"
require "securerandom"

require "msgpack"
require "omq"
require "omq/rfc/zstd"


# Unique IPC abstract address per call to avoid cross-test interference.
def ipc_url(label) = "ipc://@omq-test-#{label}-#{SecureRandom.hex(4)}"

# Suppress stderr/stdout from abort/puts during validation tests.
def quietly
  orig_stderr = $stderr
  orig_stdout = $stdout
  $stderr = StringIO.new
  $stdout = StringIO.new
  yield
ensure
  $stderr = orig_stderr
  $stdout = orig_stdout
end


# Silence stderr only (keep $stdout intact for tests that assert on it).
def silence_stderr
  orig = $stderr
  $stderr = StringIO.new
  yield
ensure
  $stderr = orig
end

# Helper to build a minimal Config for unit tests.
def make_config(type_name:, **overrides)
  defaults = {
    type_name:       type_name,
    endpoints:       [],
    connects:        [],
    binds:           [],
    in_endpoints:    [],
    out_endpoints:   [],
    data:            nil,
    file:            nil,
    format:          :ascii,
    subscribes:      [],
    joins:           [],
    group:           nil,
    identity:        nil,
    target:          nil,
    interval:        nil,
    count:           nil,
    delay:           nil,
    timeout:         nil,
    linger:          5,
    reconnect_ivl:   nil,
    heartbeat_ivl:   nil,
    send_hwm:        nil,
    recv_hwm:        nil,
    sndbuf:          nil,
    rcvbuf:          nil,
    conflate:        false,
    compress:        false,
    compress_level:  nil,
    send_expr:       nil,
    recv_expr:       nil,
    parallel:        nil,
    transient:       false,
    verbose:         0,
    timestamps:      nil,
    quiet:           false,
    echo:            false,
    scripts:         [],
    recv_maxsz:      nil,
    curve_server:    false,
    curve_server_key: nil,
    crypto:    nil,
    ffi:             false,
    stdin_is_tty:    true,
  }
  OMQ::CLI::Config.new(**defaults.merge(overrides))
end
