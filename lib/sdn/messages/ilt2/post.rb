module SDN
  class Message
    module ILT2
      class PostIRConfig < Message
        MSG = 0x69
        PARAMS_LENGTH = 1

        attr_reader :channels

        def initialize(channels = nil, **kwargs)
          super(**kwargs)
          self.channels = channels
        end

        def channels=(value)
          @channels = value &. & 0xff
        end

        def parse(params)
          super
          self.channels = to_number(params[0])
        end

        def params
          transform_param(channels)
        end

        def class_inspect
          ", @channels=#{channels.chr.unpack('b8').first}"
        end
      end

      class PostMotorPosition < Message
        MSG = 0x64
        PARAMS_LENGTH = 3
  
        attr_accessor :position_pulses, :position_percent
  
        def initialize(position_pulses = nil, position_percent = nil, **kwargs)
          super(**kwargs)
          self.position_pulses = position_pulses
          self.position_percent = position_percent
        end

        def parse(params)
          super
          self.position_pulses = to_number(params[0..1])
          self.position_percent = to_number(params[2]).to_f / 255 * 100
        end

        def params
          from_number(position_pulses, 2) +
            from_number(position_percent && position_percent * 255 / 100)
        end
      end

      class PostMotorSettings < UnknownMessage
        MSG = 0x62
        PARAMS_LENGTH = 3

        attr_accessor :limit

        def initialize(limit = nil, **kwargs)
          super(**kwargs)
          self.limit = limit
        end

        def parse(params)
          super
          self.limit = to_number(params[1..2])
        end

        def params
          transform_param(0) + from_number(limit, 2)
        end
      end

      class PostMotorIP < Message
        MSG = 0x63
        PARAMS_LENGTH = 3

        attr_accessor :ip, :position_pulses

        def initialize(ip = nil, position_pulses = nil, **kwargs)
          super(**kwargs)
          self.ip = ip
          self.position_pulses = position_pulses
        end

        def parse(params)
          super
          self.ip = to_number(params[0]) + 1
          self.position_pulses = to_number(params[1..2], nillable: true)
        end

        def params
          transform_param(ip - 1) + from_number(position_pulses, 2)
        end
      end

      class PostLockStatus < Message
        MSG = 0x6B
        PARAMS_LENGTH = 1

        attr_accessor :priority # 0 for not locked

        def initialize(priority = nil, **kwargs)
          super(**kwargs)
          self.priority = priority
        end

        def parse(params)
          super
          self.current_lock_priority = to_number(params[0])
        end

        def params
          transform_param(priority)
        end
      end

      class PostNodeLabel < ::SDN::Message::PostNodeLabel
        MAX_LENGTH = 32
      end
    end
  end
end
