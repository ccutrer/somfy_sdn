# frozen_string_literal: true

require "spec_helper"

RSpec.describe SDN::Client do
  let(:client) { described_class.allocate }
  let(:io) { instance_double(IO) }

  before do
    client.instance_variable_set(:@io, io)
    client.instance_variable_set(:@buffer, +"")
  end

  describe "#send" do
    it "writes the serialized frame to the transport" do
      message = SDN::Message::GetMotorStatus.new([0x01, 0x02, 0x03])

      expect(io).to receive(:write).with(message.serialize)

      client.send(message)
    end
  end

  describe "#transact" do
    it "forces ack_requested and waits for an initial response batch" do
      message = SDN::Message::GetMotorStatus.new([0x01, 0x02, 0x03], ack_requested: false)

      expect(client).to receive(:send).with(message)
      expect(client).to receive(:receive).with(1).and_return([:ack])

      expect(client.transact(message)).to eq([:ack])
      expect(message.ack_requested).to be(true)
    end
  end

  describe "#ensure" do
    it "retries until the first response matches the expected type" do
      request = SDN::Message::GetMotorStatus.new([0x01, 0x02, 0x03])
      wrong = SDN::Message::Ack.new(request.dest)
      right = SDN::Message::PostMotorStatus.new(node_type: :st50ac, src: request.dest, dest: request.src)

      allow(client).to receive(:transact).with(request).and_return([], [wrong], [right])

      expect(client.ensure(request)).to eq(right)
      expect(client).to have_received(:transact).with(request).exactly(3).times
    end
  end

  describe "#receive" do
    it "reads and returns multiple parsed messages" do
      first = SDN::Message::Ack.new([0x01, 0x02, 0x03])
      second = SDN::Message::PostMotorPosition.new(220,
                                                   35,
                                                   2,
                                                   node_type: :st50ac,
                                                   src: [0x01, 0x02, 0x03],
                                                   dest: [0x00, 0x00, 0x01])
      chunk = first.serialize + second.serialize

      calls = 0
      allow(io).to receive(:read_nonblock) do
        calls += 1
        (calls == 1) ? chunk : raise(IO::EAGAINWaitReadable)
      end
      allow(io).to receive(:wait_readable).with(nil).and_return(nil)

      messages = client.receive

      expect(messages).to eq([first, second])
      expect(client.instance_variable_get(:@buffer)).to eq("")
    end

    it "yields parsed messages when a block is given" do
      message = SDN::Message::Ack.new([0x01, 0x02, 0x03])

      calls = 0
      allow(io).to receive(:read_nonblock) do
        calls += 1
        (calls == 1) ? message.serialize : raise(IO::EAGAINWaitReadable)
      end
      allow(io).to receive(:wait_readable).with(0.1).and_return(nil)

      yielded = []
      result = client.receive(0.1) { |parsed| yielded << parsed }

      expect(result).to eq([])
      expect(yielded).to eq([message])
    end

    it "times out on partial data, discards the buffer, and returns what it has" do
      partial = SDN::Message::GetMotorStatus.new([0x01, 0x02, 0x03]).serialize.bytes.first(4).pack("C*")

      calls = 0
      allow(io).to receive(:read_nonblock) do
        calls += 1
        (calls == 1) ? partial : raise(IO::EAGAINWaitReadable)
      end
      allow(io).to receive(:wait_readable).with(described_class::WAIT_TIME).and_return(nil)

      expect(client.receive(0.5)).to eq([])
      expect(client.instance_variable_get(:@buffer)).to eq("")
    end
  end
end
