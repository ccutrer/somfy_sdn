module SDN
  module CLI
    class MQTT
      module Write
        def write
          loop do
            message_and_retries = nil
            @mutex.synchronize do
              # got woken up early by another command getting queued; spin
              if @response_pending
                while @response_pending
                  remaining_wait = @response_pending - Time.now.to_f
                  if remaining_wait < 0
                    puts "timed out waiting on response"
                    @response_pending = nil
                    @broadcast_pending = nil
                    if @prior_message&.remaining_retries != 0
                      puts "retrying #{@prior_message.remaining_retries} more times ..."
                      @queues[@prior_message.priority].push(@prior_message)
                      @prior_message = nil
                    end
                  else
                    @cond.wait(@mutex, remaining_wait)
                  end
                end
              else
                # minimum time between messages
                sleep 0.1
              end

              @queues.find { |q| message_and_retries = q.shift }
              if message_and_retries
                if message_and_retries.message.ack_requested || message_and_retries.message.class.name =~ /^SDN::Message::Get/
                  @response_pending = Time.now.to_f + WAIT_TIME
                  if message_and_retries.message.dest == BROADCAST_ADDRESS || Message::is_group_address?(message_and_retries.message.src) && message_and_retries.message.is_a?(Message::GetNodeAddr)
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
                @cond.wait(@mutex)
              end
            end
            next unless message_and_retries

            message = message_and_retries.message
            puts "writing #{message.inspect}"
            @sdn.send(message)
          end
        rescue => e
          puts "failure writing: #{e}"
          exit 1
        end
      end
    end
  end
end