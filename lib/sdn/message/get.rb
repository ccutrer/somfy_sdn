# frozen_string_literal: true

module SDN
  class Message
    class GetGroupAddr < Message
      MSG = 0x41
      PARAMS_LENGTH = 1

      attr_reader :group_index

      def initialize(dest = nil, group_index = 1, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.group_index = group_index
      end

      def parse(params)
        super
        self.group_index = to_number(params[0]) + 1
      end

      def group_index=(value)
        raise ArgumentError, "group_index is out of range" unless (1..16).cover?(value)

        @group_index = value
      end

      def params
        transform_param(group_index - 1)
      end
    end

    class GetMotorDirection < SimpleRequest
      MSG = 0x22
    end

    class GetMotorIP < Message
      MSG = 0x25
      PARAMS_LENGTH = 1

      attr_reader :ip

      def initialize(dest = nil, ip = 1, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.ip = ip
      end

      def parse(params)
        super
        self.ip = to_number(params[0])
      end

      def ip=(value)
        raise ArgumentError, "invalid IP #{value} (should be 1-16)" unless (1..16).cover?(value)

        @ip = value
      end

      def params
        transform_param(ip)
      end
    end

    class GetMotorLimits < SimpleRequest
      MSG = 0x21
    end

    class GetMotorPosition < SimpleRequest
      MSG = 0x0c
    end

    class GetMotorRollingSpeed < SimpleRequest
      MSG = 0x23
    end

    class GetMotorStatus < SimpleRequest
      MSG = 0x0e
    end

    class GetNetworkLock < SimpleRequest
      MSG = 0x26
    end

    class GetNodeAddr < Message
      MSG = 0x40
      PARAMS_LENGTH = 0

      def initialize(dest = [0xff, 0xff, 0xff], **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
      end
    end

    class GetNodeAppVersion < SimpleRequest
      MSG = 0x74
    end

    class GetNodeLabel < SimpleRequest
      MSG = 0x45
    end

    class GetNodeSerialNumber < SimpleRequest
      MSG = 0x4c
    end

    class GetNodeStackVersion < SimpleRequest
      MSG = 0x70
    end
  end
end
