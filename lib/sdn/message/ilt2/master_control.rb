# frozen_string_literal: true

module SDN
  class Message
    module ILT2
      # Special five-byte ILT2 master-control frame parser.
      class MasterControl
        class << self
          include Helpers

          # Parses a five-byte ILT2 master control frame when present.
          #
          # @param data [<Integer>] buffered input bytes
          #
          # @return [(SDN::Message::ILT2::MasterControl, Integer), nil]
          # (see Message#parse)
          def parse(data)
            return unless data.length >= 5
            return unless checksum(data[0..2]) == data[3..4]
            # no clue what's special about these
            return unless data[0..1] == [0xfa, 0x7a]

            klass = case data[2]
                    when 0x00 then Down
                    when 0xfa then Up
                    when 0xff then Stop
                    end
            return unless klass

            [klass.new, 5]
          end
        end

        # Master-control frame representing a down command.
        class Down < MasterControl
        end

        # Master-control frame representing a stop command.
        class Stop < MasterControl
        end

        # Master-control frame representing an up command.
        class Up < MasterControl
        end
      end
    end
  end
end
