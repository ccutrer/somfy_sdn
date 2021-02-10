require 'mqtt'
require 'uri'
require 'set'

require 'sdn/cli/mqtt/group'
require 'sdn/cli/mqtt/motor'
require 'sdn/cli/mqtt/read'
require 'sdn/cli/mqtt/write'
require 'sdn/cli/mqtt/subscriptions'

module SDN
  module CLI
    class MQTT
      MessageAndRetries = Struct.new(:message, :remaining_retries, :priority)

      include Read
      include Write
      include Subscriptions

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

        read_thread = Thread.new { read }
        write_thread = Thread.new { write }
        @mqtt.get { |topic, value| handle_message(topic, value) }
      end

      def publish(topic, value)
        @mqtt.publish("#{@base_topic}/#{topic}", value, true, 1)
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
        publish("$nodes", "ffffff")

        publish("ffffff/$name", "Broadcast")
        publish("ffffff/$type", "sdn")
        publish("ffffff/$properties", "discover")

        publish("ffffff/discover/$name", "Trigger Motor Discovery")
        publish("ffffff/discover/$datatype", "enum")
        publish("ffffff/discover/$format", "discover")
        publish("ffffff/discover/$settable", "true")
        publish("ffffff/discover/$retained", "false")

        subscribe("+/discover/set")
        subscribe("+/label/set")
        subscribe("+/control/set")
        subscribe("+/jog-ms/set")
        subscribe("+/jog-pulses/set")
        subscribe("+/position-pulses/set")
        subscribe("+/position-percent/set")
        subscribe("+/ip/set")
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
          label
          state
          control
          jog-ms
          jog-pulses
          position-pulses
          position-percent
          ip
          down-limit
          groups
        } + (1..16).map { |ip| ["ip#{ip}-pulses", "ip#{ip}-percent"] }.flatten

        unless node_type == :st50ilt2
          properties.concat %w{
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
        publish("#{addr}/discover/$datatype", "enum")
        publish("#{addr}/discover/$format", "discover")
        publish("#{addr}/discover/$settable", "true")
        publish("#{addr}/discover/$retained", "false")

        publish("#{addr}/label/$name", "Node label")
        publish("#{addr}/label/$datatype", "string")
        publish("#{addr}/label/$settable", "true")

        publish("#{addr}/state/$name", "Current state of the motor")
        publish("#{addr}/state/$datatype", "enum")
        publish("#{addr}/state/$format", Message::PostMotorStatus::STATE.keys.join(','))

        publish("#{addr}/control/$name", "Control motor")
        publish("#{addr}/control/$datatype", "enum")
        publish("#{addr}/control/$format", "up,down,stop,wink,next_ip,previous_ip,refresh")
        publish("#{addr}/control/$settable", "true")
        publish("#{addr}/control/$retained", "false")

        publish("#{addr}/jog-ms/$name", "Jog motor by ms")
        publish("#{addr}/jog-ms/$datatype", "integer")
        publish("#{addr}/jog-ms/$format", "-65535:65535")
        publish("#{addr}/jog-ms/$unit", "ms")
        publish("#{addr}/jog-ms/$settable", "true")
        publish("#{addr}/jog-ms/$retained", "false")

        publish("#{addr}/jog-pulses/$name", "Jog motor by pulses")
        publish("#{addr}/jog-pulses/$datatype", "integer")
        publish("#{addr}/jog-pulses/$format", "-65535:65535")
        publish("#{addr}/jog-pulses/$unit", "pulses")
        publish("#{addr}/jog-pulses/$settable", "true")
        publish("#{addr}/jog-pulses/$retained", "false")

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
          publish("#{addr}/reset/$name", "Recall factory settings")
          publish("#{addr}/reset/$datatype", "enum")
          publish("#{addr}/reset/$format", Message::SetFactoryDefault::RESET.keys.join(','))
          publish("#{addr}/reset/$settable", "true")
          publish("#{addr}/reset/$retained", "false")

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
        publish("$nodes", (["ffffff"] + @motors.keys.sort + @groups.keys.sort).join(","))

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
        publish("#{addr}/$properties", "discover,control,jog-ms,jog-pulses,position-pulses,position-percent,ip,reset,state,motors")

        publish("#{addr}/discover/$name", "Trigger Motor Discovery")
        publish("#{addr}/discover/$datatype", "enum")
        publish("#{addr}/discover/$format", "discover")
        publish("#{addr}/discover/$settable", "true")
        publish("#{addr}/discover/$retained", "false")

        publish("#{addr}/control/$name", "Control motors")
        publish("#{addr}/control/$datatype", "enum")
        publish("#{addr}/control/$format", "up,down,stop,wink,next_ip,previous_ip,refresh")
        publish("#{addr}/control/$settable", "true")
        publish("#{addr}/control/$retained", "false")

        publish("#{addr}/jog-ms/$name", "Jog motors by ms")
        publish("#{addr}/jog-ms/$datatype", "integer")
        publish("#{addr}/jog-ms/$format", "-65535:65535")
        publish("#{addr}/jog-ms/$unit", "ms")
        publish("#{addr}/jog-ms/$settable", "true")
        publish("#{addr}/jog-ms/$retained", "false")

        publish("#{addr}/jog-pulses/$name", "Jog motors by pulses")
        publish("#{addr}/jog-pulses/$datatype", "integer")
        publish("#{addr}/jog-pulses/$format", "-65535:65535")
        publish("#{addr}/jog-pulses/$unit", "pulses")
        publish("#{addr}/jog-pulses/$settable", "true")
        publish("#{addr}/jog-pulses/$retained", "false")

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

        publish("#{addr}/state/$name", "State of the motors; only set if all motors are in the same state")
        publish("#{addr}/state/$datatype", "enum")
        publish("#{addr}/state/$format", Message::PostMotorStatus::STATE.keys.join(','))

        publish("#{addr}/motors/$name", "Motors that are members of this group")
        publish("#{addr}/motors/$datatype", "string")

        group = @groups[addr] = Group.new(self, addr)
        publish("$nodes", (["ffffff"] + @motors.keys.sort + @groups.keys.sort).join(","))
        group
      end
    end
  end
end