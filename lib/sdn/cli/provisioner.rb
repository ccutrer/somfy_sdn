require 'curses'

module SDN
  module CLI
    class Provisioner
      attr_reader :win, :sdn, :addr, :ns

      def initialize(port, addr = nil)
        @sdn = Client.new(port)
        @reversed = false
        @pulse_count = 10

        if addr
          @addr = addr = Message.parse_address(addr)
        else
          puts "Discovering motor..."
          message = sdn.ensure(Message::GetNodeAddr.new)
          puts "Found #{message.node_type}"
          @addr = addr = message.src
        end

        puts "Preparing to provision motor #{Message.print_address(addr)}"

        message = sdn.ensure(Message::GetNodeLabel.new(addr))

        node_type = message.node_type
        @ns = ns = node_type == :st50ilt2 ? Message::ILT2 : Message

        print "Motor is currently labeled '#{message.label}'; what would you like to change it to (blank to leave alone)? "
        new_label = STDIN.gets

        unless new_label == "\n"
          new_label.strip!
          sdn.ensure(ns::SetNodeLabel.new(addr, new_label))
        end

        # make sure some limits exist
        unless ns == Message::ILT2
          limits = sdn.ensure(Message::GetMotorLimits.new(addr))
          if limits.up_limit.nil? || limits.down_limit.nil?
            sdn.ensure(Message::SetMotorLimits.new(addr, :delete, :up))
            sdn.ensure(Message::SetMotorLimits.new(addr, :delete, :down))
            sdn.ensure(Message::SetMotorLimits.new(addr, :current_position, :up))
            sdn.ensure(Message::SetMotorLimits.new(addr, :specified_position, :down, 500))
          end
        end

        Curses.init_screen
        begin
          Curses.noecho
          Curses.crmode
          Curses.nonl
          Curses.curs_set(0)
          @win = Curses.stdscr
      
          process
        rescue => e
          win.setpos(0, 0)
          win.addstr(e.inspect)
          win.addstr("\n")
          win.addstr(e.backtrace.join("\n"))
          win.refresh
          sleep 10
        ensure
          Curses.close_screen
        end
      end

      def process
        win.keypad = true
        print_help
        refresh
        wait_for_stop

        loop do
          char = win.getch
          case char
          when 27 # Esc
            stop
            refresh
          when Curses::Key::UP
            if ilt2?
              sdn.ensure(Message::ILT2::SetMotorPosition.new(addr, :up_limit))
            else
              sdn.ensure(Message::MoveTo.new(addr, :up_limit))
            end
            wait_for_stop
          when Curses::Key::DOWN
            if ilt2?
              sdn.ensure(Message::ILT2::SetMotorPosition.new(addr, :down_limit))
            else
              sdn.ensure(Message::MoveTo.new(addr, :down_limit))
            end
            wait_for_stop
          when Curses::Key::LEFT
            if @pos < @pulse_count
              sdn.ensure(Message::ILT2::SetMotorSettings.new(addr, reversed_int, @limit + @pulse_count - @pos, @pulse_count))
              refresh
            end
            sdn.ensure(Message::ILT2::SetMotorPosition.new(addr, :jog_up_pulses, @pulse_count))
            wait_for_stop
          when Curses::Key::RIGHT
            if @limit - @pos < @pulse_count
              sdn.ensure(Message::ILT2::SetMotorSettings.new(addr, reversed_int, @pos + @pulse_count, @pos))
              refresh
            end
            sdn.ensure(Message::ILT2::SetMotorPosition.new(addr, :jog_down_pulses, @pulse_count))
            wait_for_stop
          when 'u'
            if ilt2?
              sdn.ensure(Message::ILT2::SetMotorSettings.new(addr, reversed_int, @limit - @pos, 0))
            else
              sdn.ensure(Message::SetMotorLimits.new(addr, :current_position, :up))
            end
            refresh
          when 'l'
            if ilt2?
              sdn.ensure(Message::ILT2::SetMotorSettings.new(addr, reversed_int, @pos, @pos))
            else
              sdn.ensure(Message::SetMotorLimits.new(addr, :current_position, :down))
            end
            refresh
          when 'r'
            @reversed = !@reversed
            if ilt2?
              sdn.ensure(Message::ILT2::SetMotorSettings.new(addr, reversed_int, @limit, @limit - @pos))
            else
              sdn.ensure(Message::SetMotorDirection.new(addr, @reversed ? :reversed : :standard))
            end
            refresh
          when 'R'
            next unless ilt2?
            @reversed = !@reversed
            sdn.ensure(Message::ILT2::SetMotorSettings.new(addr, reversed_int, @limit, @pos))
            refresh
          when '<'
            @pulse_count /= 2 if @pulse_count > 5
            print_help
          when '>'
            @pulse_count *= 2
            print_help
          when 'q'
            break
          end
        end
      end

      def print_help
        win.setpos(0, 0)
        win.addstr(<<-INSTRUCTIONS)
Move the motor. Keys:
Esc  stop movement
\u2191    go to upper limit
\u2193    go to lower limit
\u2190    jog up #{@pulse_count} pulses
\u2192    jog down #{@pulse_count} pulses
>    increase jog size
<    decrease jog size
u    set upper limit at current position
l    set lower limit at current position
r    reverse motor
        INSTRUCTIONS

        if ilt2?
          win.addstr("R    reverse motor (but leave position alone)\n")
        end
        win.addstr("q    quit\n")
        win.refresh
      end
      
      def wait_for_stop
        win.setpos(13, 0)
        win.addstr("Moving...\n")

        loop do
          win.nodelay = true
          stop if win.getch == 27 # Esc

          sdn.send(ns::GetMotorPosition.new(addr))
          unless ilt2?
            sleep 0.1
            sdn.send(ns::GetMotorStatus.new(addr))
          end

          sdn.receive(0.1) do |message|

            if message.is_a?(ns::PostMotorPosition)
              last_pos = @pos
              @pos = message.position_pulses
              win.setpos(14, 0)
              win.addstr("Position: #{@pos}\n")
            end

            if (ilt2? && last_pos == @pos) ||
               (message.is_a?(Message::PostMotorStatus) &&
                message.state != :running)
              win.setpos(13, 0)
              win.addstr("\n")
              win.nodelay = false
              refresh
              return
            end
          end
          sleep 0.1
        end
      end

      def refresh
        pos = sdn.ensure(ns::GetMotorPosition.new(addr))
        @pos = pos.position_pulses
        if ilt2?
          settings = sdn.ensure(Message::ILT2::GetMotorSettings.new(addr))
          @limit = settings.limit
        else
          limits = sdn.ensure(Message::GetMotorLimits.new(addr))
          @limit = limits.down_limit
          direction = sdn.ensure(Message::GetMotorDirection.new(addr))
          @reversed = direction.direction == :reversed
        end

        win.setpos(14, 0)
        win.addstr("Position: #{@pos}\n")
        win.addstr("Limit: #{@limit}\n")
        win.addstr("Reversed: #{@reversed}\n")
        win.refresh
      end

      def stop
        if ilt2?
          sdn.ensure(Message::ILT2::SetMotorPosition.new(addr, :stop))
        else
          sdn.ensure(Message::Stop.new(addr))
        end
      end

      def ilt2?
        ns == Message::ILT2
      end

      def reversed_int
        @reversed ? 1 : 0
      end
    end
  end
end
