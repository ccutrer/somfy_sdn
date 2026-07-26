# frozen_string_literal: true

require "io/wait"

module SDN
  # Transport client for sending and receiving SDN frames over serial, TCP, RFC2217, or PTY.
  class Client
    # Enables or disables raw byte tracing in the client logs.
    #
    # @return [true, false]
    attr_writer :trace

    # Opens a connection to an SDN bus over serial, TCP, RFC2217, or PTY.
    #
    # @param port [String] connection target URI or serial device path
    def initialize(port)
      uri = URI.parse(port)
      @io = if uri.scheme == "tcp"
              require "socket"
              TCPSocket.new(uri.host, uri.port)
            elsif %w[telnet rfc2217].include?(uri.scheme)
              require "net/telnet/rfc2217"
              Net::Telnet::RFC2217.new(host: uri.host,
                                       port: uri.port || 23,
                                       baud: 4800,
                                       data_bits: 8,
                                       parity: :odd,
                                       stop_bits: 1)
            elsif port == "/dev/ptmx"
              require "pty"
              io, slave = PTY.open
              puts "Slave PTY available at #{slave.path}"
              io
            elsif uri.scheme == "esphome"
              gem "esphome", "~> 1.1"
              require "esphome/serial_proxy"
              ESPHome::SerialProxy.open(uri, baud: 4800, data_bits: 8, parity: :odd, stop_bits: 1)
            else
              require "ccutrer-serialport"
              CCutrer::SerialPort.new(port, baud: 4800, data_bits: 8, parity: :odd, stop_bits: 1)
            end
      @buffer = +""
    end

    # Indicates whether raw byte tracing is enabled.
    #
    # @return [true, false]
    def trace?
      @trace
    end

    # Serializes and writes a message to the underlying transport.
    #
    # @param message [SDN::Message]
    #
    # @return [void]
    def send(message)
      SDN.logger.debug("Sending #{message.inspect}")
      @io.write(message.serialize)
    end

    # Sends a message with acknowledgement requested and waits for an initial response batch.
    #
    # @param message [SDN::Message]
    #
    # @return [<SDN::Message>] received response messages
    def transact(message)
      message.ack_requested = true
      send(message)
      receive(1)
    end

    # Re-sends a request until an expected response is received.
    #
    # The expected response message is dependent on the message sent.
    #
    # @param message [SDN::Message]
    #
    # @return [SDN::Message] the message that is of the expected response type
    def ensure(message)
      loop do
        messages = transact(message)
        next if messages.empty?
        next unless message.class.expected_response?(messages.first)

        return messages.first
      end
    end

    # Default inter-read wait time, in seconds, while assembling a partial frame.
    WAIT_TIME = 0.25

    # Reads and parses messages from the transport until parsing is exhausted or a timeout occurs.
    #
    # @param timeout [Numeric, nil] optional read timeout in seconds
    #
    # @yield [message] yields each parsed message when a block is given
    # @yieldparam message [SDN::Message] parsed message
    #
    # @return [<SDN::Message>] parsed messages when no block is given
    def receive(timeout = nil)
      messages = []

      loop do
        message, bytes_read = Message.parse(@buffer.bytes)
        # discard how much we read
        @buffer = @buffer[bytes_read..] if bytes_read
        unless message
          break unless messages.empty?

          # one EOF is just serial ports saying they have no data;
          # several EOFs in a row is the file is dead and gone
          eofs = 0
          begin
            block = @io.read_nonblock(64 * 1024)
            SDN.logger.debug("Read #{block.unpack1("H*").gsub(/\h{2}/, "\\0 ")}") if trace?
            @buffer.concat(block)
            next
          rescue IO::WaitReadable, EOFError => e
            if e.is_a?(EOFError)
              eofs += 1
            else
              eofs = 0
            end
            raise if eofs == 5

            wait = @buffer.empty? ? timeout : WAIT_TIME
            if @io.wait_readable(wait).nil?
              # timed out; just discard everything
              unless @buffer.empty?
                SDN.logger.debug "Discarding #{@buffer.unpack1("H*").gsub(/\h{2}/, "\\0 ")} due to timeout"
              end
              @buffer = +""
              return messages if timeout
            end

            retry
          end
          next
        end

        SDN.logger.debug("Received message #{message.inspect}")
        if block_given?
          yield message
        else
          messages << message
        end
      end

      messages
    end
  end
end
