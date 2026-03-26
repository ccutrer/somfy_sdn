# frozen_string_literal: true

module SDN
  class Message
    # Request for a motor's configured group address at a given slot.
    class GetGroupAddr < Message
      # (see Ack::MSG)
      MSG = 0x41
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 1

      # @!attribute [rw] group_index
      #
      # Group index in the range 1..16
      #
      # @return [Integer]
      attr_reader :group_index

      # Creates a request for a specific group slot.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param group_index [Integer] group slot to query
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, group_index = 1, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.group_index = group_index
      end

      # (see Message#parse)
      def parse(params)
        super
        self.group_index = to_number(params[0]) + 1
      end

      def group_index=(value)
        raise ArgumentError, "group_index is out of range" unless (1..16).cover?(value)

        @group_index = value
      end

      # (see Message#params)
      def params
        transform_param(group_index - 1)
      end
    end

    # Request for a motor's rotation direction setting.
    class GetMotorDirection < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x22
    end

    # Request for a motor's stored intermediate position at a given slot.
    class GetMotorIP < Message
      # (see Ack::MSG)
      MSG = 0x25
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 1

      # @!attribute [rw] ip
      #
      # Intermediate position slot being queried.
      #
      # @return [Integer]
      attr_reader :ip

      # Creates a request for a specific intermediate position slot.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param ip [Integer] intermediate position slot
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, ip = 1, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.ip = ip
      end

      # (see Message#parse)
      def parse(params)
        super
        self.ip = to_number(params[0])
      end

      def ip=(value)
        raise ArgumentError, "invalid IP #{value} (should be 1-16)" unless (1..16).cover?(value)

        @ip = value
      end

      # (see Message#params)
      def params
        transform_param(ip)
      end
    end

    # Request for a motor's configured travel limits.
    class GetMotorLimits < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x21
    end

    # Request for a motor's current position.
    class GetMotorPosition < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x0c
    end

    # Request for a motor's rolling speed configuration.
    class GetMotorRollingSpeed < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x23
    end

    # Request for a motor's current run state and last action metadata.
    class GetMotorStatus < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x0e
    end

    # Request for the current network lock state.
    class GetNetworkLock < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x26
    end

    # Discovery request for a node address, usually sent as a broadcast.
    class GetNodeAddr < Message
      # (see Ack::MSG)
      MSG = 0x40
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 0

      # Creates a node discovery request, defaulting to broadcast.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param kwargs [Hash] additional message options
      def initialize(dest = [0xff, 0xff, 0xff], **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
      end
    end

    # Request for a node's application version.
    class GetNodeAppVersion < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x74
    end

    # Request for a node's configured label.
    class GetNodeLabel < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x45
    end

    # Request for a node's serial number.
    class GetNodeSerialNumber < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x4c
    end

    # Request for a node's protocol stack version.
    class GetNodeStackVersion < SimpleRequest
      # (see Ack::MSG)
      MSG = 0x70
    end
  end
end
