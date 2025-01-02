# frozen_string_literal: true

module SDN
  module CLI
    class MQTT
      Motor = Struct.new(:bridge,
                         :addr,
                         :node_type,
                         :label,
                         :position_pulses,
                         :position_percent,
                         :ip,
                         :state,
                         :hass_state,
                         :last_direction,
                         :last_action_source,
                         :last_action_cause,
                         :up_limit,
                         :down_limit,
                         :direction,
                         :up_speed,
                         :down_speed,
                         :slow_speed,
                         :ip1_pulses,
                         :ip1_percent,
                         :ip2_pulses,
                         :ip2_percent,
                         :ip3_pulses,
                         :ip3_percent,
                         :ip4_pulses,
                         :ip4_percent,
                         :ip5_pulses,
                         :ip5_percent,
                         :ip6_pulses,
                         :ip6_percent,
                         :ip7_pulses,
                         :ip7_percent,
                         :ip8_pulses,
                         :ip8_percent,
                         :ip9_pulses,
                         :ip9_percent,
                         :ip10_pulses,
                         :ip10_percent,
                         :ip11_pulses,
                         :ip11_percent,
                         :ip12_pulses,
                         :ip12_percent,
                         :ip13_pulses,
                         :ip13_percent,
                         :ip14_pulses,
                         :ip14_percent,
                         :ip15_pulses,
                         :ip15_percent,
                         :ip16_pulses,
                         :ip16_percent,
                         :groups,
                         :last_action,
                         :last_position_pulses) do
        def initialize(*)
          members.each { |k| self[k] = :nil }
          @groups = [].fill(nil, 0, 16)
          super
        end

        def publish(attribute, value)
          return unless self[attribute] != value

          bridge.publish("#{addr}/#{attribute.to_s.tr("_", "-")}", value.to_s)
          self[attribute] = value
        end

        def add_group(index, address)
          group = bridge.add_group(Message.print_address(address)) if address
          old_group = @groups[index - 1]
          @groups[index - 1] = address
          group&.publish(:motors, group.motors_string)
          publish(:groups, groups_string)
          bridge.touch_group(old_group) if old_group
        end

        def set_groups(groups) # rubocop:disable Naming/AccessorMethodName
          return unless /^(?:\h{2}[:.]?\h{2}[:.]?\h{2}(?:,\h{2}[:.]?\h{2}[:.]?\h{2})*)?$/i.match?(groups)

          groups = groups.split(",").sort.uniq.map do |g|
                     Message.parse_address(g)
                   end.select { |g| Message.group_address?(g) }
          groups.fill(nil, groups.length, 16 - groups.length)
          messages = []
          sdn_addr = Message.parse_address(addr)
          groups.each_with_index do |g, i|
            if @groups[i] != g
              messages << Message::SetGroupAddr.new(sdn_addr, i + 1, g).tap { |m| m.ack_requested = true }
              messages << Message::GetGroupAddr.new(sdn_addr, i + 1)
            end
          end
          messages
        end

        def groups_string
          @groups.compact.map { |g| Message.print_address(g) }.sort.uniq.join(",")
        end

        def group_objects
          groups_string.split(",").map { |addr| bridge.groups[addr.delete(".")] }
        end
      end
    end
  end
end
