module SDN
  module CLI
    class MQTT
      module Read
        def read
          loop do
            begin
              @sdn.receive do |message|
                SDN.logger.info "read #{message.inspect}"

                src = Message.print_address(message.src)
                # ignore the UAI Plus and ourselves
                if src != '7F.7F.7F' && !Message.is_group_address?(message.src) && !(motor = @motors[src.gsub('.', '')])
                  SDN.logger.info "found new motor #{src}"
                  motor = publish_motor(src.gsub('.', ''), message.node_type)
                end

                follow_ups = []
                case message
                when Message::PostNodeLabel
                  if (motor.publish(:label, message.label))
                    publish("#{motor.addr}/$name", message.label)
                  end
                when Message::PostMotorPosition,
                  Message::ILT2::PostMotorPosition
                  if message.is_a?(Message::ILT2::PostMotorPosition)
                    # keep polling while it's still moving; check prior two positions
                    if motor.position_pulses == message.position_pulses &&
                      motor.last_position_pulses == message.position_pulses
                      motor.publish(:state, :stopped)
                    else
                      motor.publish(:state, :running)
                      if motor.position_pulses && motor.position_pulses != message.position_pulses
                        motor.publish(:last_direction, motor.position_pulses < message.position_pulses ? :down : :up)
                      end
                      follow_ups << Message::ILT2::GetMotorPosition.new(message.src)
                    end
                    motor.last_position_pulses = motor.position_pulses
                    ip = (1..16).find do |i|
                      # divide by 5 for some leniency
                      motor["ip#{i}_pulses"].to_i / 5 == message.position_pulses / 5
                    end
                    motor.publish(:ip, ip)
                  end
                  motor.publish(:position_percent, message.position_percent)
                  motor.publish(:position_pulses, message.position_pulses)
                  motor.publish(:ip, message.ip) if message.respond_to?(:ip)
                  motor.group_objects.each do |group|
                    positions_percent = group.motor_objects.map(&:position_percent)
                    positions_pulses = group.motor_objects.map(&:position_pulses)
                    ips = group.motor_objects.map(&:ip)

                    position_percent = nil
                    # calculate an average, but only if we know a position for
                    # every shade
                    if !positions_percent.include?(:nil) && !positions_percent.include?(nil)
                      position_percent = positions_percent.inject(&:+) / positions_percent.length
                    end

                    position_pulses = nil
                    if !positions_pulses.include?(:nil) && !positions_pulses.include?(nil)
                      position_pulses = positions_pulses.inject(&:+) / positions_pulses.length
                    end

                    ip = nil
                    ip = ips.first if ips.uniq.length == 1
                    ip = nil if ip == :nil

                    group.publish(:position_percent, position_percent)
                    group.publish(:position_pulses, position_pulses)
                    group.publish(:ip, ip)
                  end
                when Message::PostMotorStatus
                  if message.state == :running || motor.state == :running ||
                    # if it's explicitly stopped, but we didn't ask it to, it's probably
                    # changing directions so keep querying
                    (message.state == :stopped &&
                      message.last_action_cause == :explicit_command &&
                      !(motor.last_action == Message::Stop || motor.last_action.nil?))
                    follow_ups << Message::GetMotorStatus.new(message.src)
                  end
                  # this will do one more position request after it stopped
                  follow_ups << Message::GetMotorPosition.new(message.src)
                  motor.publish(:state, message.state)
                  motor.publish(:last_direction, message.last_direction)
                  motor.publish(:last_action_source, message.last_action_source)
                  motor.publish(:last_action_cause, message.last_action_cause)
                  motor.group_objects.each do |group|
                    states = group.motor_objects.map(&:state).uniq
                    state = states.length == 1 ? states.first : 'mixed'
                    group.publish(:state, state)

                    directions = group.motor_objects.map(&:last_direction).uniq
                    direction = directions.length == 1 ? directions.first : 'mixed'
                    group.publish(:last_direction, direction)
                  end
                when Message::PostMotorLimits
                  motor.publish(:up_limit, message.up_limit)
                  motor.publish(:down_limit, message.down_limit)
                when Message::ILT2::PostMotorSettings
                  motor.publish(:down_limit, message.limit)
                when Message::PostMotorDirection
                  motor.publish(:direction, message.direction)
                when Message::PostMotorRollingSpeed
                  motor.publish(:up_speed, message.up_speed)
                  motor.publish(:down_speed, message.down_speed)
                  motor.publish(:slow_speed, message.slow_speed)
                when Message::PostMotorIP,
                  Message::ILT2::PostMotorIP
                  motor.publish(:"ip#{message.ip}_pulses", message.position_pulses)
                  if message.respond_to?(:position_percent)
                    motor.publish(:"ip#{message.ip}_percent", message.position_percent) 
                  elsif motor.down_limit
                    motor.publish(:"ip#{message.ip}_percent", message.position_pulses.to_f / motor.down_limit * 100) 
                  end
                when Message::PostGroupAddr
                  motor.add_group(message.group_index, message.group_address)
                end

                @mutex.synchronize do
                  prior_message_to_group = Message.is_group_address?(@prior_message&.message&.src)

                  correct_response = @response_pending && @prior_message&.message&.class&.expected_response?(message)
                  correct_response = false if !prior_message_to_group && message.src != @prior_message&.message&.dest
                  correct_response = false if prior_message_to_group && message.dest != @prior_message&.message&.src

                  if prior_message_to_group && correct_response
                    @pending_group_motors.delete(Message.print_address(message.src).gsub('.', ''))
                    correct_response = false unless @pending_group_motors.empty?
                  end

                  signal = correct_response || !follow_ups.empty?
                  @response_pending = @broadcast_pending if correct_response
                  follow_ups.each do |follow_up|
                    @queues[1].push(MessageAndRetries.new(follow_up, 5, 1)) unless @queues[1].any? { |mr| mr.message == follow_up }
                  end
                  @cond.signal if signal
                end
              rescue EOFError
                SDN.logger.fatal "EOF reading"
                exit 2
              rescue MalformedMessage => e
                SDN.logger.warn "ignoring malformed message: #{e}" unless e.to_s =~ /issing data/
              rescue => e
                SDN.logger.error "got garbage: #{e}; #{e.backtrace}"
              end
            end
          end
        end
      end
    end
  end
end
