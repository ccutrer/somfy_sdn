module SDN
  class Message
    module ILT2
      class SetMotorSettings < UnknownMessage
        MSG = 0x52
      end

      class SetMotorIP < UnknownMessage
        MSG = 0x53
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

        attr_reader :target_type, :target, :priority

        def initialize(dest = nil, target_type = :unlock, target = -1, priority = 1, **kwargs)
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
          jog_up: 10,
          jog_down: 11,
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
          transform_param(TARGET_TYPE[target_type]) + from_number(param, 2)
        end
      end
    end
  end
end
