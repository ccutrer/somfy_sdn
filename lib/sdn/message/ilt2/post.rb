# frozen_string_literal: true

module SDN
  class Message
    module ILT2
      # Response carrying the configured ILT2 IR channel bitmask.
      class PostIRConfig < Message
        # (see Ack::MSG)
        MSG = 0x69
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 1

        # @!attribute [rw] channels
        #
        # IR channel bitmask.
        #
        # @return [Integer, nil]
        attr_reader :channels

        # Creates an ILT2 IR configuration response.
        #
        # @param channels [Integer, nil] bitmask of enabled IR channels
        def initialize(channels = nil, **)
          super(**)
          self.channels = channels
        end

        def channels=(value)
          @channels = value&.& 0xff
        end

        # (see Message#parse)
        def parse(params)
          super
          self.channels = to_number(params[0])
        end

        # (see Message#params)
        def params
          transform_param(channels)
        end

        # (see Message#class_inspect)
        def class_inspect
          ", @channels=#{channels.chr.unpack1("b8")}"
        end
      end

      # Response carrying the current ILT2 lock priority.
      class PostLockStatus < Message
        # (see Ack::MSG)
        MSG = 0x6B
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 1

        # Reported lock priority, or `0` when unlocked.
        #
        # @return [Integer, nil]
        attr_accessor :priority

        # Creates an ILT2 lock status response.
        #
        # @param priority [Integer, nil] current lock priority
        def initialize(priority = nil, **)
          super(**)
          self.priority = priority
        end

        # (see Message#parse)
        def parse(params)
          super
          self.current_lock_priority = to_number(params[0])
        end

        # (see Message#params)
        def params
          transform_param(priority)
        end
      end

      # Response carrying a stored ILT2 intermediate position.
      class PostMotorIP < Message
        # (see Ack::MSG)
        MSG = 0x63
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 3

        # Reported intermediate position slot in the range 1..16.
        #
        # @return [Integer, nil]
        attr_accessor :ip

        # @return [Integer, nil]
        attr_accessor :position_pulses

        # Creates an ILT2 motor IP response.
        #
        # @param ip [Integer, nil] intermediate position slot
        # @param position_pulses [Integer, nil] stored pulse value
        def initialize(ip = nil, position_pulses = nil, **)
          super(**)
          self.ip = ip
          self.position_pulses = position_pulses
        end

        # (see Message#parse)
        def parse(params)
          super
          self.ip = to_number(params[0]) + 1
          self.position_pulses = to_number(params[1..2], nillable: true)
        end

        # (see Message#params)
        def params
          transform_param(ip - 1) + from_number(position_pulses, 2)
        end
      end

      # Response carrying an ILT2 motor's current position.
      class PostMotorPosition < Message
        # (see Ack::MSG)
        MSG = 0x64
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 3

        # @return [Integer, nil]
        attr_accessor :position_pulses

        # @return [Numeric, nil]
        attr_accessor :position_percent

        # Creates an ILT2 motor position response.
        #
        # @param position_pulses [Integer, nil] current position in pulses
        # @param position_percent [Numeric, nil] current position in percent
        def initialize(position_pulses = nil, position_percent = nil, **)
          super(**)
          self.position_pulses = position_pulses
          self.position_percent = position_percent
        end

        # (see Message#parse)
        def parse(params)
          super
          self.position_pulses = to_number(params[0..1])
          self.position_percent = to_number(params[2]).to_f / 255 * 100
        end

        # (see Message#params)
        def params
          from_number(position_pulses, 2) +
            from_number(position_percent && (position_percent * 255 / 100))
        end
      end

      # Response carrying ILT2 motor settings in a partially decoded form.
      class PostMotorSettings < UnknownMessage
        # (see Ack::MSG)
        MSG = 0x62
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 3

        # Reported configured lower limit.
        #
        # @return [Integer, nil]
        attr_accessor :limit

        # Creates an ILT2 motor settings response.
        #
        # @param limit [Integer, nil] configured lower limit
        def initialize(limit = nil, **)
          super(**)
          self.limit = limit
        end

        # (see Message#parse)
        def parse(params)
          super
          self.limit = to_number(params[1..2])
        end

        # (see Message#params)
        def params
          transform_param(0) + from_number(limit, 2)
        end
      end

      # ILT2 node-label response variant with a larger maximum payload.
      class PostNodeLabel < ::SDN::Message::PostNodeLabel
        # Maximum label length, in bytes
        MAX_LENGTH = 32
      end
    end
  end
end
