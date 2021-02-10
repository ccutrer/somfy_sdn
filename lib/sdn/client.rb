require 'io/wait'

module SDN
  class Client
    def initialize(port)
      uri = URI.parse(port)
      @io = if uri.scheme == "tcp"
        require 'socket'
        TCPSocket.new(uri.host, uri.port)
      elsif uri.scheme == "telnet" || uri.scheme == "rfc2217"
        require 'net/telnet/rfc2217'
        Net::Telnet::RFC2217.new('Host' => uri.host,
         'Port' => uri.port || 23,
         'baud' => 4800,
         'parity' => Net::Telnet::RFC2217::ODD)
      elsif port == "/dev/ptmx"
        require 'pty'
        io, slave = PTY.open
        puts "Slave PTY available at #{slave.path}"
        io
      else
        require 'ccutrer-serialport'
        CCutrer::SerialPort.new(port, baud: 4800, data_bits: 8, parity: :odd, stop_bits: 1)
      end
      @buffer = ""
    end

    def send(message)
      @io.write(message.serialize)
    end

    def transact(message)
      message.ack_requested = true
      send(message)
      receive(1)
    end

    def ensure(message)
      loop do
        messages = transact(message)
        next if messages.empty?
        next unless message.expected_response?(messages.first)
        return messages.first
      end
    end

    WAIT_TIME = 0.25

    def receive(timeout = nil)
      messages = []

      loop do
        message, bytes_read = Message.parse(@buffer.bytes)
        # discard how much we read
        @buffer = @buffer[bytes_read..-1]
        unless message
          break unless messages.empty?

          begin
            @buffer.concat(@io.read_nonblock(64 * 1024))
            next
          rescue IO::WaitReadable, EOFError
            wait = @buffer.empty? ? timeout : WAIT_TIME
            if @io.wait_readable(wait).nil?
              # timed out; just discard everything
              @buffer = ""
            end
          end
          next
        end
        yield message if block_given?
        messages << message
      end

      messages
    end
  end
end
