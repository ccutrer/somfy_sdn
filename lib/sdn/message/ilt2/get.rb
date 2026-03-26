# frozen_string_literal: true

module SDN
  class Message
    # ILT2-specific message namespace.
    module ILT2
      # Request for the configured IR channel bitmask.
      class GetIRConfig < SimpleRequest
        # (see Ack::MSG)
        MSG = 0x49
      end

      # Request for the current ILT2 lock status.
      class GetLockStatus < SimpleRequest
        # (see Ack::MSG)
        MSG = 0x4b
      end

      # Request for an ILT2 intermediate position at a given slot.
      class GetMotorIP < Message
        # (see Ack::MSG)
        MSG = 0x43
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 1

        # @!attribute [rw] ip
        #
        # Intermediate position slot being queried in the range 1..16.
        #
        # @return [Integer]
        attr_reader :ip

        # Creates an ILT2 request for a specific intermediate position slot.
        #
        # @param dest [(Integer, Integer, Integer), nil] destination address
        # @param ip [Integer] intermediate position slot
        # @param kwargs [Hash] additional message options
        def initialize(dest = nil, ip = 1, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.ip = ip
        end

        def ip=(value)
          raise ArgumentError, "invalid IP #{value} (should be 1-16)" unless (1..16).cover?(value)

          @ip = value
        end

        # (see Message#parse)
        def parse(params)
          super
          self.ip = to_number(params[0]) + 1
        end

        # (see Message#params)
        def params
          transform_param(@ip - 1)
        end
      end

      # Request for an ILT2 motor's current position.
      class GetMotorPosition < SimpleRequest
        # (see Ack::MSG)
        MSG = 0x44
      end

      # Request for ILT2 motor settings such as the configured limit.
      class GetMotorSettings < SimpleRequest
        # (see Ack::MSG)
        MSG = 0x42
      end
    end
  end
end
