# frozen_string_literal: true

RSpec.describe GirbMcp do
  it "has a version number" do
    expect(GirbMcp::VERSION).not_to be_nil
    expect(GirbMcp::VERSION).to eq("0.1.0")
  end

  describe GirbMcp::Error do
    it "is a StandardError" do
      expect(GirbMcp::Error.new).to be_a(StandardError)
    end
  end

  describe GirbMcp::ConnectionError do
    it "is a GirbMcp::Error" do
      expect(GirbMcp::ConnectionError.new).to be_a(GirbMcp::Error)
    end

    it "stores final_output" do
      err = GirbMcp::ConnectionError.new("msg", final_output: "some output")
      expect(err.message).to eq("msg")
      expect(err.final_output).to eq("some output")
    end

    it "defaults final_output to nil" do
      err = GirbMcp::ConnectionError.new("msg")
      expect(err.final_output).to be_nil
    end
  end

  describe GirbMcp::SessionError do
    it "is a GirbMcp::Error" do
      expect(GirbMcp::SessionError.new).to be_a(GirbMcp::Error)
    end

    it "stores final_output" do
      err = GirbMcp::SessionError.new("msg", final_output: "output")
      expect(err.message).to eq("msg")
      expect(err.final_output).to eq("output")
    end
  end

  describe GirbMcp::TimeoutError do
    it "is a GirbMcp::Error" do
      expect(GirbMcp::TimeoutError.new).to be_a(GirbMcp::Error)
    end
  end
end
