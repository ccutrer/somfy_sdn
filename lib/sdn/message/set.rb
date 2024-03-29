# frozen_string_literal: true

module SDN
  class Message
    class SetFactoryDefault < Message
      MSG = 0x1f
      PARAMS_LENGTH = 1
      RESET = { all_settings: 0x00,
                group_addresses: 0x01,
                limits: 0x11,
                rotation: 0x12,
                rolling_speed: 0x13,
                ips: 0x15,
                locks: 0x17 }.freeze

      attr_reader :reset

      def initialize(dest = nil, reset = :all_settings, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.reset = reset
      end

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

      def params
        transform_param(RESET[reset])
      end
    end

    class SetGroupAddr < Message
      MSG = 0x51
      PARAMS_LENGTH = 4

      attr_accessor :group_address
      attr_reader :group_index

      def initialize(dest = nil, group_index = 1, group_address = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.group_index = group_index
        self.group_address = group_address
      end

      def parse(params)
        super
        self.group_index = to_number(params[0]) + 1
        self.group_address = transform_param(params[1..3])
      end

      def group_index=(value)
        raise ArgumentError, "group_index is out of range" unless (1..16).cover?(value)

        @group_index = value
      end

      def params
        transform_param(group_index - 1) + transform_param(group_address || [0, 0, 0])
      end

      def class_inspect
        ", group_index=#{group_index.inspect}, group_address=#{group_address ? print_address(group_address) : "nil"}"
      end
    end

    class SetMotorDirection < Message
      MSG = 0x12
      PARAMS_LENGTH = 1
      DIRECTION = { standard: 0x00, reversed: 0x01 }.freeze

      attr_reader :direction

      def initialize(dest = nil, direction = :standard, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.direction = direction
      end

      def parse(params)
        super
        self.direction = DIRECTION.invert[to_number(params[0])]
      end

      def direction=(value)
        raise ArgumentError, "direction must be one of :standard, :reversed" unless DIRECTION.key?(value)

        @direction = value
      end

      def params
        transform_param(DIRECTION[direction])
      end
    end

    class SetMotorIP < Message
      MSG = 0x15
      PARAMS_LENGTH = 4
      # for distribute, value is how many IPs to distribute over
      TYPE = { delete: 0x00,
               current_position: 0x01,
               position_pulses: 0x02,
               position_percent: 0x03,
               distribute: 0x04 }.freeze

      attr_reader :type, :ip, :value

      def initialize(dest = nil, type = :delete, ip = nil, value = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.type = type
        self.ip = ip
        self.value = value
      end

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
        raise ArgumentError, "ip must be in range 1..16 or nil" unless ip.nil? || (1..16).cover?(ip)

        @ip = value
      end

      def value=(value)
        @value = value&.& 0xffff
      end

      def params
        transform_param(TYPE[type]) + transform_param(ip || 0) + from_number(value || 0, 2)
      end
    end

    class SetMotorLimits < Message
      MSG = 0x11
      PARAMS_LENGTH = 4
      TYPE = { delete: 0x00, current_position: 0x01, specified_position: 0x02, jog_ms: 0x04, jog_pulses: 0x05 }.freeze
      TARGET = { down: 0x00, up: 0x01 }.freeze

      attr_reader :type, :target, :value

      def initialize(dest = nil, type = :delete, target = :up, value = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.type = type
        self.target = target
        self.value = value
      end

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

      def params
        param = value || 0
        param /= 10 if target == :jog_ms
        transform_param(TYPE[type]) + transform_param(TARGET[target]) + from_number(param, 2)
      end
    end

    class SetMotorRollingSpeed < Message
      MSG = 0x13
      PARAMS_LENGTH = 3

      attr_accessor :up_speed, :down_speed, :slow_speed

      def initialize(dest = nil, up_speed: nil, down_speed: nil, slow_speed: nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.up_speed = up_speed
        self.down_speed = down_speed
        self.slow_speed = slow_speed
      end

      def parse(params)
        super
        self.up_speed = to_number(params[0])
        self.down_speed = to_number(params[1])
        self.slow_speed = to_number(params[2])
      end

      def params
        transform_param(up_speed || 0xff) + transform_param(down_speed || 0xff) + transform_param(slow_speed || 0xff)
      end
    end

    class SetNetworkLock < Message
      MSG = 0x16

      attr_accessor :locked, :priority

      def parse(params)
        self.locked = to_number(params[0]) == 1
        self.priority = to_number(params[1])
      end

      def params
        transform_param(locked ? 1 : 0) + transform_param(priority)
      end
    end

    class SetNodeLabel < Message
      MSG = 0x55
      MAX_LENGTH = 16

      attr_accessor :label

      def initialize(dest = nil, label = "", **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.label = label
      end

      def parse(params)
        self.label = to_string(params)
      end

      def params
        from_string(label, self.class::MAX_LENGTH)
      end
    end
  end
end
