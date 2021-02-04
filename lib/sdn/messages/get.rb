module SDN
  class Message
    class GetMotorPosition < SimpleRequest
      MSG = 0x0c
    end

    class GetMotorStatus < SimpleRequest
      MSG = 0x0e
    end

    class GetMotorLimits < SimpleRequest
      MSG = 0x21
    end

    class GetMotorDirection < SimpleRequest
      MSG = 0x22
    end

    class GetMotorRollingSpeed < SimpleRequest
      MSG = 0x23
    end

    class GetMotorIP < Message
      MSG = 0x25
      PARAMS_LENGTH = 1

      attr_reader :ip

      def initialize(dest = nil, ip = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.ip = ip
      end

      def parse(params)
        super
        self.ip = to_number(params[0], nillable: true)
      end

      def ip=(value)
        raise ArgumentError, "invalid IP #{ip} (should be 1-16)" unless ip.nil? || (1..16).include?(ip)
        @ip = value
      end

      def params
        transform_param(@ip || 0xff)
      end
    end

    class GetGroupAddr < Message
      MSG = 0x41
      PARAMS_LENGTH = 1

      attr_reader :group_index

      def initialize(dest = nil, group_index = 0, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.group_index = group_index
      end

      def parse(params)
        super
        self.group_index = to_number(params[0])
      end

      def group_index=(value)
        raise ArgumentError, "group_index is out of range" unless (0...16).include?(value)
        @group_index = value
      end

      def params
        transform_param(group_index)
      end
    end

    class GetNodeLabel < SimpleRequest
      MSG = 0x45
    end

    class GetNodeAddr < Message
      MSG = 0x40
      PARAMS_LENGTH = 0

      def initialize(dest = [0xff, 0xff, 0xff], **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
      end
    end

    class GetNodeSerialNumber < SimpleRequest
      MSG = 0x4c
    end

    class GetNodeStackVersion < SimpleRequest
      MSG = 0x70
    end

    class GetNodeAppVersion < SimpleRequest
      MSG = 0x74
    end

  end
end
