# frozen_string_literal: true

module SDN
  module CLI
    class MQTT
      class PQueue < Array
        def push(obj)
          i = index { |o| o.priority > obj.priority }
          if i
            insert(i, obj)
          else
            super
          end
        end
      end
    end
  end
end
