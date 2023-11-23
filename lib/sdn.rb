require 'logger'

require 'sdn/client'
require 'sdn/message'

module SDN
  BROADCAST_ADDRESS = [0xff, 0xff, 0xff]

  class << self
    def logger=(logger)
      logger.datetime_format = '%Y-%m-%d %H:%M:%S.%L'
      logger.formatter = proc do |severity, datetime, progname, msg|
        "#{datetime.strftime(logger.datetime_format)} [#{Process.pid}/#{Thread.current.object_id}] #{severity}: #{msg}\n"
      end
      @logger = logger
    end

    def logger
      unless @logger
        self.logger = Logger.new(STDOUT, :info)
      end
      @logger
    end
  end
end
