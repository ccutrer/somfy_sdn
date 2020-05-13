require 'sdn/messages/helpers'

module SDN
  class MalformedMessage < RuntimeError; end

  class Message  
    class << self
      def parse(data)
        offset = -1
        msg = length = ack_requested = message_class = nil
        # we loop here scanning for a valid message
        loop do
          offset += 1
          return nil if data.length - offset < 11
          msg = to_number(data[offset])
          length = to_number(data[offset + 1])
          ack_requested = length & 0x80 == 0x80
          length &= 0x7f
          # impossible message
          next if length < 11 || length > 32
          # don't have enough data for what this message wants;
          # it could be garbage on the line so keep scanning
          next if length > data.length - offset

          message_class = constants.find { |c| (const_get(c, false).const_get(:MSG, false) rescue nil) == msg }
          message_class = const_get(message_class, false) if message_class
          message_class ||= UnknownMessage

          calculated_sum = checksum(data.slice(offset, length - 2))
          read_sum = data.slice(offset + length - 2, 2)
          next unless read_sum == calculated_sum

          break
        end

        puts "discarding invalid data prior to message #{data[0...offset].map { |b| '%02x' % b }.join(' ')}" unless offset == 0
        puts "read #{data.slice(offset, length).map { |b| '%02x' % b }.join(' ')}"

        reserved = to_number(data[offset + 2])
        src = transform_param(data.slice(offset + 3, 3))
        dest = transform_param(data.slice(offset + 6, 3))
        result = message_class.new(reserved: reserved, ack_requested: ack_requested, src: src, dest: dest)
        result.parse(data.slice(offset + 9, length - 11))
        result.msg = msg if message_class == UnknownMessage
        [result, offset + length]
      end
    end

    include Helpers
    singleton_class.include Helpers

    attr_reader :reserved, :ack_requested, :src, :dest

    def initialize(reserved: nil, ack_requested: false, src: nil, dest: nil)
      @reserved = reserved || 0x02 # message sent to Sonesse 30
      @ack_requested = ack_requested
      if src.nil? && is_group_address?(dest)
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
      result = transform_param(reserved) + transform_param(src) + transform_param(dest) + params
      length = result.length + 4
      length |= 0x80 if ack_requested
      result = transform_param(self.class.const_get(:MSG)) + transform_param(length) + result
      result.concat(checksum(result))
      puts "wrote #{result.map { |b| '%02x' % b }.join(' ')}"
      result.pack("C*")
    end

    def inspect
      "#<%s @reserved=%02xh, @ack_requested=%s, @src=%s, @dest=%s%s>" % [self.class.name, reserved, ack_requested, print_address(src), print_address(dest), class_inspect]
    end

    def class_inspect
      ivars = instance_variables - [:@reserved, :@ack_requested, :@src, :@dest]
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
      VALUES = { data_error: 0x01, unknown_message: 0x10, node_is_locked: 0x20, wrong_position: 0x21, limits_not_set: 0x22, ip_not_set: 0x23, out_of_range: 0x24, busy: 0xff }

      # presumed
      attr_accessor :error_code

      def parse(params)
        super
        error_code = to_number(params[0])
        self.error_code = VALUES[error_code] || error_code
      end
    end

    class Ack < Message
      MSG = 0x7f
      PARAMS_LENGTH = 0
    end

    # messages after this point were decoded from UAI+ communication and may be named wrong
    class UnknownMessage < Message
      attr_accessor :msg, :params

      alias parse params=

      def class_inspect
        result = ", @msg=%02xh" % msg
        return result if params.empty?

        result << ", @params=#{params.map { |b| "%02x" % b }.join(' ')}"
      end
    end
  end
end

require 'sdn/messages/control'
require 'sdn/messages/get'
require 'sdn/messages/post'
require 'sdn/messages/set'
