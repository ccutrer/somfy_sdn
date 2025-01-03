# frozen_string_literal: true

require "mqtt"
require "mqtt-homeassistant"
require "uri"
require "set"

require "sdn/cli/mqtt/group"
require "sdn/cli/mqtt/motor"
require "sdn/cli/mqtt/p_queue"
require "sdn/cli/mqtt/read"
require "sdn/cli/mqtt/write"
require "sdn/cli/mqtt/subscriptions"
require "sdn/version"

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
        @device_id = device_id
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

          hass_device = {
            name: "Somfy SDN Bridge",
            identifiers: @device_id,
            sw_version: SDN::VERSION
          }
          @mqtt.publish_hass_button("discover",
                                    command_topic: "#{@base_topic}/FFFFFF/discover/set",
                                    device: hass_device,
                                    icon: "mdi:search-add",
                                    name: "Discover Motors",
                                    node_id: @device_id,
                                    object_id: "discover",
                                    unique_id: "#{@device_id}_discover",
                                    payload_press: "true")

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
          hass_device = {
            identifiers: addr,
            model_id: node_type,
            name: addr,
            via_device: @device_id
          }
          node_id = "#{@device_id}_#{addr}"

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

          @mqtt.publish_hass_button("discover",
                                    command_topic: "#{@base_topic}/#{addr}/discover/set",
                                    device: hass_device,
                                    icon: "mdi:search-add",
                                    name: "Rediscover",
                                    node_id: node_id,
                                    object_id: "discover",
                                    payload_press: "true",
                                    unique_id: "#{node_id}_discover")

          publish("#{addr}/label/$name", "Node label")
          publish("#{addr}/label/$datatype", "string")
          publish("#{addr}/label/$settable", "true")
          @mqtt.publish_hass_text("label",
                                  command_topic: "#{@base_topic}/#{addr}/label/set",
                                  device: hass_device,
                                  entity_category: :config,
                                  icon: "mdi:rename",
                                  max: 16,
                                  name: "Label",
                                  node_id: node_id,
                                  unique_id: "#{node_id}_label")

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

          @mqtt.publish_hass_cover("motor",
                                   command_topic: "#{@base_topic}/#{addr}/control/set",
                                   device: hass_device,
                                   icon: "mdi:roller-shade",
                                   name: "Motor",
                                   node_id: node_id,
                                   payload_close: "down",
                                   payload_open: "up",
                                   payload_stop: "stop",
                                   position_open: 0,
                                   position_closed: 100,
                                   position_topic: "#{@base_topic}/#{addr}/position-percent",
                                   set_position_topic: "#{@base_topic}/#{addr}/position-percent/set",
                                   state_topic: "#{@base_topic}/#{addr}/hass-state",
                                   unique_id: "#{node_id}_motor")
          {
            Wink: "mdi:emoticon-wink",
            Next_IP: "mdi:skip-next",
            Previous_IP: "mdi:skip-previous",
            Refresh: "mdi:refresh"
          }.each do |command, icon|
            @mqtt.publish_hass_button(command.to_s.downcase,
                                      command_topic: "#{@base_topic}/#{addr}/control/set",
                                      device: hass_device,
                                      icon: icon,
                                      name: command.to_s.sub("_", " "),
                                      node_id: node_id,
                                      payload_press: command.to_s.downcase,
                                      unique_id: "#{node_id}_#{command.to_s.downcase}")
          end

          publish("#{addr}/position-pulses/$name", "Position from up limit (in pulses)")
          publish("#{addr}/position-pulses/$datatype", "integer")
          publish("#{addr}/position-pulses/$format", "0:65535")
          publish("#{addr}/position-pulses/$unit", "pulses")
          publish("#{addr}/position-pulses/$settable", "true")

          @mqtt.publish_hass_number("position-pulses",
                                    command_topic: "#{@base_topic}/#{addr}/position-pulses/set",
                                    device: hass_device,
                                    enabled_by_default: false,
                                    max: 65_536,
                                    min: 0,
                                    name: "Position (Pulses)",
                                    node_id: node_id,
                                    object_id: "position-pulses",
                                    state_topic: "#{@base_topic}/#{addr}/position-pulses",
                                    step: 10,
                                    unit_of_measurement: "pulses",
                                    unique_id: "#{node_id}_position-pulses")

          publish("#{addr}/ip/$name", "Intermediate Position")
          publish("#{addr}/ip/$datatype", "integer")
          publish("#{addr}/ip/$format", "1:16")
          publish("#{addr}/ip/$settable", "true")
          publish("#{addr}/ip/$retained", "false") if node_type == :st50ilt2

          @mqtt.publish_hass_number("ip",
                                    command_topic: "#{@base_topic}/#{addr}/ip/set",
                                    device: hass_device,
                                    name: "Intermediate Position",
                                    max: 16,
                                    min: 0,
                                    node_id: node_id,
                                    object_id: "ip",
                                    payload_reset: "",
                                    state_topic: "#{@base_topic}/#{addr}/ip",
                                    unique_id: "#{node_id}_ip")

          publish("#{addr}/down-limit/$name", "Down limit")
          publish("#{addr}/down-limit/$datatype", "integer")
          publish("#{addr}/down-limit/$format", "0:65535")
          publish("#{addr}/down-limit/$unit", "pulses")
          publish("#{addr}/down-limit/$settable", "true")

          @mqtt.publish_hass_number("down-limit",
                                    command_topic: "#{@base_topic}/#{addr}/down-limit/set",
                                    device: hass_device,
                                    entity_category: :config,
                                    icon: "mdi:roller-shade-closed",
                                    max: 65_536,
                                    min: 0,
                                    node_id: node_id,
                                    payload_reset: "",
                                    state_topic: "#{@base_topic}/#{addr}/down-limit",
                                    step: 10,
                                    unit_of_measurement: "pulses",
                                    unique_id: "#{node_id}_down-limit")

          publish("#{addr}/last-direction/$name", "Direction of last motion")
          publish("#{addr}/last-direction/$datatype", "enum")
          publish("#{addr}/last-direction/$format", Message::PostMotorStatus::DIRECTION.keys.join(","))

          unless node_type == :st50ilt2
            publish("#{addr}/reset/$name", "Recall factory settings")
            publish("#{addr}/reset/$datatype", "enum")
            publish("#{addr}/reset/$format", Message::SetFactoryDefault::RESET.keys.join(","))
            publish("#{addr}/reset/$settable", "true")
            publish("#{addr}/reset/$retained", "false")

            Message::SetFactoryDefault::RESET.each_key do |key|
              @mqtt.publish_hass_button("reset_#{key}",
                                        command_topic: "#{@base_topic}/#{addr}/reset/set",
                                        device: hass_device,
                                        enabled_by_default: false,
                                        entity_category: :config,
                                        name: "Reset #{key.to_s.sub("_", " ")}",
                                        node_id: node_id,
                                        payload_press: key,
                                        unique_id: "#{node_id}_#{key}")
            end

            publish("#{addr}/last-action-source/$name", "Source of last action")
            publish("#{addr}/last-action-source/$datatype", "enum")
            publish("#{addr}/last-action-source/$format", Message::PostMotorStatus::SOURCE.keys.join(","))

            @mqtt.publish_hass_sensor("last-action-source",
                                      device: hass_device,
                                      device_class: :enum,
                                      entity_category: :diagnostic,
                                      name: "Source of last action",
                                      node_id: node_id,
                                      object_id: "last-action-source",
                                      options: Message::PostMotorStatus::SOURCE.keys,
                                      state_topic: "#{@base_topic}/#{addr}/last-action-source",
                                      unique_id: "#{node_id}_last-action-source")

            publish("#{addr}/last-action-cause/$name", "Cause of last action")
            publish("#{addr}/last-action-cause/$datatype", "enum")
            publish("#{addr}/last-action-cause/$format", Message::PostMotorStatus::CAUSE.keys.join(","))

            @mqtt.publish_hass_sensor("last-action-cause",
                                      device: hass_device,
                                      device_class: :enum,
                                      entity_category: :diagnostic,
                                      name: "Cause of last action",
                                      node_id: node_id,
                                      object_id: "last-action-cause",
                                      options: Message::PostMotorStatus::CAUSE.keys,
                                      state_topic: "#{@base_topic}/#{addr}/last-action-cause",
                                      unique_id: "#{node_id}_last-action-cause")

            publish("#{addr}/up-limit/$name", "Up limit (always = 0)")
            publish("#{addr}/up-limit/$datatype", "integer")
            publish("#{addr}/up-limit/$format", "0:65535")
            publish("#{addr}/up-limit/$unit", "pulses")
            publish("#{addr}/up-limit/$settable", "true")

            @mqtt.publish_hass_number("up-limit",
                                      command_topic: "#{@base_topic}/#{addr}/up-limit/set",
                                      device: hass_device,
                                      entity_category: :config,
                                      icon: "mdi:roller-shade-open",
                                      max: 65_536,
                                      min: 0,
                                      name: "Up Limit",
                                      node_id: node_id,
                                      payload_reset: "",
                                      state_topic: "#{@base_topic}/#{addr}/up-limit",
                                      step: 10,
                                      unit_of_measurement: "pulses",
                                      unique_id: "#{node_id}_up-limit")

            publish("#{addr}/direction/$name", "Motor rotation direction")
            publish("#{addr}/direction/$datatype", "enum")
            publish("#{addr}/direction/$format", "standard,reversed")
            publish("#{addr}/direction/$settable", "true")

            @mqtt.publish_hass_select("direction",
                                      command_topic: "#{@base_topic}/#{addr}/direction/set",
                                      device: hass_device,
                                      entity_category: :config,
                                      icon: "mdi:circle-arrows",
                                      name: "Motor rotation direction",
                                      node_id: node_id,
                                      object_id: "direction",
                                      options: %w[standard reversed],
                                      state_topic: "#{@base_topic}/#{addr}/direction",
                                      unique_id: "#{node_id}_direction")

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

            %w[Up Slow].each do |speed_type|
              @mqtt.publish_hass_number("#{speed_type.downcase}-speed",
                                        command_topic: "#{@base_topic}/#{addr}/#{speed_type.downcase}-speed/set",
                                        device: hass_device,
                                        entity_category: :config,
                                        icon: "mdi:car-speed-limiter",
                                        max: 28,
                                        min: 6,
                                        name: "#{speed_type} speed",
                                        node_id: node_id,
                                        state_topic: "#{@base_topic}/#{addr}/#{speed_type.downcase}-speed",
                                        unit_of_measurement: "RPM",
                                        unique_id: "#{node_id}_#{speed_type.downcase}-speed")
            end
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

            @mqtt.publish_hass_number("ip#{ip}-pulses",
                                      command_topic: "#{@base_topic}/#{addr}/ip#{ip}-pulses/set",
                                      device: hass_device,
                                      enabled_by_default: false,
                                      entity_category: :config,
                                      max: 65_536,
                                      min: 0,
                                      name: "Intermediation Position #{ip} (Pulses)",
                                      node_id: node_id,
                                      object_id: "ip#{ip}-pulses",
                                      payload_reset: "",
                                      state_topic: "#{@base_topic}/#{addr}/ip#{ip}-pulses",
                                      step: 10,
                                      unit_of_measurement: "pulses",
                                      unique_id: "#{node_id}_ip#{ip}-pulses")

            publish("#{addr}/ip#{ip}-percent/$name", "Intermediate Position #{ip}")
            publish("#{addr}/ip#{ip}-percent/$datatype", "integer")
            publish("#{addr}/ip#{ip}-percent/$format", "0:100")
            publish("#{addr}/ip#{ip}-percent/$unit", "%")
            publish("#{addr}/ip#{ip}-percent/$settable", "true")

            @mqtt.publish_hass_number("ip#{ip}-percent",
                                      command_topic: "#{@base_topic}/#{addr}/ip#{ip}-percent/set",
                                      device: hass_device,
                                      entity_category: :config,
                                      max: 100,
                                      min: 0,
                                      name: "Intermediation Position #{ip} (Percent)",
                                      node_id: node_id,
                                      object_id: "ip#{ip}-percent",
                                      payload_reset: "",
                                      state_topic: "#{@base_topic}/#{addr}/ip#{ip}-percent",
                                      unit_of_measurement: "%",
                                      unique_id: "#{node_id}_ip#{ip}-percent")
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
          hass_device = {
            identifiers: addr,
            model: "Shade Group",
            name: addr,
            via_device: @device_id
          }
          node_id = "#{@device_id}_#{addr}"

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

          @mqtt.publish_hass_button("discover",
                                    command_topic: "#{@base_topic}/#{addr}/discover/set",
                                    device: hass_device,
                                    icon: "mdi:search-add",
                                    name: "Rediscover",
                                    node_id: node_id,
                                    object_id: "discover",
                                    payload_press: "true",
                                    unique_id: "#{node_id}_discover")

          publish("#{addr}/control/$name", "Control motors")
          publish("#{addr}/control/$datatype", "enum")
          publish("#{addr}/control/$format", "up,down,stop,wink,next_ip,previous_ip,refresh")
          publish("#{addr}/control/$settable", "true")
          publish("#{addr}/control/$retained", "false")

          @mqtt.publish_hass_cover("group",
                                   command_topic: "#{@base_topic}/#{addr}/control/set",
                                   device: hass_device,
                                   icon: "mdi:roller-shade",
                                   name: "Group",
                                   node_id: node_id,
                                   payload_close: "down",
                                   payload_open: "up",
                                   payload_stop: "stop",
                                   position_open: 0,
                                   position_closed: 100,
                                   position_topic: "#{@base_topic}/#{addr}/position-percent",
                                   set_position_topic: "#{@base_topic}/#{addr}/position-percent/set",
                                   state_topic: "#{@base_topic}/#{addr}/hass-state",
                                   unique_id: "#{node_id}_group")
          {
            Wink: "mdi:emoticon-wink",
            Next_IP: "mdi:skip-next",
            Previous_IP: "mdi:skip-previous",
            Refresh: "mdi:refresh"
          }.each do |command, icon|
            @mqtt.publish_hass_button(command.to_s.downcase,
                                      command_topic: "#{@base_topic}/#{addr}/control/set",
                                      device: hass_device,
                                      icon: icon,
                                      name: command.to_s.sub("_", " "),
                                      node_id: node_id,
                                      payload_press: command.to_s.downcase,
                                      unique_id: "#{node_id}_#{command.to_s.downcase}")
          end

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

          @mqtt.publish_hass_number("position-pulses",
                                    command_topic: "#{@base_topic}/#{addr}/position-pulses/set",
                                    device: hass_device,
                                    enabled_by_default: false,
                                    max: 65_536,
                                    min: 0,
                                    name: "Position (Pulses)",
                                    node_id: node_id,
                                    object_id: "position-pulses",
                                    state_topic: "#{@base_topic}/#{addr}/position-pulses",
                                    step: 10,
                                    unit_of_measurement: "pulses",
                                    unique_id: "#{node_id}_position-pulses")

          publish("#{addr}/position-percent/$name", "Position (in %)")
          publish("#{addr}/position-percent/$datatype", "integer")
          publish("#{addr}/position-percent/$format", "0:100")
          publish("#{addr}/position-percent/$unit", "%")
          publish("#{addr}/position-percent/$settable", "true")

          publish("#{addr}/ip/$name", "Intermediate Position")
          publish("#{addr}/ip/$datatype", "integer")
          publish("#{addr}/ip/$format", "1:16")
          publish("#{addr}/ip/$settable", "true")

          @mqtt.publish_hass_number("ip",
                                    command_topic: "#{@base_topic}/#{addr}/ip/set",
                                    device: hass_device,
                                    name: "Intermediate Position",
                                    max: 16,
                                    min: 0,
                                    node_id: node_id,
                                    object_id: "ip",
                                    payload_reset: "",
                                    state_topic: "#{@base_topic}/#{addr}/ip",
                                    unique_id: "#{node_id}_ip")

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
