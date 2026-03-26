# frozen_string_literal: true

module SDN
  module CLI
    class MQTT
      # In-memory state container for a discovered group and its aggregated MQTT attributes.
      Group = Struct.new(:bridge,
                         :addr,
                         :position_percent,
                         :position_pulses,
                         :ip,
                         :last_direction,
                         :state,
                         :hass_state,
                         :motors) do
        def initialize(*)
          members.each { |k| self[k] = :nil }
          super
        end

        # @!visibility private
        def publish(attribute, value)
          return unless self[attribute] != value

          bridge.publish("#{addr}/#{attribute.to_s.tr("_", "-")}", value.to_s)
          self[attribute] = value
        end

        # @return [String]
        def printed_addr
          Message.print_address(Message.parse_address(addr))
        end

        # @!attribute [r] motor_objects
        #
        # @return [<SDN::CLI::MQTT::Motor>]
        def motor_objects
          bridge.motors.select { |_addr, motor| motor.groups_string.include?(printed_addr) }.values
        end

        # @!attribute [r] motors_string
        #
        # Returns the current group membership as a comma-separated motor address list.
        #
        # @return [String]
        def motors_string
          motor_objects.map { |m| Message.print_address(Message.parse_address(m.addr)) }.sort.join(",")
        end
      end
    end
  end
end
