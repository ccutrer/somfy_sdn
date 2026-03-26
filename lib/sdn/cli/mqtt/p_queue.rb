# frozen_string_literal: true

module SDN
  module CLI
    class MQTT
      # Priority queue used to order outbound SDN messages by importance.
      class PQueue < Array
        # Inserts a queued item ahead of lower-priority entries.
        #
        # @param obj [Object] queued item responding to `priority`
        #
        # @return [Array] the queue itself
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
