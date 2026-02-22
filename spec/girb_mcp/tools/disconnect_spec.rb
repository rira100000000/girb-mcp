# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::Disconnect do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "disconnects and returns confirmation" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Disconnected from session")
    end

    it "returns message when no active session" do
      allow(manager).to receive(:client).and_raise(
        GirbMcp::SessionError, "No active session"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("No active session to disconnect")
    end

    it "kills process for run_script sessions" do
      wait_thread = instance_double(Thread, alive?: true)
      allow(client).to receive(:wait_thread).and_return(wait_thread)
      allow(client).to receive(:pid).and_return("999")
      allow(Process).to receive(:kill)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(Process).to have_received(:kill).with("TERM", 999)
      expect(text).to include("Process 999 terminated")
    end

    it "handles already-exited process gracefully" do
      wait_thread = instance_double(Thread, alive?: true)
      allow(client).to receive(:wait_thread).and_return(wait_thread)
      allow(client).to receive(:pid).and_return("999")
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Disconnected from session")
      expect(text).not_to include("terminated")
    end

    it "resumes process on disconnect for connect sessions" do
      # connect session: wait_thread is nil (default from build_mock_client)
      allow(client).to receive(:send_command).and_return("")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(client).to have_received(:send_command_no_wait).with("c")
      expect(text).to include("Disconnected from session")
    end

    it "deletes all breakpoints before continuing for connect sessions" do
      bp_output = "#0  BP - Line  app/controllers/users_controller.rb:10\n" \
                  "#1  BP - Line  app/models/user.rb:20\n"
      allow(client).to receive(:send_command).with("info breakpoints", timeout: anything).and_return(bp_output)
      allow(client).to receive(:send_command).with("delete 0", timeout: anything).and_return("")
      allow(client).to receive(:send_command).with("delete 1", timeout: anything).and_return("")

      described_class.call(server_context: server_context)

      expect(client).to have_received(:send_command).with("info breakpoints", timeout: anything)
      expect(client).to have_received(:send_command).with("delete 0", timeout: anything)
      expect(client).to have_received(:send_command).with("delete 1", timeout: anything)
      expect(client).to have_received(:send_command_no_wait).with("c")
    end

    it "skips BP deletion when no breakpoints are set" do
      allow(client).to receive(:send_command).and_return("")

      described_class.call(server_context: server_context)

      expect(client).not_to have_received(:send_command).with(/\Adelete/, anything)
      expect(client).to have_received(:send_command_no_wait).with("c")
    end

    it "continues even when BP deletion fails" do
      allow(client).to receive(:send_command).with("info breakpoints", timeout: anything).and_raise(
        GirbMcp::ConnectionError, "lost"
      )

      described_class.call(server_context: server_context)

      expect(client).to have_received(:send_command_no_wait).with("c")
    end

    it "skips cleanup entirely when process is not paused" do
      allow(client).to receive(:paused).and_return(false)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(client).not_to have_received(:send_command)
      expect(client).not_to have_received(:send_command_no_wait)
      expect(text).to include("Disconnected from session")
    end

    it "does not send continue for run_script sessions" do
      wait_thread = instance_double(Thread, alive?: true)
      allow(client).to receive(:wait_thread).and_return(wait_thread)
      allow(client).to receive(:pid).and_return("999")
      allow(Process).to receive(:kill)

      described_class.call(server_context: server_context)

      expect(client).not_to have_received(:send_command_no_wait)
    end

    it "suggests next steps" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("run_script")
      expect(text).to include("connect")
    end

    it "restores SIGINT handler on disconnect for connect sessions" do
      allow(client).to receive(:send_command).and_return("")
      allow(client).to receive(:send_command)
        .with(/\$_girb_orig_int/, timeout: anything)
        .and_return("=> :ok")

      described_class.call(server_context: server_context)

      expect(client).to have_received(:send_command).with(/\$_girb_orig_int.*trap/, timeout: anything)
    end

    it "does not fail disconnect when SIGINT restore fails" do
      allow(client).to receive(:send_command)
        .with(/\$_girb_orig_int/, timeout: anything)
        .and_raise(GirbMcp::ConnectionError, "lost connection")
      allow(client).to receive(:send_command).and_return("")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Disconnected from session")
    end

    it "does not restore SIGINT handler for run_script sessions" do
      wait_thread = instance_double(Thread, alive?: true)
      allow(client).to receive(:wait_thread).and_return(wait_thread)
      allow(client).to receive(:pid).and_return("999")
      allow(Process).to receive(:kill)

      described_class.call(server_context: server_context)

      expect(client).not_to have_received(:send_command).with(/\$_girb_orig_int/)
    end
  end
end
