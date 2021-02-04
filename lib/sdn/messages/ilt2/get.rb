module SDN
  class Message
    module ILT2
      class GetMotorPosition < SimpleRequest
        MSG = 0x44
      end

      class GetMotorSettings < SimpleRequest
        MSG = 0x42
      end

      class GetMotorIP < ::SDN::Message::GetMotorIP
        MSG = 0x43
      end

      class GetLockStatus < SimpleRequest
        MSG = 0x4b
      end
    end
  end
end
