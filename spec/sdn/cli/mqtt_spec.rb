# frozen_string_literal: true

require "spec_helper"

RSpec.describe SDN::CLI::MQTT do
  let(:bridge) { described_class.allocate }
  let(:queue) { SDN::CLI::MQTT::PQueue.new }
  let(:mutex) { instance_double(Mutex) }
  let(:cond) { instance_double(ConditionVariable, signal: nil) }
  let(:sdn) { instance_double(SDN::Client) }
  let(:base_topic) { "homie/somfy" }
  let(:motor_addr) { "010203" }
  let(:group_addr) { "0101AA" }
  let(:motor_bytes) { SDN::Message.parse_address(motor_addr) }
  let(:motor) { SDN::CLI::MQTT::Motor.new(bridge, motor_addr, :st50ac) }

  before do
    bridge.instance_variable_set(:@base_topic, base_topic)
    bridge.instance_variable_set(:@queue, queue)
    bridge.instance_variable_set(:@mutex, mutex)
    bridge.instance_variable_set(:@cond, cond)
    bridge.instance_variable_set(:@motors, { motor_addr => motor })
    bridge.instance_variable_set(:@groups, {})
    bridge.instance_variable_set(:@sdn, sdn)
    bridge.instance_variable_set(:@auto_discover, false)
    bridge.instance_variable_set(:@motors_found, false)
    bridge.instance_variable_set(:@response_pending, nil)
    bridge.instance_variable_set(:@broadcast_pending, nil)
    bridge.instance_variable_set(:@prior_message, nil)
    bridge.instance_variable_set(:@pending_group_motors, [])

    allow(mutex).to receive(:synchronize).and_yield
    allow(bridge).to receive(:publish)
  end

  describe "#handle_message" do
    it "queues a label write and label refresh for individual motors" do
      bridge.handle_message("#{base_topic}/#{motor_addr}/label/set", "Kitchen")

      expect(queue.length).to eq(2)
      write, refresh = queue
      expect(write.message).to eq(SDN::Message::SetNodeLabel.new(motor_bytes, "Kitchen", ack_requested: true))
      expect(refresh.message).to eq(SDN::Message::GetNodeLabel.new(motor_bytes))
      expect(write.remaining_retries).to eq(5)
      expect(refresh.priority).to eq(1)
    end

    it "maps control commands to MoveTo and tracks last_action" do
      bridge.handle_message("#{base_topic}/#{motor_addr}/control/set", "down")

      command, follow_up = queue

      expect(command.message).to eq(SDN::Message::MoveTo.new(motor_bytes, :down_limit, nil, :up, ack_requested: true))
      expect(follow_up.message).to eq(SDN::Message::GetMotorStatus.new(motor_bytes))
      expect(motor.last_action).to eq(SDN::Message::MoveTo)
    end

    it "treats position-percent shutter verbs as control messages" do
      bridge.handle_message("#{base_topic}/#{motor_addr}/position-percent/set", "UP")

      expect(queue.first.message).to eq(SDN::Message::MoveTo.new(motor_bytes, :up_limit, nil, :up, ack_requested: true))
    end

    it "queues a single follow-up even when it is already pending" do
      queue.push(described_class::MessageAndRetries.new(SDN::Message::GetMotorStatus.new(motor_bytes), 5, 1))

      bridge.handle_message("#{base_topic}/#{motor_addr}/position-pulses/set", "300")

      follow_ups = queue.select { |entry| entry.message == SDN::Message::GetMotorStatus.new(motor_bytes) }
      expect(follow_ups.length).to eq(1)
    end

    it "uses ILT2 command types for ILT2 motors" do
      ilt2_motor = SDN::CLI::MQTT::Motor.new(bridge, motor_addr, :st50ilt2)
      bridge.motors[motor_addr] = ilt2_motor

      bridge.handle_message("#{base_topic}/#{motor_addr}/control/set", "next_ip")

      command, follow_up = queue

      expect(command.message).to eq(SDN::Message::ILT2::SetMotorPosition.new(motor_bytes,
                                                                             :next_ip_down,
                                                                             0,
                                                                             ack_requested: true))
      expect(follow_up.message).to eq(SDN::Message::ILT2::GetMotorPosition.new(motor_bytes))
    end

    it "updates rolling speed by merging current motor state into the request" do
      motor.up_speed = 10
      motor.down_speed = 20
      motor.slow_speed = 30

      bridge.handle_message("#{base_topic}/#{motor_addr}/down-speed/set", "45")

      command, follow_up = queue

      expect(command.message).to eq(SDN::Message::SetMotorRollingSpeed.new(motor_bytes,
                                                                           up_speed: 10,
                                                                           down_speed: 45,
                                                                           slow_speed: 30,
                                                                           ack_requested: true))
      expect(follow_up.message).to eq(SDN::Message::GetMotorRollingSpeed.new(motor_bytes))
    end

    it "expands group updates into per-slot writes returned by the motor model" do
      messages = [
        SDN::Message::SetGroupAddr.new(motor_bytes, 1, SDN::Message.parse_address("01.01.10")),
        SDN::Message::GetGroupAddr.new(motor_bytes, 1)
      ]
      allow(motor).to receive(:set_groups).with("01.01.10").and_return(messages)

      bridge.handle_message("#{base_topic}/#{motor_addr}/groups/set", "01.01.10")

      expect(queue.map(&:message)).to eq(messages)
      expect(queue.map(&:remaining_retries)).to eq([5, 5])
    end

    it "ignores invalid reset values" do
      bridge.handle_message("#{base_topic}/#{motor_addr}/reset/set", "bogus")

      expect(queue).to be_empty
    end

    it "ignores group-only forbidden writes" do
      bridge.handle_message("#{base_topic}/#{group_addr}/label/set", "Group")

      expect(queue).to be_empty
    end

    it "queues group discovery requests at low priority" do
      bridge.handle_message("#{base_topic}/#{group_addr}/discover/set", "discover")

      queued = queue.first
      expect(queued.message).to eq(SDN::Message::GetNodeAddr.new(SDN::Message.parse_address(group_addr)))
      expect(queued.priority).to eq(50)
      expect(queued.remaining_retries).to eq(1)
    end
  end

  describe "#write" do
    it "retries once when an ack-requesting command gets no response" do
      message = SDN::Message::SetNodeLabel.new(motor_bytes, "Retry me", ack_requested: true)
      queue.push(described_class::MessageAndRetries.new(message, 2, 0))

      first_now = instance_double(Time, to_f: 100.0)
      timed_out_now = instance_double(Time, to_f: 101.0)
      retry_now = instance_double(Time, to_f: 101.1)
      allow(Time).to receive(:now).and_return(first_now, timed_out_now, retry_now)
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0, 0.2, 0.4)
      allow(bridge).to receive(:sleep)

      sends = 0
      allow(sdn).to receive(:send) do |sent|
        sends += 1
        expect(sent).to eq(message)
        raise SystemExit if sends == 2
      end

      expect { bridge.write }.to raise_error(SystemExit)
      expect(sdn).to have_received(:send).with(message).twice
      expect(queue).to be_empty
      expect(bridge.instance_variable_get(:@prior_message).remaining_retries).to eq(0)
    end

    it "marks a running motor stopped after the final GetMotorStatus timeout" do
      motor.state = :running
      motor.position_percent = 55
      message = SDN::Message::GetMotorStatus.new(motor_bytes)

      bridge.send(:handle_get_motor_status_timeout, message)

      expect(motor.state).to eq(:stopped)
      expect(motor.hass_state).to eq(:stopped)
      expect(motor.last_action_source).to eq(:bridge)
      expect(motor.last_action_cause).to eq(:timeout)
      expect(bridge).to have_received(:publish).with("#{motor_addr}/state", "stopped")
      expect(bridge).to have_received(:publish).with("#{motor_addr}/hass-state", "stopped")
      expect(bridge).to have_received(:publish).with("#{motor_addr}/last-action-source", "bridge")
      expect(bridge).to have_received(:publish).with("#{motor_addr}/last-action-cause", "timeout")
    end

    it "leaves non-running motors unchanged after a GetMotorStatus timeout" do
      motor.state = :stopped
      message = SDN::Message::GetMotorStatus.new(motor_bytes)

      bridge.send(:handle_get_motor_status_timeout, message)

      expect(motor.state).to eq(:stopped)
      expect(motor.last_action_source).to be_nil
      expect(motor.last_action_cause).to be_nil
      expect(bridge).not_to have_received(:publish).with("#{motor_addr}/state", anything)
    end

    it "marks hass-state open when a running motor times out at 0 percent" do
      motor.state = :running
      motor.position_percent = 0
      message = SDN::Message::GetMotorStatus.new(motor_bytes)

      bridge.send(:handle_get_motor_status_timeout, message)

      expect(motor.hass_state).to eq(:open)
      expect(bridge).to have_received(:publish).with("#{motor_addr}/hass-state", "open")
    end

    it "clears position state after a GetMotorPosition timeout" do
      motor.position_pulses = 1234
      motor.position_percent = 56
      motor.ip = 4
      message = SDN::Message::GetMotorPosition.new(motor_bytes)

      bridge.send(:handle_get_motor_position_timeout, message)

      expect(motor.position_pulses).to be_nil
      expect(motor.position_percent).to be_nil
      expect(motor.ip).to be_nil
      expect(bridge).to have_received(:publish).with("#{motor_addr}/position-pulses", "")
      expect(bridge).to have_received(:publish).with("#{motor_addr}/position-percent", "")
      expect(bridge).to have_received(:publish).with("#{motor_addr}/ip", "")
    end

    it "clears position state after an ILT2 GetMotorPosition timeout" do
      motor.position_pulses = 222
      motor.position_percent = 33
      motor.ip = 2
      message = SDN::Message::ILT2::GetMotorPosition.new(motor_bytes)

      bridge.send(:handle_get_motor_position_timeout, message)

      expect(motor.position_pulses).to be_nil
      expect(motor.position_percent).to be_nil
      expect(motor.ip).to be_nil
    end

    it "does not republish already-cleared position state after a GetMotorPosition timeout" do
      motor.position_pulses = nil
      motor.position_percent = nil
      motor.ip = nil
      message = SDN::Message::GetMotorPosition.new(motor_bytes)

      bridge.send(:handle_get_motor_position_timeout, message)

      expect(bridge).not_to have_received(:publish).with("#{motor_addr}/position-pulses", anything)
      expect(bridge).not_to have_received(:publish).with("#{motor_addr}/position-percent", anything)
      expect(bridge).not_to have_received(:publish).with("#{motor_addr}/ip", anything)
    end
  end
end
