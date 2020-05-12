module SDN
  Motor = Struct.new(:bridge,
                     :addr,
                     :label,
                     :positionpulses,
                     :positionpercent,
                     :ip,
                     :state,
                     :last_direction,
                     :last_action_source,
                     :last_action_cause,
                     :uplimit,
                     :downlimit,
                     :direction,
                     :upspeed,
                     :downspeed,
                     :slowspeed,
                     :ip1pulses,
                     :ip1percent,
                     :ip2pulses,
                     :ip2percent,
                     :ip3pulses,
                     :ip3percent,
                     :ip4pulses,
                     :ip4percent,
                     :ip5pulses,
                     :ip5percent,
                     :ip6pulses,
                     :ip6percent,
                     :ip7pulses,
                     :ip7percent,
                     :ip8pulses,
                     :ip8percent,
                     :ip9pulses,
                     :ip9percent,
                     :ip10pulses,
                     :ip10percent,
                     :ip11pulses,
                     :ip11percent,
                     :ip12pulses,
                     :ip12percent,
                     :ip13pulses,
                     :ip13percent,
                     :ip14pulses,
                     :ip14percent,
                     :ip15pulses,
                     :ip15percent,
                     :ip16pulses,
                     :ip16percent,
                     :groups) do
     def initialize(*)
       members.each { |k| self[k] = :nil }
       @groups = [].fill(nil, 0, 16)
       super
     end

     def publish(attribute, value)
       if self[attribute] != value
         bridge.publish("#{addr}/#{attribute}", value.to_s)
         self[attribute] = value
       end
     end

     def add_group(index, address)
       bridge.add_group(SDN::Message.print_address(address)) if address
       @groups[index] = address
       publish(:groups, groups_string)
     end

     def set_groups(groups)
       return unless groups =~ /^(?:\h{2}[:.]?\h{2}[:.]?\h{2}(?:,\h{2}[:.]?\h{2}[:.]?\h{2})*)?$/i
       groups = groups.split(',').sort.uniq.map { |g| SDN::Message.parse_address(g) }
       groups.fill(nil, groups.length, 16 - groups.length)
       messages = []
       sdn_addr = SDN::Message.parse_address(addr)
       groups.each_with_index do |g, i|
         if @groups[i] != g
           messages << SDN::Message::SetGroupAddr.new(sdn_addr, i, g)
           messages << SDN::Message::GetGroupAddr.new(sdn_addr, i)
         end
       end
       messages
     end

     def groups_string
       @groups.compact.map { |g| SDN::Message.print_address(g) }.sort.uniq.join(',')
     end
  end

  class MQTTBridge
    def initialize(mqtt_uri, serialport, device_id: "somfy", base_topic: "homie")
      @base_topic = "#{base_topic}/#{device_id}"
      @mqtt = MQTT::Client.new(mqtt_uri)
      @mqtt.set_will("#{@base_topic}/$state", "lost", true)
      @mqtt.connect
      @motors = {}
      @groups = Set.new
      @write_queue = Queue.new

      publish_basic_attributes

      @sdn = SerialPort.open(serialport, "baud" => 4800, "parity" => SerialPort::ODD)

      read_thread = Thread.new do
        loop do
          begin
            message = SDN::Message.parse(@sdn)
            next unless message
            src = SDN::Message.print_address(message.src)
            # ignore the UAI Plus and ourselves
            if src != '7F.7F.7F' && !SDN::Message::is_group_address?(message.src) && !(motor = @motors[src.gsub('.', '')])
              motor = publish_motor(src.gsub('.', ''))
              puts "found new motor #{src}"
            end

            puts "read #{message.inspect}"
            case message
            when SDN::Message::PostNodeLabel
              if (motor.publish(:label, message.label))
                publish("#{motor.addr}/$name", message.label)
              end
            when SDN::Message::PostMotorPosition
              motor.publish(:positionpercent, message.position_percent)
              motor.publish(:positionpulses, message.position_pulses)
              motor.publish(:ip, message.ip)
            when SDN::Message::PostMotorStatus
              if message.state == :running || motor.state == :running
                @write_queue.push(SDN::Message::GetMotorStatus.new(message.src))
              end
              # this will do one more position request after it stopped
              @write_queue.push(SDN::Message::GetMotorPosition.new(message.src))
              motor.publish(:state, message.state)
              motor.publish(:last_direction, message.last_direction)
              motor.publish(:last_action_source, message.last_action_source)
              motor.publish(:last_action_cause, message.last_action_cause)
            when SDN::Message::PostMotorLimits
              motor.publish(:uplimit, message.up_limit)
              motor.publish(:downlimit, message.down_limit)
            when SDN::Message::PostMotorDirection
              motor.publish(:direction, message.direction)
            when SDN::Message::PostMotorRollingSpeed
              motor.publish(:upspeed, message.up_speed)
              motor.publish(:downspeed, message.down_speed)
              motor.publish(:slowspeed, message.slow_speed)
            when SDN::Message::PostMotorIP
              motor.publish(:"ip#{message.ip}pulses", message.position_pulses) 
              motor.publish(:"ip#{message.ip}percent", message.position_percent)
            when SDN::Message::PostGroupAddr
              motor.add_group(message.group_index, message.group_address)
            end

          rescue SDN::MalformedMessage => e
            puts "ignoring malformed message: #{e}" unless e.to_s =~ /issing data/
          rescue => e
            puts "got garbage: #{e}; #{e.backtrace}"
          end
        end
      end

      write_thread = Thread.new do
        loop do
          message = @write_queue.pop
          puts "writing #{message.inspect}"
          @sdn.write(message.serialize)
          # give more response time to a discovery message
          sleep 5 if (message.is_a?(SDN::Message::GetNodeAddr) && message.dest == [0xff, 0xff, 0xff])
          sleep 0.1
        end
      end

      @mqtt.get do |topic, value|
        puts "got #{value.inspect} at #{topic}"
        if topic == "#{@base_topic}/discovery/discover/set" && value == "true"
          # trigger discovery
          @write_queue.push(SDN::Message::GetNodeAddr.new)
        elsif (match = topic.match(%r{^#{Regexp.escape(@base_topic)}/(?<addr>\h{6})/(?<property>label|down|up|stop|positionpulses|positionpercent|ip|wink|reset|(?<speed_type>upspeed|downspeed|slowspeed)|uplimit|downlimit|direction|ip(?<ip>\d+)(?<ip_type>pulses|percent)|groups)/set$}))
          addr = SDN::Message.parse_address(match[:addr])
          property = match[:property]
          # not homie compliant; allows linking the positionpercent property
          # directly to an OpenHAB rollershutter channel
          if property == 'positionpercent' && value =~ /^(?:UP|DOWN|STOP)$/i
            property = value.downcase
            value = "true"
          end
          motor = @motors[SDN::Message.print_address(addr).gsub('.', '')]
          is_group = SDN::Message.is_group_address?(addr)
          follow_up = SDN::Message::GetMotorStatus.new(addr)
          message = case property
            when 'label'
              follow_up = SDN::Message::GetNodeLabel.new(addr)
              SDN::Message::SetNodeLabel.new(addr, value) unless is_group
            when 'stop'
              SDN::Message::Stop.new(addr) if value == "true"
            when 'up', 'down'
              SDN::Message::MoveTo.new(addr, "#{property}_limit".to_sym) if value == "true"
            when 'wink'
              SDN::Message::Wink.new(addr) if value == "true"
            when 'reset'
              next unless SDN::Message::SetFactoryDefault::RESET.keys.include?(value.to_sym)
              SDN::Message::SetFactoryDefault.new(addr, value.to_sym)
            when 'positionpulses', 'positionpercent', 'ip'
              SDN::Message::MoveTo.new(addr, property.to_sym, value.to_i)
            when 'direction'
              next if is_group
              follow_up = SDN::Message::GetMotorDirection.new(addr)
              next unless %w{standard reversed}.include?(value)
              SDN::Message::SetMotorDirection.new(addr, value.to_sym)
            when 'uplimit', 'downlimit'
              next if is_group
              if %w{delete current_position jog_ms jog_pulses}.include?(value)
                type = value.to_sym
                value = 10
              else
                type = :specified_position
              end
              target = property == 'uplimit' ? :up : :down
              follow_up = SDN::Message::GetMotorLimits.new(addr)
              SDN::Message::SetMotorLimits.new(addr, type, target, value.to_i)
            when /^ip\d(?:pulses|percent)$/
              next if is_group
              ip = match[:ip].to_i
              next unless (1..16).include?(ip)
              follow_up = SDN::Message::GetMotorIP.new(addr, ip)
              type = if value == 'delete'
                :delete
              elsif value == 'current_position'
                :current_position
              elsif match[:ip_type] == 'pulses'
                :position_pulses
              else
                :position_percent
              end
              SDN::Message::SetMotorIP.new(addr, type, ip, value.to_i)
            when 'upspeed', 'downspeed', 'slowspeed'
              next if is_group
              next unless motor
              follow_up = SDN::Message::GetMotorRollingSpeed.new(addr)
              message = SDN::Message::SetMotorRollingSpeed.new(addr,
                up_speed: motor.up_speed,
                down_speed: motor.down_speed,
                slow_speed: motor.slow_speed)
              message.send(:"#{property.sub('speed', '')}_speed=", value.to_i)
              message
            when 'groups'
              next if is_group
              next unless motor
              messages = motor.set_groups(value)
              messages.each { |m| @write_queue.push(m) }
              nil
          end
          if message
            @write_queue.push(message)
            next if follow_up.is_a?(SDN::Message::GetMotorStatus) && motor&.state == :running
            @write_queue.push(follow_up)
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

      subscribe("discovery/discover/set")
      subscribe("+/label/set")
      subscribe("+/down/set")
      subscribe("+/up/set")
      subscribe("+/stop/set")
      subscribe("+/positionpulses/set")
      subscribe("+/positionpercent/set")
      subscribe("+/ip/set")
      subscribe("+/wink/set")
      subscribe("+/reset/set")
      subscribe("+/direction/set")
      subscribe("+/upspeed/set")
      subscribe("+/downspeed/set")
      subscribe("+/slowspeed/set")
      subscribe("+/uplimit/set")
      subscribe("+/downlimit/set")
      subscribe("+/groups/set")
      (1..16).each do |ip|
        subscribe("+/ip#{ip}pulses/set")
        subscribe("+/ip#{ip}percent/set")
      end

      publish("$state", "ready")
    end

    def publish_motor(addr)
      publish("#{addr}/$name", addr)
      publish("#{addr}/$type", "Sonesse 30 Motor")
      publish("#{addr}/$properties", "label,down,up,stop,positionpulses,positionpercent,ip,wink,reset,state,last_direction,last_action_source,last_action_cause,uplimit,downlimit,direction,upspeed,downspeed,slowspeed,#{(1..16).map { |ip| "ip#{ip}pulses,ip#{ip}percent" }.join(',')},groups")

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

      publish("#{addr}/positionpulses/$name", "Position from up limit (in pulses)")
      publish("#{addr}/positionpulses/$datatype", "integer")
      publish("#{addr}/positionpulses/$format", "0:65535")
      publish("#{addr}/positionpulses/$unit", "pulses")
      publish("#{addr}/positionpulses/$settable", "true")

      publish("#{addr}/positionpercent/$name", "Position (in %)")
      publish("#{addr}/positionpercent/$datatype", "integer")
      publish("#{addr}/positionpercent/$format", "0:100")
      publish("#{addr}/positionpercent/$unit", "%")
      publish("#{addr}/positionpercent/$settable", "true")

      publish("#{addr}/ip/$name", "Intermediate Position")
      publish("#{addr}/ip/$datatype", "integer")
      publish("#{addr}/ip/$format", "1:16")
      publish("#{addr}/ip/$settable", "true")

      publish("#{addr}/wink/$name", "Feedback")
      publish("#{addr}/wink/$datatype", "boolean")
      publish("#{addr}/wink/$settable", "true")
      publish("#{addr}/wink/$retained", "false")

      publish("#{addr}/reset/$name", "Recall factory settings")
      publish("#{addr}/reset/$datatype", "enum")
      publish("#{addr}/reset/$format", SDN::Message::SetFactoryDefault::RESET.keys.join(','))
      publish("#{addr}/reset/$settable", "true")
      publish("#{addr}/reset/$retained", "false")

      publish("#{addr}/state/$name", "State of the motor")
      publish("#{addr}/state/$datatype", "enum")
      publish("#{addr}/state/$format", SDN::Message::PostMotorStatus::STATE.keys.join(','))

      publish("#{addr}/last_direction/$name", "Direction of last motion")
      publish("#{addr}/last_direction/$datatype", "enum")
      publish("#{addr}/last_direction/$format", SDN::Message::PostMotorStatus::DIRECTION.keys.join(','))

      publish("#{addr}/last_action_source/$name", "Source of last action")
      publish("#{addr}/last_action_source/$datatype", "enum")
      publish("#{addr}/last_action_source/$format", SDN::Message::PostMotorStatus::SOURCE.keys.join(','))

      publish("#{addr}/last_action_cause/$name", "Cause of last action")
      publish("#{addr}/last_action_cause/$datatype", "enum")
      publish("#{addr}/last_action_cause/$format", SDN::Message::PostMotorStatus::CAUSE.keys.join(','))

      publish("#{addr}/uplimit/$name", "Up limit (always = 0)")
      publish("#{addr}/uplimit/$datatype", "integer")
      publish("#{addr}/uplimit/$format", "0:65535")
      publish("#{addr}/uplimit/$unit", "pulses")
      publish("#{addr}/uplimit/$settable", "true")

      publish("#{addr}/downlimit/$name", "Down limit")
      publish("#{addr}/downlimit/$datatype", "integer")
      publish("#{addr}/downlimit/$format", "0:65535")
      publish("#{addr}/downlimit/$unit", "pulses")
      publish("#{addr}/downlimit/$settable", "true")

      publish("#{addr}/direction/$name", "Motor rotation direction")
      publish("#{addr}/direction/$datatype", "enum")
      publish("#{addr}/direction/$format", "standard,reversed")
      publish("#{addr}/direction/$settable", "true")

      publish("#{addr}/upspeed/$name", "Up speed")
      publish("#{addr}/upspeed/$datatype", "integer")
      publish("#{addr}/upspeed/$format", "6:28")
      publish("#{addr}/upspeed/$unit", "RPM")
      publish("#{addr}/upspeed/$settable", "true")

      publish("#{addr}/downspeed/$name", "Down speed, always = Up speed")
      publish("#{addr}/downspeed/$datatype", "integer")
      publish("#{addr}/downspeed/$format", "6:28")
      publish("#{addr}/downspeed/$unit", "RPM")
      publish("#{addr}/downspeed/$settable", "true")

      publish("#{addr}/slowspeed/$name", "Slow speed")
      publish("#{addr}/slowspeed/$datatype", "integer")
      publish("#{addr}/slowspeed/$format", "6:28")
      publish("#{addr}/slowspeed/$unit", "RPM")
      publish("#{addr}/slowspeed/$settable", "true")

      publish("#{addr}/groups/$name", "Group Memberships")
      publish("#{addr}/groups/$datatype", "string")
      publish("#{addr}/groups/$settable", "true")

      (1..16).each do |ip|
        publish("#{addr}/ip#{ip}pulses/$name", "Intermediate Position #{ip}")
        publish("#{addr}/ip#{ip}pulses/$datatype", "integer")
        publish("#{addr}/ip#{ip}pulses/$format", "0:65535")
        publish("#{addr}/ip#{ip}pulses/$unit", "pulses")
        publish("#{addr}/ip#{ip}pulses/$settable", "true")

        publish("#{addr}/ip#{ip}percent/$name", "Intermediate Position #{ip}")
        publish("#{addr}/ip#{ip}percent/$datatype", "integer")
        publish("#{addr}/ip#{ip}percent/$format", "0:100")
        publish("#{addr}/ip#{ip}percent/$unit", "%")
        publish("#{addr}/ip#{ip}percent/$settable", "true")
      end

      motor = Motor.new(self, addr)
      @motors[addr] = motor
      publish("$nodes", (["discovery"] + @motors.keys.sort + @groups.to_a).join(","))

      sdn_addr = SDN::Message.parse_address(addr)
      # these messages are often corrupt; just don't bother for now.
      #@write_queue.push(SDN::Message::GetNodeLabel.new(sdn_addr))
      @write_queue.push(SDN::Message::GetMotorStatus.new(sdn_addr))
      @write_queue.push(SDN::Message::GetMotorLimits.new(sdn_addr))
      @write_queue.push(SDN::Message::GetMotorDirection.new(sdn_addr))
      @write_queue.push(SDN::Message::GetMotorRollingSpeed.new(sdn_addr))
      (1..16).each { |ip| @write_queue.push(SDN::Message::GetMotorIP.new(sdn_addr, ip)) }
      (0...16).each { |g| @write_queue.push(SDN::Message::GetGroupAddr.new(sdn_addr, g)) }

      motor
    end

    def add_group(addr)
      addr = addr.gsub('.', '')
      return if @groups.include?(addr)

      publish("#{addr}/$name", addr)
      publish("#{addr}/$type", "Shade Group")
      publish("#{addr}/$properties", "down,up,stop,positionpulses,positionpercent,ip,wink,reset")

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

      publish("#{addr}/positionpulses/$name", "Position from up limit (in pulses)")
      publish("#{addr}/positionpulses/$datatype", "integer")
      publish("#{addr}/positionpulses/$format", "0:65535")
      publish("#{addr}/positionpulses/$unit", "pulses")
      publish("#{addr}/positionpulses/$settable", "true")

      publish("#{addr}/positionpercent/$name", "Position (in %)")
      publish("#{addr}/positionpercent/$datatype", "integer")
      publish("#{addr}/positionpercent/$format", "0:100")
      publish("#{addr}/positionpercent/$unit", "%")
      publish("#{addr}/positionpercent/$settable", "true")

      publish("#{addr}/ip/$name", "Intermediate Position")
      publish("#{addr}/ip/$datatype", "integer")
      publish("#{addr}/ip/$format", "1:16")
      publish("#{addr}/ip/$settable", "true")

      publish("#{addr}/wink/$name", "Feedback")
      publish("#{addr}/wink/$datatype", "boolean")
      publish("#{addr}/wink/$settable", "true")
      publish("#{addr}/wink/$retained", "false")

      @groups << addr
      publish("$nodes", (["discovery"] + @motors.keys.sort + @groups.to_a).join(","))
    end
  end
end
