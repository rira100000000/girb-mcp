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
      # After first ensure_paused, process is no longer paused (normal resume)
      allow(client).to receive(:paused).and_return(true, true, false)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
      expect(text).to include("Disconnected from session")
    end

    it "deletes all breakpoints before continuing for connect sessions" do
      bp_output = "#0  BP - Line  app/controllers/users_controller.rb:10\n" \
                  "#1  BP - Line  app/models/user.rb:20\n"
      allow(client).to receive(:send_command).with("info breakpoints", timeout: anything).and_return(bp_output)
      allow(client).to receive(:send_command).with("delete 0", timeout: anything).and_return("")
      allow(client).to receive(:send_command).with("delete 1", timeout: anything).and_return("")
      allow(client).to receive(:paused).and_return(true, true, false)

      described_class.call(server_context: server_context)

      expect(client).to have_received(:send_command).with("info breakpoints", timeout: anything)
      expect(client).to have_received(:send_command).with("delete 0", timeout: anything)
      expect(client).to have_received(:send_command).with("delete 1", timeout: anything)
      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
    end

    it "skips BP deletion when no breakpoints are set" do
      allow(client).to receive(:send_command).and_return("")
      allow(client).to receive(:paused).and_return(true, true, false)

      described_class.call(server_context: server_context)

      expect(client).not_to have_received(:send_command).with(/\Adelete/, anything)
      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
    end

    it "continues even when BP deletion fails" do
      allow(client).to receive(:send_command).with("info breakpoints", timeout: anything).and_raise(
        GirbMcp::ConnectionError, "lost"
      )
      allow(client).to receive(:paused).and_return(true, true, false)

      described_class.call(server_context: server_context)

      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
    end

    it "tries repause then interrupt_and_wait when process is not paused" do
      allow(client).to receive(:paused).and_return(false, false, true, false)
      allow(client).to receive(:repause).with(timeout: 3).and_raise(GirbMcp::TimeoutError, "timeout")
      allow(client).to receive(:interrupt_and_wait).with(timeout: 3).and_return("")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(client).to have_received(:repause).with(timeout: 3)
      expect(client).to have_received(:interrupt_and_wait).with(timeout: 3)
      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
      expect(text).to include("Disconnected from session")
    end

    it "uses repause to re-pause remote client without interrupt_and_wait" do
      allow(client).to receive(:paused).and_return(false, true, true, false)
      allow(client).to receive(:repause).with(timeout: 3).and_return("")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(client).to have_received(:repause).with(timeout: 3)
      expect(client).not_to have_received(:interrupt_and_wait)
      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
      expect(text).to include("Disconnected from session")
    end

    it "auto-escalates with warning and sends resume when both repause and interrupt fail" do
      allow(client).to receive(:paused).and_return(false)
      allow(client).to receive(:repause).and_raise(GirbMcp::TimeoutError, "timeout")
      allow(client).to receive(:interrupt_and_wait).and_raise(GirbMcp::ConnectionError, "lost")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Disconnected from session")
      expect(text).to include("WARNING:")
      expect(text).to match(/could not re-pause/i)
      expect(text).to include("resume command was sent")
      expect(client).not_to have_received(:send_command)
      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
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

    context "force disconnect" do
      it "skips cleanup and disconnects immediately for connect sessions" do
        response = described_class.call(force: true, server_context: server_context)
        text = response_text(response)

        expect(text).to include("Force-disconnected")
        expect(text).to include("cleanup skipped")
        expect(text).to include("Breakpoints were NOT removed")
        expect(text).to include("paused state")
        expect(client).not_to have_received(:send_command)
        expect(client).not_to have_received(:send_command_no_wait)
        expect(manager).to have_received(:disconnect)
      end

      it "kills process for run_script sessions even in force mode" do
        wait_thread = instance_double(Thread, alive?: true)
        allow(client).to receive(:wait_thread).and_return(wait_thread)
        allow(client).to receive(:pid).and_return("999")
        allow(Process).to receive(:kill)

        response = described_class.call(force: true, server_context: server_context)
        text = response_text(response)

        expect(Process).to have_received(:kill).with("TERM", 999)
        expect(text).to include("Force-disconnected")
        expect(text).to include("Process 999 terminated")
      end

      it "warns when run_script process kill fails" do
        wait_thread = instance_double(Thread, alive?: true)
        allow(client).to receive(:wait_thread).and_return(wait_thread)
        allow(client).to receive(:pid).and_return("999")
        allow(Process).to receive(:kill).and_raise(Errno::ESRCH)

        response = described_class.call(force: true, server_context: server_context)
        text = response_text(response)

        expect(text).to include("Force-disconnected")
        expect(text).to include("NOT terminated")
        expect(text).not_to include("paused state")
      end
    end

    it "tries additional repause for remote client when initial repause and interrupt fail" do
      allow(client).to receive(:remote).and_return(true)
      allow(client).to receive(:paused).and_return(false, false, false, true, false)
      allow(client).to receive(:listen_ports).and_return([])
      allow(client).to receive(:repause).with(timeout: 3).and_return(nil)
      allow(client).to receive(:interrupt_and_wait).with(timeout: 3).and_return(nil)
      allow(client).to receive(:repause).with(timeout: 5).and_return("")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(client).to have_received(:repause).with(timeout: 5)
      expect(text).to include("Disconnected from session")
      expect(text).not_to include("WARNING")
    end

    it "tries HTTP wake + repause for remote client with listen_ports" do
      allow(client).to receive(:remote).and_return(true)
      allow(client).to receive(:listen_ports).and_return([3000])
      allow(client).to receive(:paused).and_return(false, false, false, true, false)
      allow(client).to receive(:repause).with(timeout: 3).and_return(nil)
      allow(client).to receive(:interrupt_and_wait).with(timeout: 3).and_return(nil)
      allow(client).to receive(:wake_io_blocked_process).and_return(Thread.new {})
      allow(client).to receive(:repause).with(timeout: 5).and_return("")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(client).to have_received(:wake_io_blocked_process).with(3000)
      expect(client).to have_received(:repause).with(timeout: 5)
      expect(text).to include("Disconnected from session")
      expect(text).not_to include("WARNING")
    end

    context "stale pause defense" do
      it "retries c when process is re-paused after best_effort_cleanup" do
        # First ensure_paused returns "" and leaves paused=true (stale pause),
        # second ensure_paused returns "" and leaves paused=false (normal exit)
        pause_call_count = 0
        allow(client).to receive(:ensure_paused) do |timeout:|
          pause_call_count += 1
          ""
        end

        # Simulate: paused=true initially, then paused after first c+ensure,
        # then not paused after retry c+ensure
        paused_values = [true, true, true, true, true, false]
        call_index = 0
        allow(client).to receive(:paused) do
          val = paused_values[[call_index, paused_values.size - 1].min]
          call_index += 1
          val
        end

        allow(client).to receive(:send_command).and_return("")

        described_class.call(server_context: server_context)

        # send_command_no_wait("c") should be called twice:
        # once in best_effort_cleanup, once in stale pause retry
        expect(client).to have_received(:send_command_no_wait).with("c", force: true).at_least(:twice)
      end

      it "limits stale pause retries to MAX_STALE_PAUSE_RETRIES" do
        # Process stays paused forever (stale pause keeps happening)
        allow(client).to receive(:paused).and_return(true)
        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:send_command).and_return("")

        described_class.call(server_context: server_context)

        # Should not loop infinitely — bounded by MAX_STALE_PAUSE_RETRIES (2)
        # 1 initial c + at most 2 retries = at most 3
        expect(client).to have_received(:send_command_no_wait)
          .with("c", force: true).at_most(3).times
      end
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
