# frozen_string_literal: true

module SDN
  module CLI
    class MQTT
      Group = Struct.new(:bridge, :addr, :position_percent, :position_pulses, :ip, :last_direction, :state, :motors) do
        def initialize(*)
          members.each { |k| self[k] = :nil }
          super
        end

        def publish(attribute, value)
          return unless self[attribute] != value

          bridge.publish("#{addr}/#{attribute.to_s.tr("_", "-")}", value.to_s)
          self[attribute] = value
        end

        def printed_addr
          Message.print_address(Message.parse_address(addr))
        end

        def motor_objects
          bridge.motors.select { |_addr, motor| motor.groups_string.include?(printed_addr) }.values
        end

        def motors_string
          motor_objects.map { |m| Message.print_address(Message.parse_address(m.addr)) }.sort.join(",")
        end
      end
    end
  end
end
