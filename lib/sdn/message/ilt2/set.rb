module SDN
  class Message
    module ILT2
      class SetIRConfig < PostIRConfig
        MSG = 0x59

        def initialize(dest = nil, channels = nil, **kwargs)
          kwargs[:dest] ||= dest
          super(channels, **kwargs)
        end
      end

      class SetLockStatus < Message
        MSG = 0x5B
        PARAMS_LENGTH = 3
        TARGET_TYPE = {
          current: 0,
          up_limit: 1,
          down_limit: 2,
          ip: 4,
          unlock: 5
        }

        # when target_type is down_limit, target is number of 10ms intervals it's still allowed to roll up
        attr_reader :target_type, :target, :priority

        def initialize(dest = nil, target_type = :unlock, target = nil, priority = 1, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.target_type = target_type
          self.target = target
          self.priority = priority
        end

        def parse(params)
          super
          self.target_type = TARGET_TYPE.invert[to_number(params[0])]
          self.target = to_number(params[1])
          self.priority = to_number(params[2])
        end

        def target_type=(value)
          raise ArgumentError, "target_type must be one of :current, :up_limit, :down_limit, :ip, or :unlock" unless TARGET_TYPE.keys.include?(value)
          @target_type = value
        end

        def target=(value)
          @target = value&. & 0xff
        end

        def priority=(value)
          raise ArgumentError, "priority must be between 1 and 100" unless (1..100).include?(value)
          @priority = value
        end

        def params
          transform_param(TARGET_TYPE[target_type]) + transform_param(target) + transform_param(priority)
        end
      end

      class SetMotorIP < Message
        MSG = 0x53
        PARAMS_LENGTH = 3

        attr_reader :ip, :value

        def initialize(dest = nil, ip = 1, value = nil, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.ip = ip
          self.value = value
        end

        def parse(params)
          super
          self.ip = to_number(params[0]) + 1
          self.value = to_number(params[1..2], nillable: true)
        end

        def ip=(value)
          raise ArgumentError, "ip must be in range 1..16 or nil" unless ip.nil? || (1..16).include?(ip)
          @ip = value
        end

        def value=(value)
          @value = value &. & 0xffff
        end

        def params
          transform_param(ip - 1) + from_number(value, 2)
        end
      end

      class SetMotorLimits < UnknownMessage
        MSG = 0x5C
      end

      class SetMotorPosition < Message
        MSG = 0x54
        PARAMS_LENGTH = 3
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
          position_percent: 16,
        }.freeze

        attr_reader :target_type, :target

        def initialize(dest = nil, target_type = :up_limit, target = 0, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.target_type = target_type
          self.target = target
        end

        def parse(params)
          super
          self.target_type = TARGET_TYPE.invert[to_number(params[0])]
          target = to_number(params[1..2])
          if target_type == :position_percent
            target = target.to_f / 255 * 100
          end
          if target_type == :ip
            target += 1
          end
          self.target = target
        end

        def target_type=(value)
          raise ArgumentError, "target_type must be one of :up_limit, :down_limit, :stop, :ip, :next_ip_up, :next_ip_down, :jog_up, :jog_down, or :position_percent" unless TARGET_TYPE.keys.include?(value)
          @target_type = value
        end

        def target=(value)
          if target_type == :position_percent && value
            @target = [[0, value].max, 100].min
          else
            @target = value&. & 0xffff
          end
        end

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
        MSG = 0x52
        PARAMS_LENGTH = 5

        attr_accessor :flags, :down_limit, :position_pulses

        def initialize(dest = nil, flags = 0, down_limit = 0, position_pulses = 0, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.flags = flags
          self.down_limit = down_limit
          self.position_pulses = position_pulses
        end

        def parse(params)
          super
          self.flags = to_number(params[0])
          self.down_limit = to_number(params[1..2])
          self.position_pulses = to_number(params[3..4])
        end

        def params
          transform_param(flags) + from_number(down_limit, 2) + from_number(position_pulses, 2)
        end
      end

      class SetNodeLabel < ::SDN::Message::SetNodeLabel
        MAX_LENGTH = 32
      end
    end
  end
end
