# frozen_string_literal: true

module SDN
  class Message
    class Lock < Message
      MSG = 0x06
      PARAMS_LENGTH = 5
      TARGET_TYPE = { current: 0, up_limit: 1, down_limit: 2, ip: 4, unlock: 5, position_percent: 7 }.freeze

      attr_reader :target_type, :target, :priority

      def initialize(dest = nil, target_type = :unlock, target = nil, priority = 1, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.target_type = target_type
        self.target = target
        self.priority = priority
      end

      def target_type=(value)
        unless TARGET_TYPE.key?(value)
          raise ArgumentError,
                "target_type must be one of :current, :up_limit, :down_limit, :ip, :unlock, or :position_percent"
        end

        @target_type = value
      end

      def target=(value)
        @target = value&.& 0xffff
      end

      def priority=(value)
        @priority = value & 0xff
      end

      def parse(params)
        super
        self.target_type = TARGET_TYPE.invert[to_number(params[0])]
        target = to_number(params[1..2], nillable: true)
        self.target = target
        self.priority = to_number(params[3])
      end

      def params
        transform_param(TARGET_TYPE[target_type]) + from_number(target,
                                                                2) + transform_param(priority) + transform_param(0)
      end
    end

    # Move in momentary mode
    class Move < Message
      MSG = 0x01
      PARAMS_LENGTH = 3
      DIRECTION = { down: 0x00, up: 0x01, cancel: 0x02 }.freeze
      SPEED = { up: 0x00, down: 0x01, slow: 0x02 }.freeze

      attr_reader :direction, :duration, :speed

      def initialize(dest = nil, direction = :cancel, duration: nil, speed: :up, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.direction = direction
        self.duration = duration
        self.speed = speed
      end

      def parse(params)
        super
        self.direction = DIRECTION.invert[to_number(params[0])]
        duration = to_number(params[1])
        duration = nil if duration.zero?
        self.duration = duration
        self.speed = SPEED.invert[to_number(params[3])]
      end

      def direction=(value)
        unless DIRECTION.key?(value)
          raise ArgumentError,
                "direction must be one of :down, :up, or :cancel (#{value})"
        end

        @direction = value
      end

      def duration=(value)
        if value && (value < 0x0a || value > 0xff)
          raise ArgumentError,
                "duration must be in range 0x0a to 0xff (#{value})"
        end

        @duration = value
      end

      def speed=(value)
        raise ArgumentError, "speed must be one of :up, :down, or :slow (#{value})" unless SPEED.key?(value)

        @speed = speed
      end

      def params
        transform_param(DIRECTION[direction]) +
          transform_param(duration || 0) +
          transform_param(SPEED[speed])
      end
    end

    # Move relative to current position
    class MoveOf < Message
      MSG = 0x04
      PARAMS_LENGTH = 4
      TARGET_TYPE = { next_ip: 0x00,
                      previous_ip: 0x01,
                      jog_down_pulses: 0x02,
                      jog_up_pulses: 0x03,
                      jog_down_ms: 0x04,
                      jog_up_ms: 0x05 }.freeze

      attr_reader :target_type, :target

      def initialize(dest = nil, target_type = nil, target = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.target_type = target_type
        self.target = target
      end

      def parse(params)
        super
        self.target_type = TARGET_TYPE.invert[to_number(params[0])]
        target = to_number(params[1..2], nillable: true)
        target *= 10 if %I[jog_down_ms jog_up_ms].include?(target_type)
        self.target = target
      end

      def target_type=(value)
        unless value.nil? || TARGET_TYPE.key?(value)
          raise ArgumentError, "target_type must be one of :next_ip, :previous_ip, " \
                               ":jog_down_pulses, :jog_up_pulses, :jog_down_ms, :jog_up_ms"
        end

        @target_type = value
      end

      def target=(value)
        value &= 0xffff if value
        @target = value
      end

      def params
        param = target || 0xffff
        param /= 10 if %I[jog_down_ms jog_up_ms].include?(target_type)
        transform_param(TARGET_TYPE[target_type]) + from_number(param, 2) + transform_param(0)
      end
    end

    # Move to absolute position
    class MoveTo < Message
      MSG = 0x03
      PARAMS_LENGTH = 4
      TARGET_TYPE = { down_limit: 0x00, up_limit: 0x01, ip: 0x02, position_pulses: 0x03, position_percent: 0x04 }.freeze
      SPEED = { up: 0x00, down: 0x01, slow: 0x02 }.freeze

      attr_reader :target_type, :target, :speed

      def initialize(dest = nil, target_type = :down_limit, target = nil, speed = :up, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.target_type = target_type
        self.target = target
        self.speed = speed
      end

      def parse(params)
        super
        self.target_type = TARGET_TYPE.invert[to_number(params[0])]
        self.target = to_number(params[1..2], nillable: true)
        self.speed = SPEED.invert[to_number(params[3])]
      end

      def target_type=(value)
        unless TARGET_TYPE.key?(value)
          raise ArgumentError,
                "target_type must be one of :down_limit, :up_limit, :ip, :position_pulses, or :position_percent"
        end

        @target_type = value
      end

      def target=(value)
        value &= 0xffff if value
        @target = value
      end

      def speed=(value)
        raise ArgumentError, "speed must be one of :up, :down, or :slow" unless SPEED.key?(value)

        @speed = value
      end

      def params
        transform_param(TARGET_TYPE[target_type]) + from_number(target || 0xffff, 2) + transform_param(SPEED[speed])
      end
    end

    # Stop movement
    class Stop < Message
      MSG = 0x02
      PARAMS_LENGTH = 1

      def initialize(dest = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
      end

      def params
        transform_param(0)
      end
    end

    class Wink < SimpleRequest
      MSG = 0x05
    end
  end
end
