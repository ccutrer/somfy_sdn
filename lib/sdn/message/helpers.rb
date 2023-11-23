# frozen_string_literal: true

module SDN
  class Message
    module Helpers
      def parse_address(addr_string)
        addr_string.match(/^(\h{2})[:.]?(\h{2})[:.]?(\h{2})$/).captures.map { |byte| byte.to_i(16) }
      end

      def print_address(addr_bytes)
        format("%02X.%02X.%02X", *addr_bytes)
      end

      def group_address?(addr_bytes)
        addr_bytes[0..1] == [1, 1]
      end

      def node_type_from_number(number)
        case number
        when 1 then :st50ilt2
        when 2 then :st30
        when 6 then :glydea
        when 7 then :st50ac
        when 8 then :st50dc
        when 0x70 then :lt50
        else; number
        end
      end

      def node_type_to_number(type)
        case type
        when :st50ilt2 then 1
        when :st30 then 2
        when :glydea then 6
        when :st50ac then 7
        when :st50dc then 8
        when :lt50 then 0x70
        else; type
        end
      end

      def node_type_to_string(type)
        type.is_a?(Integer) ? format("%02xh", type) : type.inspect
      end

      def transform_param(param)
        Array(param).reverse.map { |byte| 0xff - byte }
      end

      def to_number(param, nillable: false)
        result = Array(param).reverse.inject(0) { |sum, byte| (sum << 8) + 0xff - byte }
        result = nil if nillable && result == (1 << (8 * Array(param).length)) - 1
        result
      end

      def from_number(number, bytes = 1)
        number ||= (1**(bytes * 8)) - 1
        number = number.to_i
        bytes.times.each_with_object([]) do |_, res|
          res << ((0xff - number) & 0xff)
          number >>= 8
        end
      end

      def to_string(param)
        chars = param.map { |b| 0xff - b }
        chars.pack("C*").sub(/\0+$/, "").strip
      end

      def from_string(string, bytes)
        chars = string.bytes
        chars = chars[0...bytes].fill(" ".ord, chars.length, bytes - chars.length)
        chars.map { |b| 0xff - b }
      end

      def checksum(bytes)
        result = bytes.sum
        [result >> 8, result & 0xff]
      end
    end
  end
end
