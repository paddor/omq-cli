# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest"
gem "rake"

gem "omq",           path: ENV["OMQ_DEV"] ? "../omq" : nil
gem "omq-draft",     path: ENV["OMQ_DEV"] ? "../omq-draft" : nil
gem "omq-ractor",    path: ENV["OMQ_DEV"] ? "../omq-ractor" : nil
gem "protocol-zmtp", path: ENV["OMQ_DEV"] ? "../protocol-zmtp" : nil
gem "nuckle",        path: ENV["OMQ_DEV"] ? "../nuckle" : nil

if ENV["OMQ_DEV"]
  gem "rbnacl", "~> 7.0"
end
