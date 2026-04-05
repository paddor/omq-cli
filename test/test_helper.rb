# frozen_string_literal: true

require "minitest/autorun"
require "omq"
require "omq/draft/all"
require "omq/ractor"
require "async"

require "console"
Console.logger = Console::Logger.new(Console::Output::Null.new)
Warning[:experimental] = false
