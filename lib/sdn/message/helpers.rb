# frozen_string_literal: true

module SDN
  class Message
    # Shared conversions for SDN addresses, encoded parameters, strings, and checksums.
    module Helpers
      # Converts a printable SDN address into its byte representation.
      #
      # @param addr_string [String] address such as `01.02.03`
      #
      # @return [(Integer, Integer, Integer)] three-byte address
      def parse_address(addr_string)
        addr_string.match(/^(\h{2})[:.]?(\h{2})[:.]?(\h{2})$/).captures.map { |byte| byte.to_i(16) }
      end

      # Formats an address byte array using dotted hexadecimal notation.
      #
      # @param addr_bytes [(Integer, Integer, Integer)] address bytes
      #
      # @return [String]
      def print_address(addr_bytes)
        format("%02X.%02X.%02X", *addr_bytes)
      end

      # Checks whether an address is a group address.
      #
      # @param addr_bytes [(Integer, Integer, Integer)] address bytes
      #
      # @return [true, false]
      def group_address?(addr_bytes)
        addr_bytes[0..1] == [1, 1]
      end

      # Maps a numeric node type identifier to a symbolic name when known.
      #
      # @param number [Integer] protocol node type identifier
      #
      # @return [Symbol, Integer]
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

      # Maps a symbolic node type name to its numeric protocol identifier.
      #
      # @param type [Symbol, Integer] node type
      #
      # @return [Integer]
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

      # Formats a node type for inspection output.
      #
      # @param type [Symbol, Integer] node type
      #
      # @return [String]
      def node_type_to_string(type)
        type.is_a?(Integer) ? format("%02xh", type) : type.inspect
      end

      # Applies the SDN byte inversion and endianness transformation to a parameter value.
      #
      # @param param [Integer, <Integer>] parameter value
      #
      # @return [<Integer>]
      def transform_param(param)
        Array(param).reverse.map { |byte| 0xff - byte }
      end

      # Converts transformed SDN bytes into an integer.
      #
      # @param param [Integer, <Integer>] transformed bytes
      # @param nillable [true, false] whether all-`0xff` values should become `nil`
      #
      # @return [Integer, nil]
      def to_number(param, nillable: false)
        result = Array(param).reverse.inject(0) { |sum, byte| (sum << 8) + 0xff - byte }
        result = nil if nillable && result == (1 << (8 * Array(param).length)) - 1
        result
      end

      # Converts an integer into SDN-transformed bytes.
      #
      # @param number [Integer, nil] numeric value
      # @param bytes [Integer] number of bytes to emit
      #
      # @return [<Integer>]
      def from_number(number, bytes = 1)
        number ||= (1**(bytes * 8)) - 1
        number = number.to_i
        bytes.times.each_with_object([]) do |_, res|
          res << ((0xff - number) & 0xff)
          number >>= 8
        end
      end

      # Decodes transformed SDN bytes into a trimmed string.
      #
      # @param param [<Integer>] transformed string bytes
      #
      # @return [String]
      def to_string(param)
        chars = param.map { |b| 0xff - b }
        chars.pack("C*").sub(/\0+$/, "").strip
      end

      # Encodes a string into a fixed-width SDN byte array.
      #
      # @param string [String]
      # @param bytes [Integer] output width
      #
      # @return [<Integer>]
      def from_string(string, bytes)
        chars = string.bytes
        chars = chars[0...bytes].fill(" ".ord, chars.length, bytes - chars.length)
        chars.map { |b| 0xff - b }
      end

      # Computes the SDN checksum bytes for the provided payload.
      #
      # @param bytes [<Integer>]
      #
      # @return [(Integer, Integer)] two-byte checksum
      def checksum(bytes)
        result = bytes.sum
        [result >> 8, result & 0xff]
      end
    end
  end
end
