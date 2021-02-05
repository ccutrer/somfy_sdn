module SDN
  class Message
    class PostMotorPosition < Message
      MSG = 0x0d
      PARAMS_LENGTH = 5

      attr_accessor :position_pulses, :position_percent, :ip

      def initialize(position_pulses = nil, position_percent = nil, ip = nil, **kwargs)
        super(**kwargs)
        self.position_pulses = position_pulses
        self.position_percent = position_percent
        self.ip = ip
      end

      def parse(params)
        super
        self.position_pulses = to_number(params[0..1], nillable: true)
        self.position_percent = to_number(params[2], nillable: true)
        self.ip = to_number(params[4], nillable: true)
      end

      def params
        from_number(position_pulses, 2) + from_number(position_percent) + from_number(ip)
      end
    end

    class PostMotorStatus < Message
      MSG = 0x0f
      PARAMS_LENGTH = 4
      STATE = { stopped: 0x00, running: 0x01, blocked: 0x02, locked: 0x03 }.freeze
      DIRECTION = { down: 0x00, up: 0x01 }.freeze
      SOURCE = { internal: 0x00, network: 0x01, dct: 0x02 }.freeze
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

      attr_accessor :state, :last_direction, :last_action_source, :last_action_cause

      def parse(params)
        super
        self.state = STATE.invert[to_number(params[0])]
        self.last_direction = DIRECTION.invert[to_number(params[1])]
        self.last_action_source = SOURCE.invert[to_number(params[2])]
        self.last_action_cause = CAUSE.invert[to_number(params[3])]
      end
    end

    class PostMotorLimits < Message
      MSG = 0x31
      PARAMS_LENGTH = 4

      attr_accessor :up_limit, :down_limit

      def initialize(up_limit = nil, down_limit = nil, **kwargs)
        super(**kwargs)
        self.up_limit = up_limit
        self.down_limit = down_limit
      end

      def parse(params)
        super
        self.up_limit = to_number(params[0..1], nillable: true)
        self.down_limit = to_number(params[2..3], nillable: true)
      end

      def params
        from_number(up_limit, 2) + from_number(down_limit, 2)
      end
    end

    class PostMotorDirection < Message
      MSG = 0x32
      PARAMS_LENGTH = 1
      DIRECTION = { standard: 0x00, reversed: 0x01 }.freeze

      attr_accessor :direction

      def parse(params)
        super
        self.direction = DIRECTION.invert[to_number(params[0])]
      end
    end

    class PostMotorRollingSpeed < Message
      MSG = 0x33
      PARAMS_LENGTH = 6

      attr_accessor :up_speed, :down_speed, :slow_speed

      def parse(params)
        super
        self.up_speed = to_number(params[0])
        self.down_speed = to_number(params[1])
        self.slow_speed = to_number(params[2])
        # 3 ignored params
      end
    end

    class PostMotorIP < Message
      MSG = 0x35
      PARAMS_LENGTH = 4

      attr_accessor :ip, :position_pulses, :position_percent

      def initialize(ip = nil, position_pulses = nil, position_percent = nil, **kwargs)
        super(**kwargs)
        self.ip = ip
        self.position_pulses = position_pulses
        self.position_percent = position_percent
      end

      def parse(params)
        super
        self.ip = to_number(params[0])
        self.position_pulses = to_number(params[1..2], nillable: true)
        self.position_percent = to_number(params[3], nillable: true)
      end

      def params
        from_number(ip) + from_number(position_pulses, 2) + from_number(position_percent)
      end
    end

    class PostNetworkLock < UnknownMessage
      MSG = 0x36
      PARAMS_LENGTH = 5

      def parse(params)
        super
      end
    end

    class PostNodeAddr < Message
      MSG = 0x60
      PARAMS_LENGTH = 0
    end

    class PostGroupAddr < Message
      MSG = 0x61
      PARAMS_LENGTH = 4

      def initialize(group_index = nil, group_address = nil, **kwargs)
        super(**kwargs)
        self.group_index = group_index
        self.group_address = group_address
      end

      attr_accessor :group_index, :group_address

      def parse(params)
        super
        self.group_index = to_number(params[0]) + 1
        self.group_address = transform_param(params[1..3])
        self.group_address = nil if group_address == [0, 0, 0] || group_address == [0x01, 0x01, 0xff]
      end

      def params
        from_number(group_index - 1) + transform_param(group_address || [0, 0, 0])
      end

      def class_inspect
        ", group_index=#{group_index.inspect}, group_address=#{group_address ? print_address(group_address) : 'nil'}"
      end
    end

    class PostNodeLabel < Message
      MSG = 0x65
      MAX_LENGTH = 16

      attr_accessor :label

      def initialize(label = nil, **kwargs)
        super(**kwargs)
        self.label = label
      end

      def parse(params)
        @label = to_string(params)
      end

      def params
        from_string(label, self.class::MAX_LENGTH)
      end
    end

    class PostNodeSerialNumber < Message
      MSG = 0x6c

      # format is NNNNNNMMYYWW
      # N = NodeID (address)
      # M = Manufacturer ID
      # Y = Year (last two digits)
      # W = Week
      attr_accessor :serial_number

      def parse(params)
        @serial_number = to_string(params)
      end
    end

    class PostNodeAppVersion < Message
      MSG = 0x75
      PARAMS_LENGTH = 6

      attr_accessor :reference, :index_letter, :index_number, :profile

      def parse(params)
        super
        self.reference = to_number(params[0..2])
        self.index_letter = to_string(params[3..3])
        self.index_number = transform_param(params[4])
        self.profile = transform_param(params[5])
      end
    end

    class PostNodeStackVersion < PostNodeAppVersion
      MSG = 0x71
    end
  end
end
