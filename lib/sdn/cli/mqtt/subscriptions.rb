module SDN
  module CLI
    class MQTT
      module Subscriptions
        def handle_message(topic, value)
          puts "got #{value.inspect} at #{topic}"
          if (match = topic.match(%r{^#{Regexp.escape(@base_topic)}/(?<addr>\h{6})/(?<property>discover|label|control|jog-(?<jog_type>pulses|ms)|position-pulses|position-percent|ip|reset|(?<speed_type>up-speed|down-speed|slow-speed)|up-limit|down-limit|direction|ip(?<ip>\d+)-(?<ip_type>pulses|percent)|groups)/set$}))
            addr = Message.parse_address(match[:addr])
            property = match[:property]
            # not homie compliant; allows linking the position-percent property
            # directly to an OpenHAB rollershutter channel
            if property == 'position-percent' && value =~ /^(?:UP|DOWN|STOP)$/i
              property = "control"
              value = value.downcase
            end
            mqtt_addr = Message.print_address(addr).gsub('.', '')
            motor = @motors[mqtt_addr]
            is_group = Message.is_group_address?(addr)
            group = @groups[mqtt_addr]
            follow_up = motor&.node_type == :st50ilt2 ? Message::ILT2::GetMotorPosition.new(addr) :
              Message::GetMotorStatus.new(addr)
            ns = motor&.node_type == :st50ilt2 ? Message::ILT2 : Message

            message = case property
              when 'discover'
                follow_up = nil
                if value == "discover"
                  # discovery is low priority, and longer timeout
                  @mutex.synchronize do
                    @queues[2].push(MessageAndRetries.new(Message::GetNodeAddr.new(addr), 1, 2))
                    @cond.signal
                  end
                end
                nil
              when 'label'
                follow_up = Message::GetNodeLabel.new(addr)
                ns::SetNodeLabel.new(addr, value) unless is_group
              when 'control'
                case value
                when 'up', 'down'
                  (motor&.node_type == :st50ilt2 ? ns::SetMotorPosition : Message::MoveTo).
                    new(addr, "#{value}_limit".to_sym)
                when 'stop'
                  motor&.node_type == :st50ilt2 ? ns::SetMotorPosition.new(addr, :stop) : Message::Stop.new(addr)
                when 'next_ip'
                  motor&.node_type == :st50ilt2 ? ns::SetMotorPosition.new(addr, :next_ip_down) :
                    Message::MoveOf.new(addr, :next_ip)
                when 'previous_ip'
                  motor&.node_type == :st50ilt2 ? ns::SetMotorPosition.new(addr, :next_ip_up) :
                    Message::MoveOf.new(addr, :previous_ip)
                when 'wink'
                  Message::Wink.new(addr)
                when 'refresh'
                  follow_up = nil
                  (motor&.node_type == :st50ilt2 ? ns::GetMotorPosition : Message::GetMotorStatus).
                    new(addr)
                end
              when /jog-(?:pulses|ms)/
                value = value.to_i
                (motor&.node_type == :st50ilt2 ? ns::SetMotorPosition : Message::MoveOf).
                  new(addr, "jog_#{value < 0 ? :up : :down }_#{match[:jog_type]}".to_sym, value.abs)
              when 'reset'
                return unless Message::SetFactoryDefault::RESET.keys.include?(value.to_sym)
                Message::SetFactoryDefault.new(addr, value.to_sym)
              when 'position-pulses', 'position-percent', 'ip'
                if value == 'REFRESH'
                  follow_up = nil
                  (motor&.node_type == :st50ilt2 ? ns::GetMotorPosition : Message::GetMotorStatus).
                    new(addr)
                else
                  (motor&.node_type == :st50ilt2 ? ns::SetMotorPosition : Message::MoveTo).
                    new(addr, property.sub('position-', 'position_').to_sym, value.to_i)
                end
              when 'direction'
                return if is_group
                follow_up = Message::GetMotorDirection.new(addr)
                return unless %w{standard reversed}.include?(value)
                Message::SetMotorDirection.new(addr, value.to_sym)
              when 'up-limit', 'down-limit'
                return if is_group
                if %w{delete current_position jog_ms jog_pulses}.include?(value)
                  type = value.to_sym
                  value = 10
                else
                  type = :specified_position
                end
                target = property == 'up-limit' ? :up : :down
                follow_up = Message::GetMotorLimits.new(addr)
                Message::SetMotorLimits.new(addr, type, target, value.to_i)
              when /^ip\d-(?:pulses|percent)$/
                return if is_group
                ip = match[:ip].to_i
                return unless (1..16).include?(ip)
                follow_up = ns::GetMotorIP.new(addr, ip)

                if motor&.node_type == :st50ilt2
                  value = if value == 'delete'
                    nil
                  elsif value == 'current_position'
                    motor.position_pulses
                  elsif match[:ip_type] == 'pulses'
                    value.to_i
                  else
                    value.to_f / motor.down_limit * 100
                  end
                  ns::SetMotorIP.new(addr, ip, value)
                else
                  type = if value == 'delete'
                    :delete
                  elsif value == 'current_position'
                    :current_position
                  elsif match[:ip_type] == 'pulses'
                    :position_pulses
                  else
                    :position_percent
                  end
                  Message::SetMotorIP.new(addr, type, ip, value.to_i)
                end
              when 'up-speed', 'down-speed', 'slow-speed'
                return if is_group
                return unless motor
                follow_up = Message::GetMotorRollingSpeed.new(addr)
                message = Message::SetMotorRollingSpeed.new(addr,
                  up_speed: motor.up_speed,
                  down_speed: motor.down_speed,
                  slow_speed: motor.slow_speed)
                message.send(:"#{property.sub('-', '_')}=", value.to_i)
                message
              when 'groups'
                return if is_group
                return unless motor
                messages = motor.set_groups(value)
                @mutex.synchronize do
                  messages.each { |m| @queues[0].push(MessageAndRetries.new(m, 5, 0)) }
                  @cond.signal
                end
                nil
            end

            if motor
              motor.last_action = message.class if [Message::MoveTo, Message::Move, Message::Wink, Message::Stop].include?(message.class)
            end

            if message
              message.ack_requested = true if message.class.name !~ /^SDN::Message::Get/
              @mutex.synchronize do
                @queues[0].push(MessageAndRetries.new(message, 5, 0))
                if follow_up
                  @queues[1].push(MessageAndRetries.new(follow_up, 5, 1)) unless @queues[1].any? { |mr| mr.message == follow_up }
                end
                @cond.signal
              end
            end
          end
        end
      end
    end
  end
end
