# frozen_string_literal: true

module SDN
  module CLI
    class MQTT
      class PQueue < Array
        def push(obj)
          i = index { |o| o.priority > obj.priority }
          if i
            super
          else
            insert(i, obj)
          end
        end
      end
    end
  end
end
