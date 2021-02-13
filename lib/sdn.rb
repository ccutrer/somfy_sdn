require 'logger'

require 'sdn/client'
require 'sdn/message'

module SDN
  BROADCAST_ADDRESS = [0xff, 0xff, 0xff]

  class << self
    def logger
      @logger ||= begin
        Logger.new(STDOUT, :info).tap do |logger|
          logger.datetime_format = '%Y-%m-%d %H:%M:%S.%L'
          logger.formatter = proc do |severity, datetime, progname, msg|
            "#{datetime.strftime(logger.datetime_format)} [#{Process.pid}/#{Thread.current.object_id}] #{severity}: #{msg}\n"
          end
        end
      end
    end
  end
end
