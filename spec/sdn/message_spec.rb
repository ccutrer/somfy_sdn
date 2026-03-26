# frozen_string_literal: true

require "spec_helper"

RSpec.describe SDN::Message do
  let(:src) { [0x01, 0x02, 0x03] }
  let(:dest) { [0x04, 0x05, 0x06] }

  describe ".parse" do
    it "round trips a standard request frame" do
      message = SDN::Message::GetMotorPosition.new(dest,
                                                   node_type: :st50ac,
                                                   ack_requested: true,
                                                   src:)

      parsed, consumed = described_class.parse(message.serialize.bytes)

      expect(consumed).to eq(message.serialize.bytesize)
      expect(parsed).to eq(message)
      expect(parsed).to be_a(SDN::Message::GetMotorPosition)
      expect(parsed.node_type).to eq(:st50ac)
      expect(parsed.ack_requested).to be(true)
      expect(parsed.src).to eq(src)
      expect(parsed.dest).to eq(dest)
    end

    it "round trips a parsed response payload" do
      message = SDN::Message::PostMotorPosition.new(1234,
                                                    66,
                                                    4,
                                                    node_type: :st50dc,
                                                    src: dest,
                                                    dest: src)

      parsed, = described_class.parse(message.serialize.bytes)

      expect(parsed).to be_a(SDN::Message::PostMotorPosition)
      expect(parsed.position_pulses).to eq(1234)
      expect(parsed.position_percent).to eq(66)
      expect(parsed.ip).to eq(4)
      expect(parsed.src).to eq(dest)
      expect(parsed.dest).to eq(src)
    end

    it "round trips ILT2 position commands with percent targets" do
      message = SDN::Message::ILT2::SetMotorPosition.new(dest,
                                                         :position_percent,
                                                         37.5,
                                                         node_type: :st50ilt2,
                                                         src:)

      parsed, = described_class.parse(message.serialize.bytes)

      expect(parsed).to be_a(SDN::Message::ILT2::SetMotorPosition)
      expect(parsed.target_type).to eq(:position_percent)
      expect(parsed.target).to be_within(0.5).of(37.5)
      expect(parsed.node_type).to eq(:st50ilt2)
    end

    it "skips leading garbage until a valid frame is found" do
      message = SDN::Message::GetNodeLabel.new(dest)
      bytes = [0x00, 0x01, 0x02] + message.serialize.bytes

      parsed, consumed = described_class.parse(bytes)

      expect(parsed).to eq(message)
      expect(consumed).to eq(bytes.length)
    end

    it "returns unknown messages for unrecognized opcodes" do
      known = SDN::Message::GetMotorStatus.new(dest, src:)
      bytes = known.serialize.bytes
      bytes[0] = described_class.transform_param(0x7e).first
      checksum = described_class.checksum(bytes[0...-2])
      bytes[-2] = checksum[0]
      bytes[-1] = checksum[1]

      parsed, = described_class.parse(bytes)

      expect(parsed).to be_a(SDN::Message::UnknownMessage)
      expect(parsed.msg).to eq(0x7e)
    end

    it "returns nil when only a partial frame is buffered" do
      message = SDN::Message::GetMotorStatus.new(dest)

      parsed, consumed = described_class.parse(message.serialize.bytes.first(5))

      expect(parsed).to be_nil
      expect(consumed).to eq(0)
    end
  end

  describe "message payload parsing" do
    it "decodes symbolic NACK error codes" do
      message = SDN::Message::Nack.new(dest, :busy, src:)

      parsed, = described_class.parse(message.serialize.bytes)

      expect(parsed).to be_a(SDN::Message::Nack)
      expect(parsed.error_code).to eq(:busy)
    end

    it "raises on malformed fixed-length payloads" do
      message = SDN::Message::GetMotorIP.new(dest, 3)

      expect do
        message.parse([])
      end.to raise_error(SDN::MalformedMessage, /unrecognized params/)
    end

    it "truncates and trims node labels consistently" do
      message = SDN::Message::SetNodeLabel.new(dest, "  Living Room Shade Label  ")

      parsed, = described_class.parse(message.serialize.bytes)

      expect(parsed).to be_a(SDN::Message::SetNodeLabel)
      expect(parsed.label).to eq("Living Room Sh")
    end
  end
end
