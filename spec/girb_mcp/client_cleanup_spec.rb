# frozen_string_literal: true

RSpec.describe GirbMcp::ClientCleanup do
  let(:client) { build_mock_client }

  describe ".cleanup_and_resume" do
    it "restores stdout, deletes breakpoints, restores SIGINT, and resumes" do
      bp_output = "#0  BP - Line  app/controllers/users_controller.rb:10\n" \
                  "#1  BP - Line  app/models/user.rb:20\n"

      allow(client).to receive(:send_command).and_return("")
      allow(client).to receive(:send_command)
        .with("info breakpoints", timeout: anything)
        .and_return(bp_output)
      allow(client).to receive(:send_command)
        .with("delete 0", timeout: anything).and_return("")
      allow(client).to receive(:send_command)
        .with("delete 1", timeout: anything).and_return("")
      # Stale pause loop: false → no stale retry
      allow(client).to receive(:paused).and_return(false)

      described_class.cleanup_and_resume(client, deadline: Time.now + 5)

      expect(client).to have_received(:send_command)
        .with('$stdout = STDOUT if $stdout != STDOUT', timeout: anything)
      expect(client).to have_received(:send_command)
        .with("info breakpoints", timeout: anything).once
      expect(client).to have_received(:send_command)
        .with("delete 0", timeout: anything)
      expect(client).to have_received(:send_command)
        .with("delete 1", timeout: anything)
      expect(client).to have_received(:send_command)
        .with(/\$_girb_orig_int/, timeout: anything)
      expect(client).to have_received(:send_command_no_wait).with("c", force: true).once
    end

    it "skips BP deletion when no breakpoints are set" do
      allow(client).to receive(:send_command).and_return("")
      # Stale pause loop: false → no stale retry
      allow(client).to receive(:paused).and_return(false)

      described_class.cleanup_and_resume(client, deadline: Time.now + 5)

      expect(client).not_to have_received(:send_command).with(/\Adelete \d/, anything)
      expect(client).to have_received(:send_command_no_wait).with("c", force: true).once
    end

    it "continues even when BP deletion fails" do
      allow(client).to receive(:send_command)
        .with("info breakpoints", timeout: anything)
        .and_raise(GirbMcp::ConnectionError, "lost")
      allow(client).to receive(:send_command).and_return("")
      # Stale pause loop: false → no stale retry
      allow(client).to receive(:paused).and_return(false)

      described_class.cleanup_and_resume(client, deadline: Time.now + 5)

      expect(client).to have_received(:send_command_no_wait).with("c", force: true).once
    end

    it "retries when stale pause is detected" do
      allow(client).to receive(:send_command).and_return("")
      # paused=true during cleanup, stays true after first c, then goes false
      allow(client).to receive(:paused).and_return(true, true, true, false)

      described_class.cleanup_and_resume(client, deadline: Time.now + 5)

      expect(client).to have_received(:send_command_no_wait)
        .with("c", force: true).at_least(:twice)
    end

    it "limits stale pause retries" do
      allow(client).to receive(:send_command).and_return("")
      allow(client).to receive(:paused).and_return(true)

      described_class.cleanup_and_resume(client, deadline: Time.now + 5, max_stale_retries: 2)

      # 1 initial c + at most 2 retries = at most 3
      expect(client).to have_received(:send_command_no_wait)
        .with("c", force: true).at_most(3).times
    end
  end

  describe ".delete_all_breakpoints" do
    it "deletes each breakpoint by number" do
      bp_output = "#0  BP - Line  app.rb:5\n#1  BP - Method  User#save\n"
      allow(client).to receive(:send_command)
        .with("info breakpoints", timeout: anything).and_return(bp_output)
      allow(client).to receive(:send_command)
        .with("delete 0", timeout: anything).and_return("")
      allow(client).to receive(:send_command)
        .with("delete 1", timeout: anything).and_return("")

      described_class.delete_all_breakpoints(client, Time.now + 5)

      expect(client).to have_received(:send_command).with("delete 0", timeout: anything)
      expect(client).to have_received(:send_command).with("delete 1", timeout: anything)
    end

    it "handles empty breakpoint list" do
      allow(client).to receive(:send_command)
        .with("info breakpoints", timeout: anything).and_return("")

      described_class.delete_all_breakpoints(client, Time.now + 5)

      expect(client).not_to have_received(:send_command).with(/\Adelete/, anything)
    end

    it "skips when deadline has passed" do
      described_class.delete_all_breakpoints(client, Time.now - 1)

      expect(client).not_to have_received(:send_command)
    end
  end
end
