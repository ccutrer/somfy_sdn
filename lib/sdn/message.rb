require 'sdn/messages/helpers'

module SDN
  class MalformedMessage < RuntimeError; end

  class Message  
    class << self
      def readpartial(io, length, allow_empty: true)
        data = []
        while data.length < length
          begin
            data.concat(io.read_nonblock(length - data.length).bytes)
          rescue EOFError
            break
          rescue IO::WaitReadable
            break if allow_empty
            IO.select([io])
          end
        end
        data
      end

      def parse(io)
        io = StringIO.new(io) if io.is_a?(String)
        data = readpartial(io, 2, allow_empty: false)
        if data.length != 2
          # don't have enough data yet; buffer it
          io.ungetbyte(data.first) if data.length == 1
          raise MalformedMessage, "Could not get message type and length"
        end
        msg = to_number(data.first)
        length = to_number(data.last)
        ack_requested = length & 0x80 == 0x80
        length &= 0x7f
        if length < 11 || length > 32
          # only skip over one byte to try and re-sync
          io.ungetbyte(data.last)
          raise MalformedMessage, "Message has bogus length: #{length}"
        end
        data.concat(readpartial(io, length - 4))
        unless data.length == length - 2
          data.reverse.each { |byte| io.ungetbyte(byte) }
          raise MalformedMessage, "Missing data: got #{data.length} expected #{length}"
        end

        message_class = constants.find { |c| (const_get(c, false).const_get(:MSG, false) rescue nil) == msg }
        message_class = const_get(message_class, false) if message_class
        message_class ||= UnknownMessage

        bogus_checksums = [SetNodeLabel::MSG, PostNodeLabel::MSG].include?(msg)

        calculated_sum = checksum(data)
        read_sum = readpartial(io, 2)
        if read_sum.length == 0 || (!bogus_checksums && read_sum.length == 1)
          read_sum.each { |byte| io.ungetbyte(byte) }
          data.reverse.each { |byte| io.ungetbyte(byte) }
          raise MalformedMessage, "Missing data: got #{data.length} expected #{length}"
        end

        # check both the proper checksum, and a truncated checksum
        unless calculated_sum == read_sum || (bogus_checksums && calculated_sum.last == read_sum.first)
            raw_message = (data + read_sum).map { |b| '%02x' % b }.join(' ')
            # skip over single byte to try and re-sync
            data.shift
            read_sum.reverse.each { |byte| io.ungetbyte(byte) }
            data.reverse.each { |byte| io.ungetbyte(byte) }
            raise MalformedMessage, "Checksum mismatch for #{message_class.name}: #{raw_message}"
        end
        # the checksum was truncated; put back the unused byte
        io.ungetbyte(read_sum.last) if calculated_sum != read_sum && read_sum.length == 2

        puts "read #{(data + read_sum).map { |b| '%02x' % b }.join(' ')}"

        reserved = to_number(data[2])
        src = transform_param(data[3..5])
        dest = transform_param(data[6..8])
        result = message_class.new(reserved: reserved, ack_requested: ack_requested, src: src, dest: dest)
        result.parse(data[9..-1])
        result.msg = msg if message_class == UnknownMessage
        result
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
