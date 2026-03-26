# frozen_string_literal: true

module SDN
  module CLI
    # @!visibility private
    class Simulator
      # Simulated motor implementation that responds to a subset of SDN requests.
      class MockMotor
        # Simulated motor address.
        #
        # @return [(Integer, Integer, Integer)]
        attr_accessor :address

        # @return [:st30, :lt50]
        attr_accessor :node_type

        # @return [String]
        attr_accessor :label

        # Stored intermediate positions keyed by slot index.
        #
        # @return [<Integer, nil>]
        attr_accessor :ips

        # Current motor position in pulses from the upper limit.
        #
        # @return [Integer, nil]
        attr_accessor :position_pulses

        # @return [Integer, nil]
        attr_accessor :up_limit

        # @return [Integer, nil]
        attr_accessor :down_limit

        # Stored group memberships keyed by slot index.
        #
        # @return [<(Integer, Integer, Integer), nil>]
        attr_accessor :groups

        # @return [Integer, nil]
        attr_accessor :network_lock_priority

        # @return [Integer, nil]
        attr_accessor :lock_priority

        # Simulated ILT2 IR channel bitmask.
        #
        # @return [Integer]
        attr_accessor :ir_channels

        # Absolute move target types supported by the simulator implementation.
        ALLOWED_MOVE_TYPES = %i[up_limit
                                down_limit
                                ip
                                position_pulses
                                position_percent].freeze

        # Creates a simulated motor backed by an SDN client.
        #
        # @param client [SDN::Client] SDN client used to receive and send messages
        def initialize(client)
          @client = client
          self.address = Message.parse_address("00.00.00")
          self.node_type = :st30
          self.label = ""
          self.ips = Array.new(16)
          self.groups = Array.new(16)
          self.ir_channels = 0
          self.lock_priority = 0
        end

        private

        # Starts processing incoming SDN messages for the simulated motor.
        #
        # @return [void]
        def process
          loop do
            @client.receive do |message|
              SDN.logger.info "Received #{message.inspect}"
              next unless message.is_a?(Message::ILT2::MasterControl) ||
                          message.dest == address ||
                          message.dest == BROADCAST_ADDRESS

              case message
              when Message::GetGroupAddr
                next nack(message) unless (1..16).cover?(message.group_index)

                respond(message.src, Message::PostGroupAddr.new(message.group_index, groups[message.group_index - 1]))
              when Message::GetMotorIP
                next nack(message) unless (1..16).cover?(message.ip)

                respond(message.src,
                        Message::PostMotorIP.new(message.ip, ips[message.ip - 1], to_percent(ips[message.ip - 1])))
              when Message::GetMotorLimits
                respond(message.src, Message::PostMotorLimits.new(up_limit, down_limit))
              when Message::GetMotorPosition
                respond(message.src, Message::PostMotorPosition.new(
                                       position_pulses,
                                       to_percent(position_pulses),
                                       ips.index(position_pulses)&.+(1)
                                     ))
              when Message::GetNodeAddr then respond(message.src, Message::PostNodeAddr.new)
              when Message::GetNodeLabel then respond(message.src, Message::PostNodeLabel.new(label))
              when Message::ILT2::GetIRConfig then respond(message.src, Message::ILT2::PostIRConfig.new(ir_channels))
              when Message::ILT2::GetLockStatus then respond(message.src,
                                                             Message::ILT2::PostLockStatus.new(lock_priority))
              when Message::ILT2::GetMotorIP
                respond(message.src, Message::ILT2::PostMotorIP.new(message.ip, ips[message.ip - 1]))
              when Message::ILT2::GetMotorPosition
                respond(message.src, Message::ILT2::PostMotorPosition.new(position_pulses, to_percent(position_pulses)))
              when Message::ILT2::GetMotorSettings
                respond(message.src, Message::ILT2::PostMotorSettings.new(down_limit))
              when Message::ILT2::SetIRConfig then self.ir_channels = message.channels
              when Message::ILT2::SetLockStatus then self.lock_priority = message.priority
              when Message::ILT2::SetMotorIP
                next nack(message) unless (1..16).cover?(message.ip)

                ips[message.ip - 1] = message.value
                ack(message)
              when Message::ILT2::SetMotorPosition
                next nack(message) unless down_limit

                self.position_pulses = case message.target_type
                                       when :up_limit then 0
                                       when :down_limit then down_limit
                                       when :ip
                                         next nack(message) unless (1..16).cover?(message.target)
                                         next nack(message) unless ips[message.target]

                                         ips[message.target]
                                       when :position_pulses
                                         next nack(message) if message.target - 1 > down_limit

                                         message.target - 1
                                       when :jog_up_pulses then [0, position_pulses - message.target].max
                                       when :jog_down_pulses then [down_limit, position_pulses + message.target].min
                                       when :position_percent
                                         next nack(message) if message.target > 100

                                         to_pulses(message.target.to_f)
                                       end
                ack(message)
              when Message::ILT2::SetMotorSettings
                if message.down_limit != 0
                  self.down_limit = message.down_limit
                  self.position_pulses = message.position_pulses
                end
              when Message::MoveTo
                next nack(message) unless down_limit
                next nack(message) unless ALLOWED_MOVE_TYPES.include?(message.target_type)

                self.position_pulses = case message.target_type
                                       when :up_limit then 0
                                       when :down_limit then down_limit
                                       when :ip
                                         next nack(message) unless (1..16).cover?(message.target)
                                         next nack(message) unless ips[message.target - 1]

                                         ips[message.target - 1]
                                       when :position_pulses
                                         next nack(message) if message.target > down_limit

                                         message.target
                                       when :position_percent
                                         next nack(message) if message.target > 100

                                         to_pulses(message.target)
                                       end
                ack(message)
              when Message::SetGroupAddr
                next nack(message) unless (1..16).cover?(message.group_index)

                groups[message.group_index - 1] = (message.group_address == [0, 0, 0]) ? nil : message.group_address
                ack(message)
              when Message::SetMotorIP
                next nack(message) unless (1..16).cover?(message.ip) || message.type == :distribute

                case message.type
                when :delete
                  ips[message.ip - 1] = nil
                  ack(message)
                when :current_position
                  ips[message.ip - 1] = position_pulses
                  ack(message)
                when :position_pulses
                  ips[message.ip - 1] = message.value
                  ack(message)
                when :position_percent
                  pulses = to_pulses(message.value)
                  if pulses
                    ips[message.ip - 1] = pulses
                    ack(message)
                  else
                    nack(message)
                  end
                when :distribute
                  next nack(message) unless down_limit
                  next nack(message) unless (1..15).cover?(message.value)

                  span = down_limit / (message.value + 1)
                  current = 0
                  (0...message.value).each do |ip|
                    ips[ip] = (current += span)
                  end
                  (message.value...16).each do |ip|
                    ips[ip] = nil
                  end
                  ack(message)
                end
              when Message::SetMotorLimits
                next nack(message) unless Message::SetMotorLimits::TARGET.key?(message.target)
                next nack(message) unless message.type == :jog_pulses

                self.up_limit ||= 0
                self.down_limit ||= 0
                self.position_pulses ||= 0

                next nack(message) if message.target == :up && position_pulses != 0
                next nack(message) if message.target == :down && position_pulses != down_limit

                case message.type
                when :jog_pulses
                  self.down_limit += message.value
                  self.position_pulses += message.value if message.target == :down
                end
                ack(message)
              when Message::SetNodeLabel then self.label = message.label
                                              ack(message)
              end
            end
          end
        end

        # Converts a pulse position to a percentage using the configured down limit.
        #
        # @param pulses [Integer, nil] position in pulses
        #
        # @return [Numeric, nil]
        def to_percent(pulses)
          (pulses && down_limit) ? 100.0 * pulses / down_limit : nil
        end

        # Converts a percentage to a pulse position using the configured down limit.
        #
        # @param percent [Numeric, nil] position in percent
        #
        # @return [Numeric, nil]
        def to_pulses(percent)
          (percent && down_limit) ? down_limit * percent / 100 : nil
        end

        # Sends an acknowledgement for the supplied message when one was requested.
        #
        # @param message [SDN::Message] request message
        #
        # @return [void]
        def ack(message)
          return unless message.ack_requested

          respond(Message::Ack.new(message.dest))
        end

        # Sends a negative acknowledgement for the supplied message when one was requested.
        #
        # @param message [SDN::Message] request message
        # @param _error_code [nil] reserved error code argument
        #
        # @return [void]
        def nack(message, _error_code = nil)
          return unless message.ack_requested

          respond(Message::Nack.new(message.dest))
        end

        def respond(dest, message)
          message.src = address
          message.node_type = node_type
          message.dest = dest
          @client.send(message)
        end
      end

      # Starts a simulator instance for a single mock motor.
      #
      # @param sdn [SDN::Client] SDN client connection
      # @param address [String, nil] optional simulated motor address
      def initialize(sdn, address = nil)
        motor = MockMotor.new(sdn)
        motor.address = Message.parse_address(address) if address
        motor.node_type = :lt50

        motor.process
      end
    end
  end
end
