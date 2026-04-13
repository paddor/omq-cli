# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest"
gem "rake"
gem "async-debug" if ENV["OMQ_DEV"]

gem "omq",                  path: ENV["OMQ_DEV"] ? "../omq" : nil
gem "omq-rfc-clientserver", path: ENV["OMQ_DEV"] ? "../omq-rfc-clientserver" : nil
gem "omq-rfc-radiodish",    path: ENV["OMQ_DEV"] ? "../omq-rfc-radiodish" : nil
gem "omq-rfc-scattergather", path: ENV["OMQ_DEV"] ? "../omq-rfc-scattergather" : nil
gem "omq-rfc-channel",      path: ENV["OMQ_DEV"] ? "../omq-rfc-channel" : nil
gem "omq-rfc-p2p",          path: ENV["OMQ_DEV"] ? "../omq-rfc-p2p" : nil
gem "omq-rfc-zstd",         path: ENV["OMQ_DEV"] ? "../omq-rfc-zstd" : nil
gem "protocol-zmtp",        path: ENV["OMQ_DEV"] ? "../protocol-zmtp" : nil
gem "nuckle",               path: ENV["OMQ_DEV"] ? "../nuckle" : nil
gem "omq-ffi",              path: "../omq-ffi", require: false if ENV["OMQ_DEV"]
gem "rzstd",                path: ENV["OMQ_DEV"] ? "../rzstd" : nil
