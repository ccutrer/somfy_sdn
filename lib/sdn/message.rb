# frozen_string_literal: true

require "sdn/message/helpers"

module SDN
  # Raised when a parsed frame is structurally valid but its payload does not match the target message type.
  class MalformedMessage < RuntimeError; end

  # Base type for all SDN protocol frames and message-specific serializers/parsers.
  class Message
    class << self
      # @!visibility private
      def inherited(klass)
        super
        return Message.inherited(klass) unless self == Message

        @message_map = nil
        (@subclasses ||= []) << klass
      end

      # Determines whether a received message satisfies the expected response for this request type.
      #
      # @param message [SDN::Message] received message candidate
      #
      # @return [true, false]
      def expected_response?(message)
        if /::Get([A-Za-z]+)/.match?(name)
          message.class.name == name.sub("::Get", "::Post") # rubocop:disable Style/ClassEqualityComparison
        else
          message.is_a?(Ack) || message.is_a?(Nack)
        end
      end

      # Attempts to parse the first valid SDN message from a byte stream.
      #
      # @param data [<Integer>] raw bytes buffered from the transport
      #
      # @return [(SDN::Message, Integer)] parsed message and consumed byte count
      def parse(data)
        offset = -1
        msg = length = ack_requested = message_class = nil
        # we loop here scanning for a valid message
        loop do
          offset += 1
          # give these weird messages a chance
          result = ILT2::MasterControl.parse(data)
          return result if result

          return [nil, 0] if data.length - offset < 11

          msg = to_number(data[offset])
          length = to_number(data[offset + 1])
          ack_requested = length & 0x80 == 0x80
          length &= 0x7f
          # impossible message
          next if length < 11 || length > 43
          # don't have enough data for what this message wants;
          # it could be garbage on the line so keep scanning
          next if length > data.length - offset

          message_class = message_map[msg] || UnknownMessage

          calculated_sum = checksum(data.slice(offset, length - 2))
          read_sum = data.slice(offset + length - 2, 2)
          next unless read_sum == calculated_sum

          break
        end

        node_type = node_type_from_number(to_number(data[offset + 2]))
        src = transform_param(data.slice(offset + 3, 3))
        dest = transform_param(data.slice(offset + 6, 3))
        begin
          result = message_class.new(node_type:, ack_requested:, src:, dest:)
          result.parse(data.slice(offset + 9, length - 11))
          result.msg = msg if message_class == UnknownMessage
        rescue ArgumentError => e
          SDN.logger.warn "Discarding illegal message of type #{message_class.name}: #{e}"
          result = nil
        end
        [result, offset + length]
      end

      private

      # Builds a lookup table from protocol opcode to message class.
      #
      # @return [{Integer => Class}]
      def message_map
        @message_map ||=
          @subclasses.each_with_object({}) do |klass, memo|
            next memo unless klass.const_defined?(:MSG, false)

            memo[klass.const_get(:MSG, false)] = klass
          end
      end
    end

    include Helpers
    singleton_class.include Helpers

    # Message sender node type.
    #
    # @return [Symbol, Integer]
    attr_accessor :node_type

    # Whether this message requests an acknowledgement.
    #
    # @return [true, false]
    attr_accessor :ack_requested

    # Source address for the message.
    #
    # @return [(Integer, Integer, Integer)]
    attr_accessor :src

    # Destination address for the message.
    #
    # @return [(Integer, Integer, Integer)]
    attr_accessor :dest

    # Builds a message envelope with optional addressing and acknowledgement behavior.
    #
    # @param node_type [Symbol, Integer, nil] originating node type
    # @param ack_requested [true, false] whether the receiver should acknowledge the message
    # @param src [(Integer, Integer, Integer), nil] source address bytes
    # @param dest [(Integer, Integer, Integer), nil] destination address bytes
    def initialize(node_type: nil, ack_requested: false, src: nil, dest: nil)
      @node_type = node_type || 0
      @ack_requested = ack_requested
      if src.nil? && !dest.nil? && group_address?(dest)
        src = dest
        dest = nil
      end
      @src = src || [0, 0, 1]
      @dest = dest || [0, 0, 0]
    end

    # Parses protocol-specific parameter bytes into this message instance.
    #
    # @param params [<Integer>] raw parameter bytes
    #
    # @return [void]
    #
    # @raise [SDN::MalformedMessage] when the parameter payload length is invalid
    def parse(params)
      return unless self.class.const_defined?(:PARAMS_LENGTH) && params.length != self.class.const_get(:PARAMS_LENGTH)

      raise MalformedMessage, "unrecognized params for #{self.class.name}: #{params.map do |b|
                                                                               format("%02x", b)
                                                                             end}"
    end

    # Serializes the message to a packed SDN frame.
    #
    # @return [String] binary protocol frame
    def serialize
      result = transform_param(node_type_to_number(node_type)) + transform_param(src) + transform_param(dest) + params
      length = result.length + 4
      length |= 0x80 if ack_requested
      result = transform_param(self.class.const_get(:MSG)) + transform_param(length) + result
      result.concat(checksum(result))
      result.pack("C*")
    end

    # @return [true, false]
    def ==(other)
      serialize == other.serialize
    end

    # @return [String]
    def inspect
      format("#<%s @node_type=%s, @ack_requested=%s, @src=%s, @dest=%s%s>",
             self.class.name,
             node_type_to_string(node_type),
             ack_requested,
             print_address(src),
             print_address(dest),
             class_inspect)
    end
    alias_method :to_s, :inspect

    private

    # Returns the protocol-specific portion of the inspection string.
    #
    # @return [String, nil]
    def class_inspect
      ivars = instance_variables - %i[@node_type @ack_requested @src @dest @params]
      return if ivars.empty?

      ivars.map { |iv| ", #{iv}=#{instance_variable_get(iv).inspect}" }.join
    end

    protected

    # Returns the protocol-specific payload bytes for this message.
    #
    # @return [<Integer>]
    def params
      []
    end

    # Base class for request messages with no protocol-specific parameters.
    class SimpleRequest < Message
      # Number of protocol parameter bytes expected
      PARAMS_LENGTH = 0

      # Creates a simple request whose only payload is the destination address.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
      end
    end

    # Positive acknowledgement response for commands that requested one.
    class Ack < SimpleRequest
      # Protocol message number
      MSG = 0x7f
      # (see SimpleRequest::PARAMS_LENGTH)
      PARAMS_LENGTH = 0
    end

    # Negative acknowledgement response emitted when a request cannot be fulfilled.
    class Nack < Message
      # (see Ack::MSG)
      MSG = 0x6f
      # (see Ack::PARAMS_LENGTH)
      PARAMS_LENGTH = 1
      # Mapping from symbolic error names to SDN error codes.
      VALUES = { data_error: 0x01,
                 unknown_message: 0x10,
                 node_is_locked: 0x20,
                 wrong_position: 0x21,
                 limits_not_set: 0x22,
                 ip_not_set: 0x23,
                 out_of_range: 0x24,
                 busy: 0xff }.freeze
      # 17 limits not set?
      # 37 not implemented? (get motor rolling speed)
      # 39 at limit? blocked?

      # Parsed NACK error code as a symbolic name or raw integer.
      #
      # @return [Symbol, Integer, nil]
      attr_accessor :error_code

      # Creates a negative acknowledgement message.
      #
      # @param dest [(Integer, Integer, Integer), nil] destination address
      # @param error_code [Symbol, Integer, nil] protocol error code
      # @param kwargs [Hash] additional message options
      def initialize(dest = nil, error_code = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.error_code = error_code
      end

      # Parses the negative acknowledgement error code.
      #
      # @param params [<Integer>] raw parameter bytes
      def parse(params)
        super
        error_code = to_number(params[0])
        self.error_code = VALUES.invert[error_code] || error_code
      end
    end

    # Fallback wrapper for frames whose opcode is unknown to the library.
    #
    # Messages after this point were decoded from UAI+ communication and may be named wrong.
    class UnknownMessage < Message
      # Unknown protocol opcode captured for this message.
      #
      # @return [Integer, nil]
      attr_accessor :msg

      # Raw undecoded parameter bytes for this message.
      #
      # @return [<Integer>, nil]
      attr_accessor :params

      # Creates a message wrapper for an unrecognized protocol opcode.
      #
      # @param params [<Integer>] raw unparsed parameter bytes
      def initialize(params = [], **)
        super(**)
        self.params = params
      end

      alias_method :parse, :params=

      # Serializes an unknown message only when raw parameters are present.
      #
      # @return [String] binary protocol frame
      #
      # @raise [NotImplementedError] when parameters are unavailable
      def serialize
        # prevent serializing something we don't know
        raise NotImplementedError unless params

        super
      end

      # (see Message#class_inspect)
      def class_inspect
        result = if instance_of?(UnknownMessage)
                   format(", @msg=%02xh", msg)
                 else
                   super || ""
                 end
        return result if params.empty?

        result << ", @params=#{params.map { |b| format("%02x", b) }.join(" ")}"
      end
    end
  end
end

require "sdn/message/control"
require "sdn/message/get"
require "sdn/message/post"
require "sdn/message/set"
require "sdn/message/ilt2/get"
require "sdn/message/ilt2/master_control"
require "sdn/message/ilt2/post"
require "sdn/message/ilt2/set"
