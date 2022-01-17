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
        Net::Telnet::RFC2217.new(host: uri.host,
         port: uri.port || 23,
         baud: 4800,
         data_bits: 8,
         parity: :odd,
         stop_bits: 1)
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
        next unless message.class.expected_response?(messages.first)
        return messages.first
      end
    end

    WAIT_TIME = 0.25

    def receive(timeout = nil)
      messages = []

      loop do
        message, bytes_read = Message.parse(@buffer.bytes)
        # discard how much we read
        @buffer = @buffer[bytes_read..-1] if bytes_read
        unless message
          break unless messages.empty?

          # one EOF is just serial ports saying they have no data;
          # two EOFs in a row is the file is dead and gone
          eofs = 0
          begin
            block = @io.read_nonblock(64 * 1024)
            SDN.logger.debug "read #{block.unpack("H*").first.gsub(/\h{2}/, "\\0 ")}"
            @buffer.concat(block)
            next
          rescue IO::WaitReadable, EOFError => e
            if e.is_a?(EOFError)
              eofs += 1
            else
              eofs = 0
            end
            raise if eofs == 2

            wait = @buffer.empty? ? timeout : WAIT_TIME
            if @io.wait_readable(wait).nil?
              # timed out; just discard everything
              SDN.logger.debug "discarding #{@buffer.unpack("H*").first.gsub(/\h{2}/, "\\0 ")} due to timeout"
              @buffer = ""
            end

            retry
          end
          next
        end
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
