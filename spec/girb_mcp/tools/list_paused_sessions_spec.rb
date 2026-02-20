# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::ListPausedSessions do
  let(:manager) { build_mock_manager }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "shows message when no sessions" do
      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("No active debug sessions")
    end

    it "lists active sessions" do
      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "session_123",
          pid: "123",
          connected: true,
          paused: false,
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

    it "shows paused status and location info" do
      client = build_mock_client
      allow(client).to receive(:send_command).with("frame")
        .and_return("#0  UsersController#show at app/controllers/users_controller.rb:10")
      allow(client).to receive(:send_command).with("info breakpoints")
        .and_return("#1  BP - Line  app/controllers/users_controller.rb:10\n#2  BP - Catch  \"NoMethodError\"")

      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "session_123",
          pid: "123",
          connected: true,
          paused: true,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 5,
          client: client,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("paused")
      expect(text).to include("Location: app/controllers/users_controller.rb:10 in UsersController#show")
      expect(text).to include("Breakpoints: 2 set")
    end

    it "handles errors when querying session details" do
      client = build_mock_client
      allow(client).to receive(:send_command).and_raise(GirbMcp::TimeoutError, "timeout")

      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "session_123",
          pid: "123",
          connected: true,
          paused: true,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 5,
          client: client,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("session_123")
      expect(text).not_to include("Location:")
    end

    it "formats duration in minutes" do
      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: true,
          paused: false,
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
      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: true,
          paused: false,
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
      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: false,
          paused: false,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 10,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("disconnected")
    end

    it "shows remaining time when plenty of time left" do
      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: true,
          paused: false,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 60,
          timeout_seconds: 1800,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("29m 0s remaining")
      expect(text).not_to include("WARNING")
    end

    it "shows warning when less than 5 minutes remaining" do
      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: true,
          paused: false,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 1620,
          timeout_seconds: 1800,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("3m 0s remaining")
      expect(text).to include("WARNING: expiring soon")
    end

    it "shows expired warning when timeout exceeded" do
      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: true,
          paused: false,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 2000,
          timeout_seconds: 1800,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("EXPIRED")
    end

    it "shows footer note about session expiry" do
      allow(manager).to receive(:active_sessions).with(include_client: true).and_return([
        {
          session_id: "s1",
          pid: "1",
          connected: true,
          paused: false,
          connected_at: Time.now,
          last_activity_at: Time.now,
          idle_seconds: 10,
          timeout_seconds: 1800,
        },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Sessions expire after inactivity")
      expect(text).to include("Any tool call resets the timer")
    end
  end
end
