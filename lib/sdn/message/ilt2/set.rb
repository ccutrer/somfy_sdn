# frozen_string_literal: true

module SDN
  class Message
    module ILT2
      # Command that writes the ILT2 IR channel bitmask.
      class SetIRConfig < PostIRConfig
        # (see Ack::MSG)
        MSG = 0x59

        # Creates an ILT2 IR configuration write command.
        #
        # @param dest [(Integer, Integer, Integer), nil] destination address
        # @param channels [Integer, nil] IR channel bitmask
        # @param kwargs [Hash] additional message options
        def initialize(dest = nil, channels = nil, **kwargs)
          kwargs[:dest] ||= dest
          super(channels, **kwargs)
        end
      end

      # Command that applies or clears an ILT2 lock target.
      class SetLockStatus < Message
        # (see Ack::MSG)
        MSG = 0x5B
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 3
        # Mapping from symbolic lock targets to SDN parameter values.
        TARGET_TYPE = {
          current: 0,
          up_limit: 1,
          down_limit: 2,
          ip: 4,
          unlock: 5
        }.freeze

        # @!attribute [rw] target_type
        #
        # when target_type is down_limit, target is number of 10ms intervals it's still allowed to roll up
        # Requested ILT2 lock target selector.
        #
        # @return [:current, :up_limit, :down_limit, :ip, :unlock]
        attr_reader :target_type

        # @return [Integer, nil]
        attr_reader :target

        # @return [Integer]
        attr_reader :priority

        # Creates an ILT2 lock status write command.
        #
        # @param dest [(Integer, Integer, Integer), nil] destination address
        # @param target_type [Symbol] lock target selector
        # @param target [Integer, nil] target value
        # @param priority [Integer] lock priority
        # @param kwargs [Hash] additional message options
        def initialize(dest = nil, target_type = :unlock, target = nil, priority = 1, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.target_type = target_type
          self.target = target
          self.priority = priority
        end

        # (see Message#parse)
        def parse(params)
          super
          self.target_type = TARGET_TYPE.invert[to_number(params[0])]
          self.target = to_number(params[1])
          self.priority = to_number(params[2])
        end

        def target_type=(value)
          unless TARGET_TYPE.key?(value)
            raise ArgumentError,
                  "target_type must be one of :current, :up_limit, :down_limit, :ip, or :unlock"
          end

          @target_type = value
        end

        def target=(value)
          @target = value&.& 0xff
        end

        def priority=(value)
          raise ArgumentError, "priority must be between 1 and 100" unless (1..100).cover?(value)

          @priority = value
        end

        # (see Message#params)
        def params
          transform_param(TARGET_TYPE[target_type]) + transform_param(target) + transform_param(priority)
        end
      end

      # Command that writes an ILT2 intermediate position slot.
      class SetMotorIP < Message
        # (see Ack::MSG)
        MSG = 0x53
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 3

        # @!attribute [rw] ip
        #
        # Requested ILT2 intermediate position slot in the range 1..16.
        #
        # @return [Integer, nil]
        attr_reader :ip

        # @return [Integer, nil]
        attr_reader :value

        # Creates an ILT2 intermediate position write command.
        #
        # @param dest [(Integer, Integer, Integer), nil] destination address
        # @param ip [Integer] intermediate position slot
        # @param value [Integer, nil] stored value
        # @param kwargs [Hash] additional message options
        def initialize(dest = nil, ip = 1, value = nil, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.ip = ip
          self.value = value
        end

        # (see Message#parse)
        def parse(params)
          super
          self.ip = to_number(params[0]) + 1
          self.value = to_number(params[1..2], nillable: true)
        end

        def ip=(value)
          raise ArgumentError, "ip must be in range 1..16 or nil" unless ip.nil? || (1..16).cover?(ip)

          @ip = value
        end

        def value=(value)
          @value = value&.& 0xffff
        end

        # (see Message#params)
        def params
          transform_param(ip - 1) + from_number(value, 2)
        end
      end

      # ILT2 motor-limit command whose payload is not yet decoded.
      class SetMotorLimits < UnknownMessage
        # (see Ack::MSG)
        MSG = 0x5C
      end

      # Command that moves an ILT2 motor to a specific target.
      class SetMotorPosition < Message
        # (see Ack::MSG)
        MSG = 0x54
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 3
        # Mapping from symbolic ILT2 move targets to SDN parameter values.
        TARGET_TYPE = {
          up_limit: 1,
          down_limit: 2,
          stop: 3,
          ip: 4,
          next_ip_up: 5,
          next_ip_down: 6,
          position_pulses: 8,
          jog_up_ms: 10,
          jog_down_ms: 11,
          jog_up_pulses: 12,
          jog_down_pulses: 13,
          position_percent: 16
        }.freeze

        # @!attribute [rw] target_type
        #
        # Requested ILT2 movement target selector.
        #
        # @return [:up_limit,
        #   :down_limit,
        #   :stop,
        #   :ip,
        #   :next_ip_up,
        #   :next_ip_down,
        #   :position_pulses,
        #   :jog_up_ms,
        #   :jog_down_ms,
        #   :jog_up_pulses,
        #   :jog_down_pulses,
        #   :position_percent]
        attr_reader :target_type

        # @!attribute [rw] target
        #
        # @return [Integer, Numeric, nil]
        attr_reader :target

        # Creates an ILT2 motor positioning command.
        #
        # @param dest [(Integer, Integer, Integer), nil] destination address
        # @param target_type [Symbol] target selector
        # @param target [Integer, Numeric] target value
        # @param kwargs [Hash] additional message options
        def initialize(dest = nil, target_type = :up_limit, target = 0, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.target_type = target_type
          self.target = target
        end

        # (see Message#parse)
        def parse(params)
          super
          self.target_type = TARGET_TYPE.invert[to_number(params[0])]
          target = to_number(params[1..2])
          target = target.to_f / 255 * 100 if target_type == :position_percent
          target += 1 if target_type == :ip
          self.target = target
        end

        def target_type=(value)
          unless TARGET_TYPE.key?(value)
            raise ArgumentError, "target_type must be one of :up_limit, :down_limit, " \
                                 ":stop, :ip, :next_ip_up, :next_ip_down, :jog_up, " \
                                 ":jog_down, or :position_percent"
          end

          @target_type = value
        end

        def target=(value)
          @target = if target_type == :position_percent && value
                      value.clamp(0, 100)
                    else
                      value&.& 0xffff
                    end
        end

        # (see Message#params)
        def params
          param = target
          param = (param * 255 / 100).to_i if target_type == :position_percent
          param -= 1 if target_type == :ip
          transform_param(TARGET_TYPE[target_type]) + from_number(param, 2)
        end
      end

      # the motor does not move, and just stores the new values
      # flags of 1 is reverse direction, but you have to set it every time
      class SetMotorSettings < UnknownMessage
        # (see Ack::MSG)
        MSG = 0x52
        # (see Ack::PARAMS_LENGTH)
        PARAMS_LENGTH = 5

        # @return [Integer]
        attr_accessor :flags

        # @return [Integer]
        attr_accessor :down_limit

        # @return [Integer]
        attr_accessor :position_pulses

        # Creates an ILT2 motor settings write command.
        #
        # @param dest [(Integer, Integer, Integer), nil] destination address
        # @param flags [Integer] settings flags
        # @param down_limit [Integer] configured lower limit
        # @param position_pulses [Integer] stored current position
        # @param kwargs [Hash] additional message options
        def initialize(dest = nil, flags = 0, down_limit = 0, position_pulses = 0, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.flags = flags
          self.down_limit = down_limit
          self.position_pulses = position_pulses
        end

        # (see Message#parse)
        def parse(params)
          super
          self.flags = to_number(params[0])
          self.down_limit = to_number(params[1..2])
          self.position_pulses = to_number(params[3..4])
        end

        # (see Message#params)
        def params
          transform_param(flags) + from_number(down_limit, 2) + from_number(position_pulses, 2)
        end
      end

      # ILT2 node-label write variant with a larger maximum payload.
      class SetNodeLabel < ::SDN::Message::SetNodeLabel
        # Maximum label length, in bytes
        MAX_LENGTH = 32
      end
    end
  end
end
