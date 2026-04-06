# frozen_string_literal: true

require "minitest/autorun"
require "securerandom"
require "omq"
require "omq/rfc/clientserver"
require "omq/rfc/radiodish"
require "omq/rfc/scattergather"
require "omq/rfc/channel"
require "omq/rfc/p2p"
require "omq/ractor"
require "async"

require "console"
Console.logger = Console::Logger.new(Console::Output::Null.new)
Warning[:experimental] = false
