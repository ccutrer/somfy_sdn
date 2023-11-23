# frozen_string_literal: true

require "logger"

require "sdn/client"
require "sdn/message"

module SDN
  BROADCAST_ADDRESS = [0xff, 0xff, 0xff].freeze

  class << self
    def logger=(logger)
      logger.datetime_format = "%Y-%m-%d %H:%M:%S.%L"
      logger.formatter = proc do |severity, datetime, _progname, msg|
        "#{datetime.strftime(logger.datetime_format)} " \
          "[#{Process.pid}/#{Thread.current.object_id}] " \
          "#{severity}: #{msg}\n"
      end
      @logger = logger
    end

    def logger
      self.logger = Logger.new($stdout, :info) unless @logger
      @logger
    end
  end
end
