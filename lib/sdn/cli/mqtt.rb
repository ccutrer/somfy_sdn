# frozen_string_literal: true

require "mqtt"
require "uri"
require "set"

require "sdn/cli/mqtt/group"
require "sdn/cli/mqtt/motor"
require "sdn/cli/mqtt/p_queue"
require "sdn/cli/mqtt/read"
require "sdn/cli/mqtt/write"
require "sdn/cli/mqtt/subscriptions"

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

      def initialize(sdn,
                     mqtt_uri,
                     device_id: "somfy",
                     base_topic: "homie",
                     auto_discover: true,
                     known_motors: [])
        @base_topic = "#{base_topic}/#{device_id}"
        @mqtt = ::MQTT::Client.new(mqtt_uri)
        @mqtt.set_will("#{@base_topic}/$state", "lost", retain: true)
        @mqtt.connect

        @motors = {}
        @groups = {}

        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @queue = PQueue.new
        @response_pending = false
        @broadcast_pending = false

        @auto_discover = auto_discover
        @motors_found = true

        clear_tree(@base_topic)
        publish_basic_attributes

        @sdn = sdn

        known_motors&.each do |addr|
          addr = Message.parse_address(addr)
          @queue.push(MessageAndRetries.new(Message::GetMotorPosition.new(addr), 5, 0))
        end

        Thread.abort_on_exception = true
        Thread.new { read }
        Thread.new { write }
        @mqtt.get { |packet| handle_message(packet.topic, packet.payload) }
      end

      def publish(topic, value)
        @mqtt.publish("#{@base_topic}/#{topic}", value, retain: true, qos: 1)
      end

      def subscribe(topic)
        @mqtt.subscribe("#{@base_topic}/#{topic}")
      end

      def enqueue(message)
        @mutex.synchronize do
          break if @queue.include?(message)

          @queue.push(message)
          @cond.signal
        end
      end

      def clear_tree(topic)
        @mqtt.subscribe("#{topic}/#")
        @mqtt.unsubscribe("#{topic}/#", wait_for_ack: true)
        until @mqtt.queue_empty?
          packet = @mqtt.get
          @mqtt.publish(packet.topic, nil, retain: true)
        end
      end

      def publish_basic_attributes
        @mqtt.batch_publish do
          publish("$homie", "4.0.0")
          publish("$name", "Somfy SDN Network")
          publish("$state", "init")
          publish("$nodes", "FFFFFF")

          publish("FFFFFF/$name", "Broadcast")
          publish("FFFFFF/$type", "sdn")
          publish("FFFFFF/$properties", "discover")

          publish("FFFFFF/discover/$name", "Trigger Motor Discovery")
          publish("FFFFFF/discover/$datatype", "enum")
          publish("FFFFFF/discover/$format", "discover")
          publish("FFFFFF/discover/$settable", "true")
          publish("FFFFFF/discover/$retained", "false")

          subscribe_all

          publish("$state", "ready")
        end

        @mqtt.on_reconnect do
          subscribe_all
          publish("$state", :init)
          publish("$state", :ready)
        end
      end

      def subscribe_all
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
      end

      def publish_motor(addr, node_type)
        motor = nil

        @mqtt.batch_publish do
          publish("#{addr}/$name", addr)
          publish("#{addr}/$type", node_type.to_s)
          properties = %w[
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
            last-direction
          ] + (1..16).map { |ip| ["ip#{ip}-pulses", "ip#{ip}-percent"] }.flatten

          unless node_type == :st50ilt2
            properties.push("reset",
                            "last-action-source",
                            "last-action-cause",
                            "up-limit",
                            "direction",
                            "up-speed",
                            "down-speed",
                            "slow-speed")
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
          publish("#{addr}/state/$format", Message::PostMotorStatus::STATE.keys.join(","))

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

          publish("#{addr}/last-direction/$name", "Direction of last motion")
          publish("#{addr}/last-direction/$datatype", "enum")
          publish("#{addr}/last-direction/$format", Message::PostMotorStatus::DIRECTION.keys.join(","))

          unless node_type == :st50ilt2
            publish("#{addr}/reset/$name", "Recall factory settings")
            publish("#{addr}/reset/$datatype", "enum")
            publish("#{addr}/reset/$format", Message::SetFactoryDefault::RESET.keys.join(","))
            publish("#{addr}/reset/$settable", "true")
            publish("#{addr}/reset/$retained", "false")

            publish("#{addr}/last-action-source/$name", "Source of last action")
            publish("#{addr}/last-action-source/$datatype", "enum")
            publish("#{addr}/last-action-source/$format", Message::PostMotorStatus::SOURCE.keys.join(","))

            publish("#{addr}/last-action-cause/$name", "Cause of last action")
            publish("#{addr}/last-action-cause/$datatype", "enum")
            publish("#{addr}/last-action-cause/$format", Message::PostMotorStatus::CAUSE.keys.join(","))

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

          publish("#{addr}/groups/$name", "Group Memberships (comma separated, address must start 0101xx)")
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
          publish("$nodes", (["FFFFFF"] + @motors.keys.sort + @groups.keys.sort).join(","))
        end

        sdn_addr = Message.parse_address(addr)
        @mutex.synchronize do
          # message priorities are:
          # 0 - control
          # 1 - follow-up (i.e. get position after control)
          # 2 - get motor limits
          # 3 - get motor info
          # 4 - get group 1
          # 5 - get ip 1
          # 6 - get group 2
          # 7 - get ip 2
          # ...
          # 50 - discover

          # The Group and IP sorting makes it so you quickly get the most commonly used group
          # and IP addresses, while the almost-never-used ones are pushed to the bottom of the list

          @queue.push(MessageAndRetries.new(Message::GetNodeLabel.new(sdn_addr), 5, 3))

          case node_type
          when :st30, 0x20 # no idea why 0x20, but that's what I get
            @queue.push(MessageAndRetries.new(Message::GetMotorLimits.new(sdn_addr), 5, 2))
            @queue.push(MessageAndRetries.new(Message::GetMotorStatus.new(sdn_addr), 5, 3))
            @queue.push(MessageAndRetries.new(Message::GetMotorDirection.new(sdn_addr), 5, 3))
            @queue.push(MessageAndRetries.new(Message::GetMotorRollingSpeed.new(sdn_addr), 5, 3))
            (1..16).each do |ip|
              @queue.push(MessageAndRetries.new(Message::GetMotorIP.new(sdn_addr, ip), 5, (2 * ip) + 3))
            end
          when :st50ilt2
            @queue.push(MessageAndRetries.new(Message::ILT2::GetMotorPosition.new(sdn_addr), 5, 2))
            @queue.push(MessageAndRetries.new(Message::ILT2::GetMotorSettings.new(sdn_addr), 5, 3))
            (1..16).each do |ip|
              @queue.push(MessageAndRetries.new(Message::ILT2::GetMotorIP.new(sdn_addr, ip), 5, (2 * ip) + 3))
            end
          end
          (1..16).each do |g|
            @queue.push(MessageAndRetries.new(Message::GetGroupAddr.new(sdn_addr, g), 5, (2 * g) + 2))
          end

          @cond.signal
        end

        motor
      end

      def touch_group(group_addr)
        group = @groups[Message.print_address(group_addr).delete(".")]
        group&.publish(:motors, group.motors_string)
      end

      def add_group(addr)
        addr = addr.delete(".")
        group = @groups[addr]
        return group if group

        @mqtt.batch_publish do
          publish("#{addr}/$name", addr)
          publish("#{addr}/$type", "Shade Group")
          publish("#{addr}/$properties",
                  "discover,control,jog-ms,jog-pulses,position-pulses,position-percent," \
                  "ip,reset,state,last-direction,motors")

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

          publish("#{addr}/state/$name", "State of the motors")
          publish("#{addr}/state/$datatype", "enum")
          publish("#{addr}/state/$format", "#{Message::PostMotorStatus::STATE.keys.join(",")},mixed")

          publish("#{addr}/last-direction/$name", "Direction of last motion")
          publish("#{addr}/last-direction/$datatype", "enum")
          publish("#{addr}/last-direction/$format", "#{Message::PostMotorStatus::DIRECTION.keys.join(",")},mixed")

          publish("#{addr}/motors/$name", "Comma separated motor addresses that are members of this group")
          publish("#{addr}/motors/$datatype", "string")

          group = @groups[addr] = Group.new(self, addr)
          publish("$nodes", (["FFFFFF"] + @motors.keys.sort + @groups.keys.sort).join(","))
        end
        group
      end
    end
  end
end
