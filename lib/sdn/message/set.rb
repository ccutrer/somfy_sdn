# frozen_string_literal: true

module SDN
  class Message
    # Command that resets a motor's persisted settings.
    class SetFactoryDefault < Message
      # (see Ack::MSG)
      MSG = 0x1f
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 1
      # Mapping from symbolic reset scopes to SDN parameter values.
      RESET = { all_settings: 0x00,
                group_addresses: 0x01,
                limits: 0x11,
                rotation: 0x12,
                rolling_speed: 0x13,
                ips: 0x15,
                locks: 0x17 }.freeze

      # @!attribute [rw] reset
      #
      # Requested reset scope.
      #
      # @return [:all_settings, :group_addresses, :limits, :rotation, :rolling_speed, :ips, :locks]
      attr_reader :reset

      # Creates a factory reset command.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param reset [:all_settings, :group_addresses, :limits, :rotation, :rolling_speed, :ips, :locks] reset scope
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, reset = :all_settings, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.reset = reset
      end

      # (see Message#parse)
      def parse(params)
        super
        self.reset = RESET.invert[to_number(params)]
      end

      def reset=(value)
        unless RESET.key?(value)
          raise ArgumentError,
                "reset must be one of :all_settings, :group_addresses, :limits, :rotation, :rolling_speed, :ips, :locks"
        end

        @reset = value
      end

      # (see Message#params)
      def params
        transform_param(RESET[reset])
      end
    end

    # Command that assigns a motor to a group slot.
    class SetGroupAddr < Message
      # (see Ack::MSG)
      MSG = 0x51
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 4

      # @!attribute [rw] group_address
      #
      # @return [(Integer, Integer, Integer), nil]
      attr_accessor :group_address

      # @!attribute [rw] group_index
      #
      # Group slot to assign the address to in the range 1..16.
      #
      # @return [Integer]
      attr_reader :group_index

      # Creates a group assignment command.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param group_index [Integer] group slot
      # @param group_address [(Integer, Integer, Integer), nil] group address
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, group_index = 1, group_address = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.group_index = group_index
        self.group_address = group_address
      end

      # (see Message#parse)
      def parse(params)
        super
        self.group_index = to_number(params[0]) + 1
        self.group_address = transform_param(params[1..3])
      end

      def group_index=(value)
        raise ArgumentError, "group_index is out of range" unless (1..16).cover?(value)

        @group_index = value
      end

      # (see Message#params)
      def params
        transform_param(group_index - 1) + transform_param(group_address || [0, 0, 0])
      end

      # (see Message#class_inspect)
      def class_inspect
        ", group_index=#{group_index.inspect}, group_address=#{group_address ? print_address(group_address) : "nil"}"
      end
    end

    # Command that sets a motor's rotation direction.
    class SetMotorDirection < Message
      # (see Ack::MSG)
      MSG = 0x12
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 1
      # Mapping from symbolic directions to SDN parameter values.
      DIRECTION = { standard: 0x00, reversed: 0x01 }.freeze

      # @!attribute [rw] direction
      #
      # @return [:standard, :reversed]
      attr_reader :direction

      # Creates a motor direction command.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param direction [:standard, :reversed] rotation direction
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, direction = :standard, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.direction = direction
      end

      # (see Message#parse)
      def parse(params)
        super
        self.direction = DIRECTION.invert[to_number(params[0])]
      end

      def direction=(value)
        raise ArgumentError, "direction must be one of :standard, :reversed" unless DIRECTION.key?(value)

        @direction = value
      end

      # (see Message#params)
      def params
        transform_param(DIRECTION[direction])
      end
    end

    # Command that stores, deletes, or distributes intermediate positions.
    class SetMotorIP < Message
      # (see Ack::MSG)
      MSG = 0x15
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 4
      # for distribute, value is how many IPs to distribute over
      # Mapping from symbolic write modes to SDN parameter values.
      TYPE = { delete: 0x00,
               current_position: 0x01,
               position_pulses: 0x02,
               position_percent: 0x03,
               distribute: 0x04 }.freeze

      # @!attribute [rw] type
      #
      # Requested intermediate-position write mode.
      #
      # @return [:delete, :current_position, :position_pulses, :position_percent, :distribute]
      attr_reader :type

      # @!attribute [rw] ip
      #
      # Requested intermediate-position slot in the range 1..16.
      #
      # @return [Integer, nil]
      attr_reader :ip

      # @!attribute [rw] value
      #
      # @return [Integer, nil]
      attr_reader :value

      # Creates an intermediate position write command.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param type [Symbol] IP write mode
      # @param ip [Integer, nil] IP slot
      # @param value [Integer, nil] IP value
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, type = :delete, ip = nil, value = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.type = type
        self.ip = ip
        self.value = value
      end

      # (see Message#parse)
      def parse(params)
        super
        self.type = TYPE.invert[to_number(params[0])]
        ip = to_number(params[1])
        ip = nil if ip.zero?
        self.ip = ip
        self.value = to_number(params[2..3])
      end

      def type=(value)
        unless TYPE.key?(value)
          raise ArgumentError,
                "type must be one of :delete, :current_position, :position_pulses, :position_percent, :distribute"
        end

        @type = value
      end

      def ip=(value)
        raise ArgumentError, "ip must be in range 1..16 or nil" unless value.nil? || (1..16).cover?(value)

        @ip = value
      end

      def value=(value)
        @value = value&.& 0xffff
      end

      # (see Message#params)
      def params
        transform_param(TYPE[type]) + transform_param(ip || 0) + from_number(value || 0, 2)
      end
    end

    # Command that modifies a motor's travel limits.
    class SetMotorLimits < Message
      # (see Ack::MSG)
      MSG = 0x11
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 4
      # Mapping from symbolic limit write modes to SDN parameter values.
      TYPE = { delete: 0x00, current_position: 0x01, specified_position: 0x02, jog_ms: 0x04, jog_pulses: 0x05 }.freeze
      # Mapping from symbolic limit targets to SDN parameter values.
      TARGET = { down: 0x00, up: 0x01 }.freeze

      # @!attribute [rw] type
      #
      # @return [:delete, :current_position, :specified_position, :jog_ms, :jog_pulses]
      attr_reader :type

      # @!attribute [rw] target
      #
      # @return [:up, :down]
      attr_reader :target

      # @!attribute [rw] value
      #
      # @return [Integer, nil]
      attr_reader :value

      # Creates a limit write command.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param type [:delete, :current_position, :specified_position, :jog_ms, :jog_pulses] limit write mode
      # @param target [:up, :down] target limit
      # @param value [Integer, nil]
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, type = :delete, target = :up, value = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.type = type
        self.target = target
        self.value = value
      end

      # (see Message#parse)
      def parse(params)
        super
        self.type = TYPE.invert[to_number(params[0])]
        self.target = TARGET.invert[to_number(params[1])]
        self.value = to_number(params[2..3])
      end

      def type=(value)
        unless TYPE.key?(value)
          raise ArgumentError,
                "type must be one of :delete, :current_position, :specified_position, :jog_ms, :jog_pulses"
        end

        @type = value
      end

      def target=(value)
        raise ArgumentError, "target must be one of :up, :down" unless TARGET.key?(value)

        @target = value
      end

      def value=(value)
        @value = value&.& 0xffff
      end

      # (see Message#params)
      def params
        param = value || 0
        param /= 10 if target == :jog_ms
        transform_param(TYPE[type]) + transform_param(TARGET[target]) + from_number(param, 2)
      end
    end

    # Command that updates a motor's rolling speeds.
    class SetMotorRollingSpeed < Message
      # (see Ack::MSG)
      MSG = 0x13
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 3

      # @!attribute [rw] up_speed
      #
      # @return [Integer, nil]
      attr_accessor :up_speed

      # @!attribute [rw] down_speed
      #
      # @return [Integer, nil]
      attr_accessor :down_speed

      # @!attribute [rw] slow_speed
      #
      # @return [Integer, nil]
      attr_accessor :slow_speed

      # Creates a rolling-speed write command.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param up_speed [Integer, nil] upward speed
      # @param down_speed [Integer, nil] downward speed
      # @param slow_speed [Integer, nil] slow speed
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, up_speed: nil, down_speed: nil, slow_speed: nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.up_speed = up_speed
        self.down_speed = down_speed
        self.slow_speed = slow_speed
      end

      # (see Message#parse)
      def parse(params)
        super
        self.up_speed = to_number(params[0])
        self.down_speed = to_number(params[1])
        self.slow_speed = to_number(params[2])
      end

      # (see Message#params)
      def params
        transform_param(up_speed || 0xff) + transform_param(down_speed || 0xff) + transform_param(slow_speed || 0xff)
      end
    end

    # Command that applies or clears the network lock state.
    class SetNetworkLock < Message
      # (see Ack::MSG)
      MSG = 0x16

      # @!attribute [rw] locked
      #
      # @return [true, false, nil]
      attr_accessor :locked

      # @!attribute [rw] priority
      #
      # @return [Integer, nil]
      attr_accessor :priority

      # (see Message#parse)
      def parse(params)
        self.locked = to_number(params[0]) == 1
        self.priority = to_number(params[1])
      end

      # (see Message#params)
      def params
        transform_param(locked ? 1 : 0) + transform_param(priority)
      end
    end

    # Command that writes a node's user-visible label.
    class SetNodeLabel < Message
      # (see Ack::MSG)
      MSG = 0x55
      # Maximum label length, in bytes
      MAX_LENGTH = 16

      # @!attribute [rw] label
      #
      # @return [String]
      attr_accessor :label

      # Creates a node label write command.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param label [String]
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, label = "", **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.label = label
      end

      # (see Message#parse)
      def parse(params)
        self.label = to_string(params)
      end

      # (see Message#params)
      def params
        from_string(label, self.class::MAX_LENGTH)
      end
    end
  end
end
