module SDN
  class Message
    module Helpers
      def parse_address(addr_string)
        addr_string.match(/^(\h{2})[:.]?(\h{2})[:.]?(\h{2})$/).captures.map { |byte| byte.to_i(16) }
      end

      def print_address(addr_bytes)
        "%02X.%02X.%02X" % addr_bytes
      end

      def is_group_address?(addr_bytes)
        addr_bytes[0..1] == [1, 1]
      end

      def transform_param(param)
        Array(param).reverse.map { |byte| 0xff - byte }
      end

      def to_number(param, nillable: false)
        result = Array(param).reverse.inject(0) { |sum, byte| (sum << 8) + 0xff - byte }
        result = nil if nillable && result == (1 << (8 * Array(param).length)) - 1
        result
      end

      def from_number(number, bytes)
        bytes.times.inject([]) do |res, _|
          res << (0xff - number & 0xff)
          number >>= 8
          res
        end
      end

      def to_string(param)
        chars = param.map { |b| 0xff - b }
        chars[0..-1].pack("C*").sub(/\0+$/, '')
      end

      def from_string(string, bytes)
        chars = string.bytes
        chars = chars[0...16].fill(0, chars.length, bytes - chars.length)
        chars.map { |b| 0xff - b }
      end

      def checksum(bytes)
        result = bytes.sum
        [result >> 8, result & 0xff]
      end
    end
  end
end
