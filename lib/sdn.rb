# frozen_string_literal: true

require "logger"

require "sdn/client"
require "sdn/message"

# Top-level Somfy SDN module
module SDN
  # Broadcast destination address used for discovery and network-wide requests.
  BROADCAST_ADDRESS = [0xff, 0xff, 0xff].freeze

  class << self
    # @!attribute [rw] logger
    #
    # Sets a logger for use by this gem. If a logger is not set, a default logger that
    # outputs to stdout with INFO level will be used.
    #
    # @return [Logger]
    def logger=(value)
      value.datetime_format = "%Y-%m-%d %H:%M:%S.%L"
      value.formatter = proc do |severity, datetime, _progname, msg|
        "#{datetime.strftime(value.datetime_format)} " \
          "[#{Process.pid}/#{Thread.current.object_id}] " \
          "#{severity}: #{msg}\n"
      end
      @logger = value
    end

    def logger
      self.logger = Logger.new($stdout, :info) unless @logger
      @logger
    end
  end
end
