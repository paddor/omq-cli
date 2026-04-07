# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest"
gem "rake"

gem "omq",                  path: ENV["OMQ_DEV"] ? "../omq" : nil
gem "omq-ractor",           path: ENV["OMQ_DEV"] ? "../omq-ractor" : nil
gem "omq-rfc-clientserver", path: ENV["OMQ_DEV"] ? "../omq-rfc-clientserver" : nil
gem "omq-rfc-radiodish",    path: ENV["OMQ_DEV"] ? "../omq-rfc-radiodish" : nil
gem "omq-rfc-scattergather", path: ENV["OMQ_DEV"] ? "../omq-rfc-scattergather" : nil
gem "omq-rfc-channel",      path: ENV["OMQ_DEV"] ? "../omq-rfc-channel" : nil
gem "omq-rfc-p2p",          path: ENV["OMQ_DEV"] ? "../omq-rfc-p2p" : nil
gem "protocol-zmtp",        path: ENV["OMQ_DEV"] ? "../protocol-zmtp" : nil
gem "nuckle",               path: ENV["OMQ_DEV"] ? "../nuckle" : nil

if ENV["OMQ_DEV"]
  gem "rbnacl", "~> 7.0"
  gem "zstd-ruby"
  gem "async-debug"
end
