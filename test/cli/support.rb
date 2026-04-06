# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/omq/cli"
require "json"
require "stringio"

HAS_MSGPACK = begin
  require "msgpack"
  true
rescue LoadError
  false
end

HAS_ZSTD = begin
  require "zstd-ruby"
  true
rescue LoadError
  false
end

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
    conflate:        false,
    compress:        false,
    send_expr:       nil,
    recv_expr:       nil,
    parallel:        nil,
    transient:       false,
    verbose:         false,
    quiet:           false,
    echo:            false,
    scripts:         [],
    recv_maxsz:      nil,
    curve_server:    false,
    curve_server_key: nil,
    curve_crypto:    nil,
    has_msgpack:     false,
    has_zstd:        false,
    stdin_is_tty:    true,
  }
  OMQ::CLI::Config.new(**defaults.merge(overrides))
end
