module SDN
  class Message
    module ILT2
      class GetIRConfig < SimpleRequest
        MSG = 0x49
      end

      class GetMotorPosition < SimpleRequest
        MSG = 0x44
      end

      class GetMotorSettings < SimpleRequest
        MSG = 0x42
      end

      class GetMotorIP < Message
        MSG = 0x43
        PARAMS_LENGTH = 1

        attr_reader :ip

        def initialize(dest = nil, ip = 1, **kwargs)
          kwargs[:dest] ||= dest
          super(**kwargs)
          self.ip = ip
        end

        def ip=(value)
          raise ArgumentError, "invalid IP #{value} (should be 1-16)" unless (1..16).include?(value)
          @ip = value
        end
  
        def parse(params)
          super
          self.ip = to_number(params[0]) + 1
        end
  
        def params
          transform_param(@ip - 1)
        end
      end

      class GetLockStatus < SimpleRequest
        MSG = 0x4b
      end
    end
  end
end
