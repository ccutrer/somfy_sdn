require 'mqtt'
require 'uri'
require 'set'

module SDN
  Group = Struct.new(:bridge, :addr, :positionpercent, :state, :motors) do
    def initialize(*)
      members.each { |k| self[k] = :nil }
      super
    end

    def publish(attribute, value)
      if self[attribute] != value
        bridge.publish("#{addr}/#{attribute}", value.to_s)
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
      motor_objects.map { |m| SDN::Message.print_address(SDN::Message.parse_address(m.addr)) }.sort.join(',')
    end
  end

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
      group = bridge.add_group(SDN::Message.print_address(address)) if address
      @groups[index] = address
      group&.publish(:motors, group.motors_string)
      publish(:groups, groups_string)
    end

    def set_groups(groups)
      return unless groups =~ /^(?:\h{2}[:.]?\h{2}[:.]?\h{2}(?:,\h{2}[:.]?\h{2}[:.]?\h{2})*)?$/i
      groups = groups.split(',').sort.uniq.map { |g| SDN::Message.parse_address(g) }.select { |g| SDN::Message.is_group_address?(g) }
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

    def group_objects
      groups_string.split(',').map { |addr| bridge.groups[addr.gsub('.', '')] }
    end
  end

  class MQTTBridge
    WAIT_TIME = 0.25
    BROADCAST_WAIT = 5.0

    attr_reader :motors, :groups

    def initialize(mqtt_uri, port, device_id: "somfy", base_topic: "homie")
      @base_topic = "#{base_topic}/#{device_id}"
      @mqtt = MQTT::Client.new(mqtt_uri)
      @mqtt.set_will("#{@base_topic}/$state", "lost", true)
      @mqtt.connect

      @motors = {}
      @groups = {}

      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @command_queue = []
      @request_queue = []
      @response_pending = false
      @broadcast_pending = false

      publish_basic_attributes

      uri = URI.parse(port)
      if uri.scheme == "tcp"
        require 'socket'
        @sdn = TCPSocket.new(uri.host, uri.port)
      elsif uri.scheme == "telnet" || uri.scheme == "rfc2217"
        require 'net/telnet/rfc2217'
        @sdn = Net::Telnet::RFC2217.new('Host' => uri.host,
         'Port' => uri.port || 23,
         'baud' => 4800,
         'parity' => Net::Telnet::RFC2217::ODD)
      else
        require 'serialport'
        @sdn = SerialPort.open(port, "baud" => 4800, "parity" => SerialPort::ODD)
      end

      read_thread = Thread.new do
        buffer = ""
        loop do
          begin
            message, bytes_read = SDN::Message.parse(buffer.bytes)
            # discard how much we read
            buffer = buffer[bytes_read..-1]
            unless message
              begin
                buffer.concat(@sdn.read_nonblock(64 * 1024))
                next
              rescue IO::WaitReadable
                wait = buffer.empty? ? nil : WAIT_TIME
                if @sdn.wait_readable(wait).nil?
                  # timed out; just discard everything
                  puts "timed out reading; discarding buffer: #{buffer.unpack('H*').first}"
                  buffer = ""
                end
              end
              next
            end

            src = SDN::Message.print_address(message.src)
            # ignore the UAI Plus and ourselves
            if src != '7F.7F.7F' && !SDN::Message::is_group_address?(message.src) && !(motor = @motors[src.gsub('.', '')])
              motor = publish_motor(src.gsub('.', ''))
              puts "found new motor #{src}"
            end

            puts "read #{message.inspect}"
            follow_ups = []
            case message
            when SDN::Message::PostNodeLabel
              if (motor.publish(:label, message.label))
                publish("#{motor.addr}/$name", message.label)
              end
            when SDN::Message::PostMotorPosition
              motor.publish(:positionpercent, message.position_percent)
              motor.publish(:positionpulses, message.position_pulses)
              motor.publish(:ip, message.ip)
              motor.group_objects.each do |group|
                positions = group.motor_objects.map(&:positionpercent)
                position = nil
                # calculate an average, but only if we know a position for
                # every shade
                if !positions.include?(:nil) && !positions.include?(nil)
                  position = positions.inject(&:+) / positions.length
                end

                group.publish(:positionpercent, position)
              end
            when SDN::Message::PostMotorStatus
              if message.state == :running || motor.state == :running
                follow_ups << SDN::Message::GetMotorStatus.new(message.src)
              end
              # this will do one more position request after it stopped
              follow_ups << SDN::Message::GetMotorPosition.new(message.src)
              motor.publish(:state, message.state)
              motor.publish(:last_direction, message.last_direction)
              motor.publish(:last_action_source, message.last_action_source)
              motor.publish(:last_action_cause, message.last_action_cause)
              motor.group_objects.each do |group|
                states = group.motor_objects.map(&:state).uniq
                state = states.length == 1 ? states.first : 'mixed'
                group.publish(:state, state)
              end
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

            @mutex.synchronize do
              signal = @response_pending || !follow_ups.empty?
              @response_pending = @broadcast_pending
              follow_ups.each do |follow_up|
                @request_queue.push(follow_up) unless @request_queue.include?(follow_up)
              end
              @cond.signal if signal
            end
          rescue EOFError
            puts "EOF reading"
            exit 2
          rescue SDN::MalformedMessage => e
            puts "ignoring malformed message: #{e}" unless e.to_s =~ /issing data/
          rescue => e
            puts "got garbage: #{e}; #{e.backtrace}"
          end
        end
      end

      write_thread = Thread.new do
        begin
          loop do
            message = nil
            @mutex.synchronize do
              # got woken up early by another command getting queued; spin
              if @response_pending
                while @response_pending
                  remaining_wait = @response_pending - Time.now.to_f
                  if remaining_wait < 0
                    puts "timed out waiting on response"
                    @response_pending = nil
                    @broadcast_pending = nil
                  else
                    @cond.wait(@mutex, remaining_wait)
                  end
                end
              else
                sleep 0.1
              end

              message = @command_queue.shift
              unless message
                message = @request_queue.shift
                if message
                  @response_pending = Time.now.to_f + WAIT_TIME
                  if message.dest == BROADCAST_ADDRESS || SDN::Message::is_group_address?(message.src) && message.is_a?(SDN::Message::GetNodeAddr)
                    @broadcast_pending = Time.now.to_f + BROADCAST_WAIT
                  end
                end
              end

              # spin until there is a message
              @cond.wait(@mutex) unless message
            end
            next unless message

            puts "writing #{message.inspect}"
            serialized = message.serialize
            @sdn.write(serialized)
            @sdn.flush
            puts "wrote #{serialized.unpack("C*").map { |b| '%02x' % b }.join(' ')}"
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
            @request_queue.push(SDN::Message::GetNodeAddr.new)
            @cond.signal
          end
        elsif (match = topic.match(%r{^#{Regexp.escape(@base_topic)}/(?<addr>\h{6})/(?<property>discover|label|down|up|stop|positionpulses|positionpercent|ip|wink|reset|(?<speed_type>upspeed|downspeed|slowspeed)|uplimit|downlimit|direction|ip(?<ip>\d+)(?<ip_type>pulses|percent)|groups)/set$}))
          addr = SDN::Message.parse_address(match[:addr])
          property = match[:property]
          # not homie compliant; allows linking the positionpercent property
          # directly to an OpenHAB rollershutter channel
          if property == 'positionpercent' && value =~ /^(?:UP|DOWN|STOP)$/i
            property = value.downcase
            value = "true"
          end
          mqtt_addr = SDN::Message.print_address(addr).gsub('.', '')
          motor = @motors[mqtt_addr]
          is_group = SDN::Message.is_group_address?(addr)
          group = @groups[mqtt_addr]
          follow_up = SDN::Message::GetMotorStatus.new(addr)
          message = case property
            when 'discover'
              follow_up = nil
              SDN::Message::GetNodeAddr.new(addr) if value == "true"
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
              SDN::Message::MoveTo.new(addr, property.sub('position', 'position_').to_sym, value.to_i)
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
              @mutex.synchronize do
                messages.each { |m| @command_queue.push(m) }
                @cond.signal
              end
              nil
          end
          if message
            @mutex.synchronize do
              @command_queue.push(message)
              @request_queue.push(follow_up) unless @request_queue.include?(follow_up)
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
      publish("#{addr}/$properties", "discover,label,down,up,stop,positionpulses,positionpercent,ip,wink,reset,state,last_direction,last_action_source,last_action_cause,uplimit,downlimit,direction,upspeed,downspeed,slowspeed,#{(1..16).map { |ip| "ip#{ip}pulses,ip#{ip}percent" }.join(',')},groups")

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
      publish("$nodes", (["discovery"] + @motors.keys.sort + @groups.keys.sort).join(","))

      sdn_addr = SDN::Message.parse_address(addr)
      @mutex.synchronize do
        @request_queue.push(SDN::Message::GetNodeLabel.new(sdn_addr))
        @request_queue.push(SDN::Message::GetMotorStatus.new(sdn_addr))
        @request_queue.push(SDN::Message::GetMotorLimits.new(sdn_addr))
        @request_queue.push(SDN::Message::GetMotorDirection.new(sdn_addr))
        @request_queue.push(SDN::Message::GetMotorRollingSpeed.new(sdn_addr))
        (1..16).each { |ip| @request_queue.push(SDN::Message::GetMotorIP.new(sdn_addr, ip)) }
        (0...16).each { |g| @request_queue.push(SDN::Message::GetGroupAddr.new(sdn_addr, g)) }

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
      publish("#{addr}/$properties", "discover,down,up,stop,positionpulses,positionpercent,ip,wink,reset,state,motors")

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

      publish("#{addr}/state/$name", "State of the motors; only set if all motors are in the same state")
      publish("#{addr}/state/$datatype", "enum")
      publish("#{addr}/state/$format", SDN::Message::PostMotorStatus::STATE.keys.join(','))

      publish("#{addr}/motors/$name", "Motors that are members of this group")
      publish("#{addr}/motors/$datatype", "string")

      group = @groups[addr] = Group.new(self, addr)
      publish("$nodes", (["discovery"] + @motors.keys.sort + @groups.keys.sort).join(","))
      group
    end
  end
end
