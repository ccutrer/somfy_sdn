module SDN
  class Message
    module ILT2
      class PostMotorPosition < Message
        MSG = 0x64
        PARAMS_LENGTH = 3
  
        attr_accessor :position_pulses, :position_percent
  
        def parse(params)
          super
          self.position_pulses = to_number(params[0..1])
          self.position_percent = to_number(params[2]).to_f / 255 * 100
        end
      end

      class PostMotorSettings < UnknownMessage
        MSG = 0x62
        PARAMS_LENGTH = 3

        def parse(params)
          # ???
          # example: ff 64 f4
        end
      end

      class PostMotorIP < Message
        MSG = 0x63
        PARAMS_LENGTH = 3

        attr_accessor :ip, :position_pulses

        def parse(params)
          super
          self.ip = to_number(params[0])
          self.position_pulses = to_number(params[1..2], nillable: true)
        end
      end

      class PostLockStatus < Message
        MSG = 0x6B
        PARAMS_LENGTH = 1

        attr_accessor :current_lock_priority # 0 for not locked

        def parse(params)
          super
          self.current_lock_priority = to_number(params[0])
        end
      end
    end
  end
end
