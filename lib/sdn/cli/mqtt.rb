require 'mqtt'
require 'uri'
require 'set'

module SDN
  module CLI
    class MQTT
      MessageAndRetries = Struct.new(:message, :remaining_retries, :priority)

      Group = Struct.new(:bridge, :addr, :position_percent, :state, :motors) do
        def initialize(*)
          members.each { |k| self[k] = :nil }
          super
        end
    
        def publish(attribute, value)
          if self[attribute] != value
            bridge.publish("#{addr}/#{attribute.to_s.gsub('_', '-')}", value.to_s)
            self[attribute] = value
          end
        end
    
        def printed_addr
          Message.print_address(Message.parse_address(addr))
        end
    
        def motor_objects
          bridge.motors.select { |addr, motor| motor.groups_string.include?(printed_addr) }.values
        end
    
        def motors_string
          motor_objects.map { |m| Message.print_address(Message.parse_address(m.addr)) }.sort.join(',')
        end
      end
    
      Motor = Struct.new(:bridge,
                         :addr,
                         :node_type,
                         :label,
                         :position_pulses,
                         :position_percent,
                         :ip,
                         :state,
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
          if self[attribute] != value
            bridge.publish("#{addr}/#{attribute.to_s.gsub('_', '-')}", value.to_s)
            self[attribute] = value
          end
        end
    
        def add_group(index, address)
          group = bridge.add_group(Message.print_address(address)) if address
          @groups[index] = address
          group&.publish(:motors, group.motors_string)
          publish(:groups, groups_string)
        end
    
        def set_groups(groups)
          return unless groups =~ /^(?:\h{2}[:.]?\h{2}[:.]?\h{2}(?:,\h{2}[:.]?\h{2}[:.]?\h{2})*)?$/i
          groups = groups.split(',').sort.uniq.map { |g| Message.parse_address(g) }.select { |g| Message.is_group_address?(g) }
          groups.fill(nil, groups.length, 16 - groups.length)
          messages = []
          sdn_addr = Message.parse_address(addr)
          groups.each_with_index do |g, i|
            if @groups[i] != g
              messages << Message::SetGroupAddr.new(sdn_addr, i, g).tap { |m| m.ack_requested = true }
              messages << Message::GetGroupAddr.new(sdn_addr, i)
            end
          end
          messages
        end
    
        def groups_string
          @groups.compact.map { |g| Message.print_address(g) }.sort.uniq.join(',')
        end
    
        def group_objects
          groups_string.split(',').map { |addr| bridge.groups[addr.gsub('.', '')] }
        end
      end

      WAIT_TIME = 0.25
      BROADCAST_WAIT = 5.0

      attr_reader :motors, :groups

      def initialize(port, mqtt_uri, device_id: "somfy", base_topic: "homie")
        @base_topic = "#{base_topic}/#{device_id}"
        @mqtt = ::MQTT::Client.new(mqtt_uri)
        @mqtt.set_will("#{@base_topic}/$state", "lost", true)
        @mqtt.connect

        @motors = {}
        @groups = {}

        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @queues = [[], [], []]
        @response_pending = false
        @broadcast_pending = false

        # queue an initial discovery
        @queues[2].push(MessageAndRetries.new(Message::GetNodeAddr.new, 1, 2))

        publish_basic_attributes

        @sdn = Client.new(port)

        read_thread = Thread.new do
          loop do
            begin
              @sdn.receive do |message|
                src = Message.print_address(message.src)
                # ignore the UAI Plus and ourselves
                if src != '7F.7F.7F' && !Message::is_group_address?(message.src) && !(motor = @motors[src.gsub('.', '')])
                  motor = publish_motor(src.gsub('.', ''), message.node_type)
                  puts "found new motor #{src}"
                end

                puts "read #{message.inspect}"
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
                      follow_ups << Message::ILT2::GetMotorPosition.new(message.src)
                    end
                    motor.last_position_pulses = motor.position_pulses
                    ip = (1..16).find do |i|
                      # divide by 5 for some leniency
                      motor["ip#{i}_pulses"] / 5 == message.position_pulses / 5
                    end
                    motor.publish(:ip, ip)
                  end
                  motor.publish(:position_percent, message.position_percent)
                  motor.publish(:position_pulses, message.position_pulses)
                  motor.publish(:ip, message.ip) if message.respond_to?(:ip)
                  motor.group_objects.each do |group|
                    positions = group.motor_objects.map(&:"position-percent")
                    position = nil
                    # calculate an average, but only if we know a position for
                    # every shade
                    if !positions.include?(:nil) && !positions.include?(nil)
                      position = positions.inject(&:+) / positions.length
                    end

                    group.publish(:position_percent, position)
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
                  correct_response = @response_pending && message.src == @prior_message&.message&.dest && @prior_message&.message&.class&.expected_response?(message)
                  signal = correct_response || !follow_ups.empty?
                  @response_pending = @broadcast_pending if correct_response
                  follow_ups.each do |follow_up|
                    @queues[1].push(MessageAndRetries.new(follow_up, 5, 1)) unless @queues[1].any? { |mr| mr.message == follow_up }
                  end
                  @cond.signal if signal
                end
              rescue EOFError
                puts "EOF reading"
                exit 2
              rescue MalformedMessage => e
                puts "ignoring malformed message: #{e}" unless e.to_s =~ /issing data/
              rescue => e
                puts "got garbage: #{e}; #{e.backtrace}"
              end
            end
          end
        end

        write_thread = Thread.new do
          begin
            loop do
              message_and_retries = nil
              @mutex.synchronize do
                # got woken up early by another command getting queued; spin
                if @response_pending
                  while @response_pending
                    remaining_wait = @response_pending - Time.now.to_f
                    if remaining_wait < 0
                      puts "timed out waiting on response"
                      @response_pending = nil
                      @broadcast_pending = nil
                      if @prior_message&.remaining_retries != 0
                        puts "retrying #{@prior_message.remaining_retries} more times ..."
                        @queues[@prior_message.priority].push(@prior_message)
                        @prior_message = nil
                      end
                    else
                      @cond.wait(@mutex, remaining_wait)
                    end
                  end
                else
                  # minimum time between messages
                  sleep 0.1
                end

                @queues.find { |q| message_and_retries = q.shift }
                if message_and_retries
                  if message_and_retries.message.ack_requested || message_and_retries.message.class.name =~ /^SDN::Message::Get/
                    @response_pending = Time.now.to_f + WAIT_TIME
                    if message_and_retries.message.dest == BROADCAST_ADDRESS || Message::is_group_address?(message_and_retries.message.src) && message_and_retries.message.is_a?(Message::GetNodeAddr)
                      @broadcast_pending = Time.now.to_f + BROADCAST_WAIT
                    end
                  end
                end

                # wait until there is a message
                if @response_pending
                  message_and_retries.remaining_retries -= 1
                  @prior_message = message_and_retries  
                elsif message_and_retries
                  @prior_message = nil  
                else
                  @cond.wait(@mutex)
                end
              end
              next unless message_and_retries

              message = message_and_retries.message
              puts "writing #{message.inspect}"
              @sdn.send(message)
            end
          rescue => e
            puts "failure writing: #{e}"
            exit 1
          end
        end

        @mqtt.get do |topic, value|
          puts "got #{value.inspect} at #{topic}"
          if topic == "#{@base_topic}/discovery/discover/set" && value == "true"
            # trigger discovery
            @mutex.synchronize do
              @queues[2].push(MessageAndRetries.new(Message::GetNodeAddr.new, 1, 2))
              @cond.signal
            end
          elsif (match = topic.match(%r{^#{Regexp.escape(@base_topic)}/(?<addr>\h{6})/(?<property>discover|label|down|up|stop|position-pulses|position-percent|ip|wink|reset|(?<speed_type>up-speed|down-speed|slow-speed)|up-limit|down-limit|direction|ip(?<ip>\d+)-(?<ip_type>pulses|percent)|groups)/set$}))
            addr = Message.parse_address(match[:addr])
            property = match[:property]
            # not homie compliant; allows linking the position-percent property
            # directly to an OpenHAB rollershutter channel
            if property == 'position-percent' && value =~ /^(?:UP|DOWN|STOP)$/i
              property = value.downcase
              value = "true"
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
                Message::GetNodeAddr.new(addr) if value == "true"
              when 'label'
                follow_up = Message::GetNodeLabel.new(addr)
                ns::SetNodeLabel.new(addr, value) unless is_group
              when 'stop'
                if value == "true"
                  motor&.node_type == :st50ilt2 ? ns::SetMotorPosition.new(addr, :stop) : Message::Stop.new(addr)
                end
              when 'up', 'down'
                if value == "true"
                  (motor&.node_type == :st50ilt2 ? ns::SetMotorPosition : Message::MoveTo).
                    new(addr, "#{property}_limit".to_sym)
                end
              when 'wink'
                Message::Wink.new(addr) if value == "true"
              when 'reset'
                next unless Message::SetFactoryDefault::RESET.keys.include?(value.to_sym)
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
                next if is_group
                follow_up = Message::GetMotorDirection.new(addr)
                next unless %w{standard reversed}.include?(value)
                Message::SetMotorDirection.new(addr, value.to_sym)
              when 'up-limit', 'down-limit'
                next if is_group
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
                next if is_group
                ip = match[:ip].to_i
                next unless (1..16).include?(ip)
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
                next if is_group
                next unless motor
                follow_up = Message::GetMotorRollingSpeed.new(addr)
                message = Message::SetMotorRollingSpeed.new(addr,
                  up_speed: motor.up_speed,
                  down_speed: motor.down_speed,
                  slow_speed: motor.slow_speed)
                message.send(:"#{property.sub('-', '_')}=", value.to_i)
                message
              when 'groups'
                next if is_group
                next unless motor
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

      def publish(topic, value)
        @mqtt.publish("#{@base_topic}/#{topic}", value, true)
      end

      def subscribe(topic)
        @mqtt.subscribe("#{@base_topic}/#{topic}")
      end

      def enqueue(message, queue = :command)
        @mutex.synchronize do
          queue = instance_variable_get(:"#{@queue}_queue")
          unless queue.include?(message)
            queue.push(message)
            @cond.signal
          end
        end
      end

      def publish_basic_attributes
        publish("$homie", "v4.0.0")
        publish("$name", "Somfy SDN Network")
        publish("$state", "init")
        publish("$nodes", "discovery")

        publish("discovery/$name", "Discovery Node")
        publish("discovery/$type", "sdn")
        publish("discovery/$properties", "discover")

        publish("discovery/discover/$name", "Trigger Motor Discovery")
        publish("discovery/discover/$datatype", "boolean")
        publish("discovery/discover/$settable", "true")
        publish("discovery/discover/$retained", "false")

        subscribe("+/discover/set")
        subscribe("+/label/set")
        subscribe("+/down/set")
        subscribe("+/up/set")
        subscribe("+/stop/set")
        subscribe("+/position-pulses/set")
        subscribe("+/position-percent/set")
        subscribe("+/ip/set")
        subscribe("+/wink/set")
        subscribe("+/reset/set")
        subscribe("+/direction/set")
        subscribe("+/up-speed/set")
        subscribe("+/down-speed/set")
        subscribe("+/slow-speed/set")
        subscribe("+/up-limit/set")
        subscribe("+/down-limit/set")
        subscribe("+/groups/set")
        (1..16).each do |ip|
          subscribe("+/ip#{ip}-pulses/set")
          subscribe("+/ip#{ip}-percent/set")
        end

        publish("$state", "ready")
      end

      def publish_motor(addr, node_type)
        publish("#{addr}/$name", addr)
        publish("#{addr}/$type", node_type.to_s)
        properties = %w{
          discover
          state
          label
          down
          up
          stop
          position-pulses
          position-percent
          ip
          down-limit
          groups
        } + (1..16).map { |ip| ["ip#{ip}-pulses", "ip#{ip}-percent"] }.flatten

        unless node_type == :st50ilt2
          properties.concat %w{
            wink
            reset
            last-direction
            last-action-source
            last-action-cause
            up-limit
            direction
            up-speed
            down-speed
            slow-speed
          }
        end

        publish("#{addr}/$properties", properties.join(","))

        publish("#{addr}/discover/$name", "Trigger Motor Discovery")
        publish("#{addr}/discover/$datatype", "boolean")
        publish("#{addr}/discover/$settable", "true")
        publish("#{addr}/discover/$retained", "false")

        publish("#{addr}/label/$name", "Node label")
        publish("#{addr}/label/$datatype", "string")
        publish("#{addr}/label/$settable", "true")

        publish("#{addr}/down/$name", "Move in down direction")
        publish("#{addr}/down/$datatype", "boolean")
        publish("#{addr}/down/$settable", "true")
        publish("#{addr}/down/$retained", "false")

        publish("#{addr}/up/$name", "Move in up direction")
        publish("#{addr}/up/$datatype", "boolean")
        publish("#{addr}/up/$settable", "true")
        publish("#{addr}/up/$retained", "false")

        publish("#{addr}/stop/$name", "Cancel adjustments")
        publish("#{addr}/stop/$datatype", "boolean")
        publish("#{addr}/stop/$settable", "true")
        publish("#{addr}/stop/$retained", "false")

        publish("#{addr}/position-percent/$name", "Position (in %)")
        publish("#{addr}/position-percent/$datatype", "integer")
        publish("#{addr}/position-percent/$format", "0:100")
        publish("#{addr}/position-percent/$unit", "%")
        publish("#{addr}/position-percent/$settable", "true")

        publish("#{addr}/position-pulses/$name", "Position from up limit (in pulses)")
        publish("#{addr}/position-pulses/$datatype", "integer")
        publish("#{addr}/position-pulses/$format", "0:65535")
        publish("#{addr}/position-pulses/$unit", "pulses")
        publish("#{addr}/position-pulses/$settable", "true")

        publish("#{addr}/ip/$name", "Intermediate Position")
        publish("#{addr}/ip/$datatype", "integer")
        publish("#{addr}/ip/$format", "1:16")
        publish("#{addr}/ip/$settable", "true")
        publish("#{addr}/ip/$retained", "false") if node_type == :st50ilt2

        publish("#{addr}/down-limit/$name", "Down limit")
        publish("#{addr}/down-limit/$datatype", "integer")
        publish("#{addr}/down-limit/$format", "0:65535")
        publish("#{addr}/down-limit/$unit", "pulses")
        publish("#{addr}/down-limit/$settable", "true")

        unless node_type == :st50ilt2
          publish("#{addr}/wink/$name", "Feedback")
          publish("#{addr}/wink/$datatype", "boolean")
          publish("#{addr}/wink/$settable", "true")
          publish("#{addr}/wink/$retained", "false")

          publish("#{addr}/reset/$name", "Recall factory settings")
          publish("#{addr}/reset/$datatype", "enum")
          publish("#{addr}/reset/$format", Message::SetFactoryDefault::RESET.keys.join(','))
          publish("#{addr}/reset/$settable", "true")
          publish("#{addr}/reset/$retained", "false")

          publish("#{addr}/state/$name", "State of the motor")
          publish("#{addr}/state/$datatype", "enum")
          publish("#{addr}/state/$format", Message::PostMotorStatus::STATE.keys.join(','))

          publish("#{addr}/last-direction/$name", "Direction of last motion")
          publish("#{addr}/last-direction/$datatype", "enum")
          publish("#{addr}/last-direction/$format", Message::PostMotorStatus::DIRECTION.keys.join(','))

          publish("#{addr}/last-action-source/$name", "Source of last action")
          publish("#{addr}/last-action-source/$datatype", "enum")
          publish("#{addr}/last-action-source/$format", Message::PostMotorStatus::SOURCE.keys.join(','))

          publish("#{addr}/last-action-cause/$name", "Cause of last action")
          publish("#{addr}/last-action-cause/$datatype", "enum")
          publish("#{addr}/last-action-cause/$format", Message::PostMotorStatus::CAUSE.keys.join(','))

          publish("#{addr}/up-limit/$name", "Up limit (always = 0)")
          publish("#{addr}/up-limit/$datatype", "integer")
          publish("#{addr}/up-limit/$format", "0:65535")
          publish("#{addr}/up-limit/$unit", "pulses")
          publish("#{addr}/up-limit/$settable", "true")

          publish("#{addr}/direction/$name", "Motor rotation direction")
          publish("#{addr}/direction/$datatype", "enum")
          publish("#{addr}/direction/$format", "standard,reversed")
          publish("#{addr}/direction/$settable", "true")

          publish("#{addr}/up-speed/$name", "Up speed")
          publish("#{addr}/up-speed/$datatype", "integer")
          publish("#{addr}/up-speed/$format", "6:28")
          publish("#{addr}/up-speed/$unit", "RPM")
          publish("#{addr}/up-speed/$settable", "true")

          publish("#{addr}/down-speed/$name", "Down speed, always = Up speed")
          publish("#{addr}/down-speed/$datatype", "integer")
          publish("#{addr}/down-speed/$format", "6:28")
          publish("#{addr}/down-speed/$unit", "RPM")
          publish("#{addr}/down-speed/$settable", "true")

          publish("#{addr}/slow-speed/$name", "Slow speed")
          publish("#{addr}/slow-speed/$datatype", "integer")
          publish("#{addr}/slow-speed/$format", "6:28")
          publish("#{addr}/slow-speed/$unit", "RPM")
          publish("#{addr}/slow-speed/$settable", "true")
        end

        publish("#{addr}/groups/$name", "Group Memberships")
        publish("#{addr}/groups/$datatype", "string")
        publish("#{addr}/groups/$settable", "true")

        (1..16).each do |ip|
          publish("#{addr}/ip#{ip}-pulses/$name", "Intermediate Position #{ip}")
          publish("#{addr}/ip#{ip}-pulses/$datatype", "integer")
          publish("#{addr}/ip#{ip}-pulses/$format", "0:65535")
          publish("#{addr}/ip#{ip}-pulses/$unit", "pulses")
          publish("#{addr}/ip#{ip}-pulses/$settable", "true")

          publish("#{addr}/ip#{ip}-percent/$name", "Intermediate Position #{ip}")
          publish("#{addr}/ip#{ip}-percent/$datatype", "integer")
          publish("#{addr}/ip#{ip}-percent/$format", "0:100")
          publish("#{addr}/ip#{ip}-percent/$unit", "%")
          publish("#{addr}/ip#{ip}-percent/$settable", "true")
        end

        motor = Motor.new(self, addr, node_type)
        @motors[addr] = motor
        publish("$nodes", (["discovery"] + @motors.keys.sort + @groups.keys.sort).join(","))

        sdn_addr = Message.parse_address(addr)
        @mutex.synchronize do
          @queues[2].push(MessageAndRetries.new(Message::GetNodeLabel.new(sdn_addr), 5, 2))
          case node_type
          when :st30
            @queues[2].push(MessageAndRetries.new(Message::GetMotorStatus.new(sdn_addr), 5, 2))
            @queues[2].push(MessageAndRetries.new(Message::GetMotorLimits.new(sdn_addr), 5, 2))
            @queues[2].push(MessageAndRetries.new(Message::GetMotorDirection.new(sdn_addr), 5, 2))
            @queues[2].push(MessageAndRetries.new(Message::GetMotorRollingSpeed.new(sdn_addr), 5, 2))
            (1..16).each { |ip| @queues[2].push(MessageAndRetries.new(Message::GetMotorIP.new(sdn_addr, ip), 5, 2)) }
          when :st50ilt2
            @queues[2].push(MessageAndRetries.new(Message::ILT2::GetMotorSettings.new(sdn_addr), 5, 2))
            @queues[2].push(MessageAndRetries.new(Message::ILT2::GetMotorPosition.new(sdn_addr), 5, 2))
            (1..16).each { |ip| @queues[2].push(MessageAndRetries.new(Message::ILT2::GetMotorIP.new(sdn_addr, ip), 5, 2)) }
          end
          (1..16).each { |g| @queues[2].push(MessageAndRetries.new(Message::GetGroupAddr.new(sdn_addr, g), 5, 2)) }

          @cond.signal
        end

        motor
      end

      def add_group(addr)
        addr = addr.gsub('.', '')
        group = @groups[addr]
        return group if group

        publish("#{addr}/$name", addr)
        publish("#{addr}/$type", "Shade Group")
        publish("#{addr}/$properties", "discover,down,up,stop,position-pulses,position-percent,ip,wink,reset,state,motors")

        publish("#{addr}/discover/$name", "Trigger Motor Discovery")
        publish("#{addr}/discover/$datatype", "boolean")
        publish("#{addr}/discover/$settable", "true")
        publish("#{addr}/discover/$retained", "false")

        publish("#{addr}/down/$name", "Move in down direction")
        publish("#{addr}/down/$datatype", "boolean")
        publish("#{addr}/down/$settable", "true")
        publish("#{addr}/down/$retained", "false")

        publish("#{addr}/up/$name", "Move in up direction")
        publish("#{addr}/up/$datatype", "boolean")
        publish("#{addr}/up/$settable", "true")
        publish("#{addr}/up/$retained", "false")

        publish("#{addr}/stop/$name", "Cancel adjustments")
        publish("#{addr}/stop/$datatype", "boolean")
        publish("#{addr}/stop/$settable", "true")
        publish("#{addr}/stop/$retained", "false")

        publish("#{addr}/position-pulses/$name", "Position from up limit (in pulses)")
        publish("#{addr}/position-pulses/$datatype", "integer")
        publish("#{addr}/position-pulses/$format", "0:65535")
        publish("#{addr}/position-pulses/$unit", "pulses")
        publish("#{addr}/position-pulses/$settable", "true")

        publish("#{addr}/position-percent/$name", "Position (in %)")
        publish("#{addr}/position-percent/$datatype", "integer")
        publish("#{addr}/position-percent/$format", "0:100")
        publish("#{addr}/position-percent/$unit", "%")
        publish("#{addr}/position-percent/$settable", "true")

        publish("#{addr}/ip/$name", "Intermediate Position")
        publish("#{addr}/ip/$datatype", "integer")
        publish("#{addr}/ip/$format", "1:16")
        publish("#{addr}/ip/$settable", "true")

        publish("#{addr}/wink/$name", "Feedback")
        publish("#{addr}/wink/$datatype", "boolean")
        publish("#{addr}/wink/$settable", "true")
        publish("#{addr}/wink/$retained", "false")

        publish("#{addr}/state/$name", "State of the motors; only set if all motors are in the same state")
        publish("#{addr}/state/$datatype", "enum")
        publish("#{addr}/state/$format", Message::PostMotorStatus::STATE.keys.join(','))

        publish("#{addr}/motors/$name", "Motors that are members of this group")
        publish("#{addr}/motors/$datatype", "string")

        group = @groups[addr] = Group.new(self, addr)
        publish("$nodes", (["discovery"] + @motors.keys.sort + @groups.keys.sort).join(","))
        group
      end
    end
  end
end
