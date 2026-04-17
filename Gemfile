# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest"
gem "rake"
gem "async-debug" if ENV["OMQ_DEV"]

gem "omq",           path: ENV["OMQ_DEV"] ? "../omq" : nil
gem "omq-zstd",      path: ENV["OMQ_DEV"] ? "../omq-zstd" : nil
gem "protocol-zmtp", path: ENV["OMQ_DEV"] ? "../protocol-zmtp" : nil
gem "nuckle",        path: ENV["OMQ_DEV"] ? "../nuckle" : nil
gem "omq-ffi",       path: "../omq-ffi", require: false if ENV["OMQ_DEV"]
gem "rzstd",         path: ENV["OMQ_DEV"] ? "../rzstd" : nil
