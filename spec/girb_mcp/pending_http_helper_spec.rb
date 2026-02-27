# frozen_string_literal: true

require "spec_helper"

RSpec.describe GirbMcp::PendingHttpHelper do
  describe ".pending_http_note" do
    it "returns nil when no pending HTTP" do
      client = build_mock_client
      allow(client).to receive(:pending_http).and_return(nil)

      expect(described_class.pending_http_note(client)).to be_nil
    end

    it "returns nil when HTTP is still running" do
      client = build_mock_client
      holder = { response: nil, error: nil, done: false }
      allow(client).to receive(:pending_http).and_return(
        { holder: holder, method: "GET", url: "http://localhost:3000/" },
      )

      expect(described_class.pending_http_note(client)).to be_nil
    end

    it "returns response note when HTTP completed successfully" do
      client = build_mock_client
      holder = { response: { status: "200 OK" }, error: nil, done: true }
      allow(client).to receive(:pending_http).and_return(
        { holder: holder, method: "GET", url: "http://localhost:3000/users" },
      )

      note = described_class.pending_http_note(client)
      expect(note).to include("HTTP response received (200 OK)")
      expect(note).to include("continue_execution")
    end

    it "returns error note when HTTP failed" do
      client = build_mock_client
      error = Net::ReadTimeout.new("execution expired")
      holder = { response: nil, error: error, done: true }
      allow(client).to receive(:pending_http).and_return(
        { holder: holder, method: "POST", url: "http://localhost:3000/users" },
      )

      note = described_class.pending_http_note(client)
      expect(note).to include("HTTP request (POST http://localhost:3000/users) failed")
      expect(note).to include("execution expired")
    end
  end
end
