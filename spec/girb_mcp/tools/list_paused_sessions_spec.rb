# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::ListPausedSessions do
  let(:manager) { build_mock_manager }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "shows message when no sessions" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("No active debug sessions")
    end

    it "lists active sessions" do
      allow(manager).to receive(:active_sessions).and_return([
        {
          session_id: "session_123",
          pid: "123",
          connected: true,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 45,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Active debug sessions")
      expect(text).to include("session_123")
      expect(text).to include("PID: 123")
      expect(text).to include("connected")
      expect(text).to include("45s")
    end

    it "formats duration in minutes" do
      allow(manager).to receive(:active_sessions).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: true,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 125,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("2m 5s")
    end

    it "formats duration in hours" do
      allow(manager).to receive(:active_sessions).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: true,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 3725,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("1h 2m")
    end

    it "shows disconnected status" do
      allow(manager).to receive(:active_sessions).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: false,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 10,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("disconnected")
    end
  end
end
