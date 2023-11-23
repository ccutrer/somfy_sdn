require 'sdn/message/helpers'

module SDN
  class MalformedMessage < RuntimeError; end

  class Message
    class << self
      def inherited(klass)
        return Message.inherited(klass) unless self == Message
        @message_map = nil
        (@subclasses ||= []) << klass
      end

      def expected_response?(message)
        if name =~ /::Get([A-Za-z]+)/
          message.class.name == name.sub("::Get", "::Post")
        else
          message.is_a?(Ack) || message.is_a?(Nack)
        end
      end

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
          result = message_class.new(node_type: node_type, ack_requested: ack_requested, src: src, dest: dest)
          result.parse(data.slice(offset + 9, length - 11))
          result.msg = msg if message_class == UnknownMessage
        rescue ArgumentError => e
          SDN.logger.warn "Discarding illegal message of type #{message_class.name}: #{e}"
          result = nil
        end
        [result, offset + length]
      end

      private

      def message_map
        @message_map ||=
          @subclasses.inject({}) do |memo, klass|
            next memo unless klass.constants(false).include?(:MSG)
            memo[klass.const_get(:MSG, false)] = klass
            memo
          end
      end
    end

    include Helpers
    singleton_class.include Helpers

    attr_accessor :node_type, :ack_requested, :src, :dest

    def initialize(node_type: nil, ack_requested: false, src: nil, dest: nil)
      @node_type = node_type || 0
      @ack_requested = ack_requested
      if src.nil? && !dest.nil? && is_group_address?(dest)
        src = dest
        dest = nil
      end
      @src = src || [0, 0, 1]
      @dest = dest || [0, 0, 0]
    end

    def parse(params)
      raise MalformedMessage, "unrecognized params for #{self.class.name}: #{params.map { |b| '%02x' % b }}" if self.class.const_defined?(:PARAMS_LENGTH) && params.length != self.class.const_get(:PARAMS_LENGTH)
    end

    def serialize
      result = transform_param(node_type_to_number(node_type)) + transform_param(src) + transform_param(dest) + params
      length = result.length + 4
      length |= 0x80 if ack_requested
      result = transform_param(self.class.const_get(:MSG)) + transform_param(length) + result
      result.concat(checksum(result))
      result.pack("C*")
    end

    def ==(other)
      self.serialize == other.serialize
    end

    def inspect
      "#<%s @node_type=%s, @ack_requested=%s, @src=%s, @dest=%s%s>" % [self.class.name, node_type_to_string(node_type), ack_requested, print_address(src), print_address(dest), class_inspect]
    end
    alias_method :to_s, :inspect

    def class_inspect
      ivars = instance_variables - [:@node_type, :@ack_requested, :@src, :@dest, :@params]
      return if ivars.empty?
      ivars.map { |iv| ", #{iv}=#{instance_variable_get(iv).inspect}" }.join
    end

    protected

    def params; []; end

    public

    class SimpleRequest < Message
      PARAMS_LENGTH = 0

      def initialize(dest = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
      end
    end

    class Nack < Message
      MSG = 0x6f
      PARAMS_LENGTH = 1
      VALUES = { data_error: 0x01,
                 unknown_message: 0x10,
                 node_is_locked: 0x20,
                 wrong_position: 0x21,
                 limits_not_set: 0x22,
                 ip_not_set: 0x23,
                 out_of_range: 0x24,
                 busy: 0xff }
                 # 17 limits not set?
                 # 37 not implemented? (get motor rolling speed)
                 # 39 at limit? blocked?


      # presumed
      attr_accessor :error_code

      def initialize(dest = nil, error_code = nil, **kwargs)
        kwargs[:dest] ||= dest
        super(**kwargs)
        self.error_code = error_code
      end

      def parse(params)
        super
        error_code = to_number(params[0])
        self.error_code = VALUES.invert[error_code] || error_code
      end
    end

    class Ack < SimpleRequest
      MSG = 0x7f
      PARAMS_LENGTH = 0
    end

    # messages after this point were decoded from UAI+ communication and may be named wrong
    class UnknownMessage < Message
      attr_accessor :msg, :params

      def initialize(params = [], **kwargs)
        super(**kwargs)
        self.params = params
      end

      alias parse params=

      def serialize
        # prevent serializing something we don't know
        raise NotImplementedError unless params
        super
      end

      def class_inspect
        result = if self.class == UnknownMessage
          result = ", @msg=%02xh" % msg 
        else
          super || ""
        end
        return result if params.empty?

        result << ", @params=#{params.map { |b| "%02x" % b }.join(' ')}"
      end
    end
  end
end

require 'sdn/message/control'
require 'sdn/message/get'
require 'sdn/message/post'
require 'sdn/message/set'
require 'sdn/message/ilt2/get'
require 'sdn/message/ilt2/master_control'
require 'sdn/message/ilt2/post'
require 'sdn/message/ilt2/set'
