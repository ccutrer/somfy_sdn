module SDN
  module CLI
    class MQTT
      module Write
        def write
          last_write_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          loop do
            message_and_retries = nil
            @mutex.synchronize do
              # got woken up early by another command getting queued; spin
              if @response_pending
                while @response_pending
                  remaining_wait = @response_pending - Time.now.to_f
                  if remaining_wait < 0
                    SDN.logger.debug "timed out waiting on response"
                    @response_pending = nil
                    @broadcast_pending = nil
                    if @prior_message && @prior_message&.remaining_retries != 0
                      SDN.logger.debug "retrying #{@prior_message.remaining_retries} more times ..."
                      if Message.is_group_address?(@prior_message.message.src) && !@pending_group_motors.empty?
                        SDN.logger.debug "re-targetting group message to individual motors"
                        @pending_group_motors.each do |addr|
                          new_message = @prior_message.message.dup
                          new_message.src = [0, 0, 1]
                          new_message.dest = Message.parse_address(addr)
                          @queues[@prior_message.priority].push(MessageAndRetries.new(new_message, @prior_message.remaining_retries, @prior_message.priority))
                        end
                        @pending_group_motors = []
                      else
                        @queues[@prior_message.priority].push(@prior_message)
                      end
                      @prior_message = nil
                    end
                  else
                    @cond.wait(@mutex, remaining_wait)
                  end
                end
              end

              @queues.find { |q| message_and_retries = q.shift }
              if message_and_retries
                if message_and_retries.message.ack_requested || message_and_retries.message.class.name =~ /^SDN::Message::Get/
                  @response_pending = Time.now.to_f + WAIT_TIME
                  @pending_group_motors = if Message.is_group_address?(message_and_retries.message.src)
                    group_addr = Message.print_address(message_and_retries.message.src).gsub('.', '')
                    @groups[group_addr]&.motor_objects&.map(&:addr) || []
                  else
                    []
                  end
                    
                  if message_and_retries.message.dest == BROADCAST_ADDRESS || Message.is_group_address?(message_and_retries.message.src) && message_and_retries.message.is_a?(Message::GetNodeAddr)
                    @broadcast_pending = Time.now.to_f + BROADCAST_WAIT
                  end
                end
              end

              # wait until there is a message
              if @response_pending
                message_and_retries.remaining_retries -= 1
                @prior_message = message_and_retries  
              elsif message_and_retries
                @prior_message = nil  
              else
                if @auto_discover && @motors_found
                  # nothing pending to write, and motors found on the last iteration;
                  # look for more motors
                  message_and_retries = MessageAndRetries.new(Message::GetNodeAddr.new, 1, 2)
                  @motors_found = false
                else
                  @cond.wait(@mutex)
                end
              end
            end
            next unless message_and_retries

            message = message_and_retries.message
            SDN.logger.info "writing #{message.inspect}"
            # minimum time between messages
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            sleep_time = 0.1 - (now - last_write_at)
            sleep(sleep_time) if sleep_time > 0
            @sdn.send(message)
            last_write_at = now
          end
        rescue => e
          SDN.logger.fatal "failure writing: #{e}: #{e.backtrace}"
          exit 1
        end
      end
    end
  end
end
