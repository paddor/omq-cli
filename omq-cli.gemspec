# frozen_string_literal: true

require_relative "lib/omq/cli/version"

Gem::Specification.new do |s|
  s.name     = "omq-cli"
  s.version  = OMQ::CLI::VERSION
  s.authors  = ["Patrik Wenger"]
  s.email    = ["paddor@gmail.com"]
  s.summary  = "ZeroMQ CLI — pipe, filter, and transform messages from the terminal"
  s.description = "Command-line tool for sending and receiving ZeroMQ messages " \
                  "on any socket type (REQ/REP, PUB/SUB, PUSH/PULL, " \
                  "DEALER/ROUTER, and all draft types). Supports Ruby eval " \
                  "(-e/-E), script handlers (-r), pipe virtual socket with " \
                  "Ractor parallelism, multiple formats (ASCII, JSON Lines, " \
                  "msgpack, Marshal), LZ4 compression, and CURVE encryption. " \
                  "Like nngcat from libnng, but with Ruby superpowers."
  s.homepage = "https://github.com/paddor/omq-cli"
  s.license  = "ISC"

  s.required_ruby_version = ">= 4.0"

  s.files      = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "CHANGELOG.md"]
  s.bindir     = "exe"
  s.executables = ["omq"]

  s.add_dependency "omq",                   "~> 0.17", ">= 0.17.7"
  s.add_dependency "omq-ffi",               "~> 0.2"
  s.add_dependency "omq-rfc-clientserver",  "~> 0.1"
  s.add_dependency "omq-rfc-radiodish",     "~> 0.1"
  s.add_dependency "omq-rfc-scattergather", "~> 0.1"
  s.add_dependency "omq-rfc-channel",       "~> 0.1"
  s.add_dependency "omq-rfc-p2p",           "~> 0.1"
  s.add_dependency "msgpack"
  s.add_dependency "rbnacl",                "~> 7.0"
  s.add_dependency "rlz4",                  "~> 0.1"
end
