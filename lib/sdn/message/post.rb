# frozen_string_literal: true

module SDN
  class Message
    # Response carrying a motor's group address for a specific slot.
    class PostGroupAddr < Message
      # (see Ack::MSG)
      MSG = 0x61
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 4

      # Creates a group address response message.
      #
      # @param group_index [Integer, nil] group slot number
      # @param group_address [(Integer, Integer, Integer), nil] group address bytes
      def initialize(group_index = nil, group_address = nil, **)
        super(**)
        self.group_index = group_index
        self.group_address = group_address
      end

      # Reported group slot number.
      #
      # @return [Integer, nil]
      attr_accessor :group_index

      # Reported group address for the slot.
      #
      # @return [(Integer, Integer, Integer), nil]
      attr_accessor :group_address

      # (see Message#parse)
      def parse(params)
        super
        self.group_index = to_number(params[0]) + 1
        self.group_address = transform_param(params[1..3])
        self.group_address = nil if [[0, 0, 0], [0x01, 0x01, 0xff]].include?(group_address)
      end

      # (see Message#params)
      def params
        from_number(group_index - 1) + transform_param(group_address || [0, 0, 0])
      end

      # (see Message#class_inspect)
      def class_inspect
        ", group_index=#{group_index.inspect}, group_address=#{group_address ? print_address(group_address) : "nil"}"
      end
    end

    # Response carrying a motor's configured rotation direction.
    class PostMotorDirection < Message
      # (see Ack::MSG)
      MSG = 0x32
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 1
      # Mapping from symbolic direction names to SDN parameter values.
      DIRECTION = { standard: 0x00, reversed: 0x01 }.freeze

      # Reported motor rotation direction.
      #
      # @return [:standard, :reversed, nil]
      attr_accessor :direction

      # (see Message#parse)
      def parse(params)
        super
        self.direction = DIRECTION.invert[to_number(params[0])]
      end
    end

    # Response carrying a stored intermediate position value.
    class PostMotorIP < Message
      # (see Ack::MSG)
      MSG = 0x35
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 4

      # Reported intermediate position slot.
      #
      # @return [Integer, nil]
      attr_accessor :ip

      # @return [Integer, nil]
      attr_accessor :position_pulses

      # @return [Integer, nil]
      attr_accessor :position_percent

      # Creates a motor IP response message.
      #
      # @param ip [Integer, nil] intermediate position slot
      # @param position_pulses [Integer, nil] stored pulse value
      # @param position_percent [Integer, nil] stored percentage value
      def initialize(ip = nil, position_pulses = nil, position_percent = nil, **)
        super(**)
        self.ip = ip
        self.position_pulses = position_pulses
        self.position_percent = position_percent
      end

      # (see Message#parse)
      def parse(params)
        super
        self.ip = to_number(params[0])
        self.position_pulses = to_number(params[1..2], nillable: true)
        self.position_percent = to_number(params[3], nillable: true)
      end

      # (see Message#params)
      def params
        from_number(ip) + from_number(position_pulses, 2) + from_number(position_percent)
      end
    end

    # Response carrying a motor's upper and lower travel limits.
    class PostMotorLimits < Message
      # (see Ack::MSG)
      MSG = 0x31
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 4

      # @return [Integer, nil]
      attr_accessor :up_limit

      # @return [Integer, nil]
      attr_accessor :down_limit

      # Creates a motor limits response message.
      #
      # @param up_limit [Integer, nil] upper limit in pulses
      # @param down_limit [Integer, nil] lower limit in pulses
      def initialize(up_limit = nil, down_limit = nil, **)
        super(**)
        self.up_limit = up_limit
        self.down_limit = down_limit
      end

      # (see Message#parse)
      def parse(params)
        super
        self.up_limit = to_number(params[0..1], nillable: true)
        self.down_limit = to_number(params[2..3], nillable: true)
      end

      # (see Message#params)
      def params
        from_number(up_limit, 2) + from_number(down_limit, 2)
      end
    end

    # Response carrying a motor's current position and active intermediate position.
    class PostMotorPosition < Message
      # (see Ack::MSG)
      MSG = 0x0d
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 5

      # @return [Integer, nil]
      attr_accessor :position_pulses

      # @return [Integer, nil]
      attr_accessor :position_percent

      # Reported active intermediate position slot.
      #
      # @return [Integer, nil]
      attr_accessor :ip

      # Creates a motor position response message.
      #
      # @param position_pulses [Integer, nil] current position in pulses
      # @param position_percent [Integer, nil] current position in percent
      # @param ip [Integer, nil] active intermediate position slot
      def initialize(position_pulses = nil, position_percent = nil, ip = nil, **)
        super(**)
        self.position_pulses = position_pulses
        self.position_percent = position_percent
        self.ip = ip
      end

      # (see Message#parse)
      def parse(params)
        super
        self.position_pulses = to_number(params[0..1], nillable: true)
        self.position_percent = to_number(params[2], nillable: true)
        self.ip = to_number(params[4], nillable: true)
      end

      # (see Message#params)
      def params
        from_number(position_pulses, 2) + from_number(position_percent) + from_number(ip)
      end
    end

    # Response carrying a motor's rolling speed configuration.
    class PostMotorRollingSpeed < Message
      # (see Ack::MSG)
      MSG = 0x33
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 6

      # @return [Integer, nil]
      attr_accessor :up_speed

      # @return [Integer, nil]
      attr_accessor :down_speed

      # @return [Integer, nil]
      attr_accessor :slow_speed

      # (see Message#parse)
      def parse(params)
        super
        self.up_speed = to_number(params[0])
        self.down_speed = to_number(params[1])
        self.slow_speed = to_number(params[2])
        # 3 ignored params
      end
    end

    # Response carrying a motor's movement state and last-action metadata.
    class PostMotorStatus < Message
      # (see Ack::MSG)
      MSG = 0x0f
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 4
      # Mapping from symbolic motor states to SDN parameter values.
      STATE = { stopped: 0x00, running: 0x01, blocked: 0x02, locked: 0x03 }.freeze
      # Mapping from symbolic directions to SDN parameter values.
      DIRECTION = { down: 0x00, up: 0x01 }.freeze
      # Mapping from symbolic action sources to SDN parameter values.
      SOURCE = { internal: 0x00, network: 0x01, dct: 0x02 }.freeze
      # Mapping from symbolic action causes to SDN parameter values.
      CAUSE = { target_reached: 0x00,
                explicit_command: 0x01,
                wink: 0x02,
                limits_not_set: 0x10,
                ip_not_set: 0x11,
                polarity_not_checked: 0x12,
                in_configuration_mode: 0x13,
                obstacle_detection: 0x20,
                over_current_protection: 0x21,
                thermal_protection: 0x22 }.freeze

      # Reported current motor state.
      #
      # @return [:stopped, :running, :blocked, :locked, nil]
      attr_accessor :state

      # Reported direction of the last movement.
      #
      # @return [:down, :up, nil]
      attr_accessor :last_direction

      # Reported source of the last action.
      #
      # @return [:internal, :network, :dct, nil]
      attr_accessor :last_action_source

      # Reported cause of the last action.
      #
      # @return [:target_reached,
      #    :explicit_command,
      #    :wink,
      #    :limits_not_set,
      #    :ip_not_set,
      #    :polarity_not_checked,
      #    :in_configuration_mode,
      #    :obstacle_detection,
      #    :over_current_protection,
      #    :thermal_protection,
      #    nil]
      attr_accessor :last_action_cause

      # (see Message#parse)
      def parse(params)
        super
        self.state = STATE.invert[to_number(params[0])]
        self.last_direction = DIRECTION.invert[to_number(params[1])]
        self.last_action_source = SOURCE.invert[to_number(params[2])]
        self.last_action_cause = CAUSE.invert[to_number(params[3])]
      end
    end

    # Response carrying the network lock payload in an undecoded form.
    class PostNetworkLock < UnknownMessage
      # (see Ack::MSG)
      MSG = 0x36
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 5
    end

    # Response used during node address discovery.
    class PostNodeAddr < Message
      # (see Ack::MSG)
      MSG = 0x60
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 0
    end

    # Response carrying a node's application version details.
    class PostNodeAppVersion < Message
      # (see Ack::MSG)
      MSG = 0x75
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 6

      # @return [Integer, nil]
      attr_accessor :reference

      # @return [String, nil]
      attr_accessor :index_letter

      # @return [Integer, <Integer>, nil]
      attr_accessor :index_number

      # @return [Integer, <Integer>, nil]
      attr_accessor :profile

      # (see Message#parse)
      def parse(params)
        super
        self.reference = to_number(params[0..2])
        self.index_letter = to_string(params[3..3])
        self.index_number = transform_param(params[4])
        self.profile = transform_param(params[5])
      end
    end

    # Response carrying a node's configured label.
    class PostNodeLabel < Message
      # (see Ack::MSG)
      MSG = 0x65
      # Maximum label length, in bytes
      MAX_LENGTH = 16

      # @return [String, nil]
      attr_accessor :label

      # Creates a node label response message.
      #
      # @param label [String, nil] node label
      def initialize(label = nil, **)
        super(**)
        self.label = label
      end

      # (see Message#parse)
      def parse(params)
        @label = to_string(params)
      end

      # (see Message#params)
      def params
        from_string(label, self.class::MAX_LENGTH)
      end
    end

    # Response carrying a node's serial number string.
    class PostNodeSerialNumber < Message
      # (see Ack::MSG)
      MSG = 0x6c

      # format is NNNNNNMMYYWW
      # N = NodeID (address)
      # M = Manufacturer ID
      # Y = Year (last two digits)
      # W = Week
      # Reported node serial number string.
      #
      # @return [String, nil]
      attr_accessor :serial_number

      # (see Message#parse)
      def parse(params)
        @serial_number = to_string(params)
      end
    end

    # Response carrying a node's protocol stack version details.
    class PostNodeStackVersion < PostNodeAppVersion
      # (see Ack::MSG)
      MSG = 0x71
    end
  end
end
