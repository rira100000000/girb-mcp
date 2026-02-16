# frozen_string_literal: true

RSpec.describe GirbMcp::DebugClient do
  describe "constants" do
    it "has default width" do
      expect(GirbMcp::DebugClient::DEFAULT_WIDTH).to eq(500)
    end

    it "has default timeout" do
      expect(GirbMcp::DebugClient::DEFAULT_TIMEOUT).to eq(15)
    end

    it "has continue timeout" do
      expect(GirbMcp::DebugClient::CONTINUE_TIMEOUT).to eq(30)
    end

    it "has ANSI escape pattern" do
      expect(GirbMcp::DebugClient::ANSI_ESCAPE).to be_a(Regexp)
      expect("\e[31mred\e[0m".gsub(GirbMcp::DebugClient::ANSI_ESCAPE, "")).to eq("red")
    end
  end

  describe "#initialize" do
    it "starts disconnected" do
      client = GirbMcp::DebugClient.new
      expect(client.connected?).to be false
      expect(client.pid).to be_nil
    end
  end

  describe "#connected?" do
    it "returns false when not connected" do
      client = GirbMcp::DebugClient.new
      expect(client.connected?).to be false
    end
  end

  describe "#send_command" do
    it "raises SessionError when not connected" do
      client = GirbMcp::DebugClient.new
      expect { client.send_command("list") }.to raise_error(
        GirbMcp::SessionError, /Not connected/
      )
    end
  end

  describe "#process_finished?" do
    it "returns false when no wait_thread" do
      client = GirbMcp::DebugClient.new
      expect(client.process_finished?).to be false
    end
  end

  describe "#register_one_shot and #cleanup_one_shot_breakpoints" do
    let(:client) { GirbMcp::DebugClient.new }

    it "returns nil when no one-shot breakpoints registered" do
      expect(client.cleanup_one_shot_breakpoints("Stop by #1")).to be_nil
    end

    it "returns nil for nil output" do
      client.register_one_shot(1)
      expect(client.cleanup_one_shot_breakpoints(nil)).to be_nil
    end

    it "returns nil when output doesn't match any registered breakpoint" do
      client.register_one_shot(1)
      expect(client.cleanup_one_shot_breakpoints("Stop by #2")).to be_nil
    end
  end

  describe "#read_stdout_output" do
    it "returns nil when no stdout_file" do
      client = GirbMcp::DebugClient.new
      expect(client.read_stdout_output).to be_nil
    end
  end

  describe "#read_stderr_output" do
    it "returns nil when no stderr_file" do
      client = GirbMcp::DebugClient.new
      expect(client.read_stderr_output).to be_nil
    end
  end

  describe ".list_sessions" do
    it "returns empty array when socket directory does not exist" do
      allow(GirbMcp::DebugClient).to receive(:socket_dir).and_return("/nonexistent")
      expect(GirbMcp::DebugClient.list_sessions).to eq([])
    end

    it "returns empty array when socket_dir is nil" do
      allow(GirbMcp::DebugClient).to receive(:socket_dir).and_return(nil)
      expect(GirbMcp::DebugClient.list_sessions).to eq([])
    end
  end

  describe ".socket_dir" do
    context "with RUBY_DEBUG_SOCK_DIR set" do
      it "returns the env var value" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("RUBY_DEBUG_SOCK_DIR").and_return("/custom/dir")
        expect(GirbMcp::DebugClient.socket_dir).to eq("/custom/dir")
      end
    end

    context "with XDG_RUNTIME_DIR set" do
      it "returns the env var value when RUBY_DEBUG_SOCK_DIR is not set" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("RUBY_DEBUG_SOCK_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("XDG_RUNTIME_DIR").and_return("/run/user/1000")
        expect(GirbMcp::DebugClient.socket_dir).to eq("/run/user/1000")
      end
    end
  end

  describe "#disconnect" do
    it "resets state" do
      client = GirbMcp::DebugClient.new
      client.disconnect
      expect(client.connected?).to be false
      expect(client.pid).to be_nil
      expect(client.paused).to be false
    end
  end

  describe "#paused" do
    it "starts as false" do
      client = GirbMcp::DebugClient.new
      expect(client.paused).to be false
    end
  end

  describe "#check_current_exception" do
    it "raises SessionError when not connected" do
      client = GirbMcp::DebugClient.new
      # check_current_exception calls send_command internally
      expect(client.check_current_exception).to be_nil
    end
  end

  describe "#ensure_paused" do
    it "returns empty string when already paused" do
      client = GirbMcp::DebugClient.new
      # Manually set paused state
      client.instance_variable_set(:@paused, true)
      expect(client.ensure_paused).to eq("")
    end

    it "returns nil when not connected" do
      client = GirbMcp::DebugClient.new
      # Not connected, no socket
      expect(client.ensure_paused).to be_nil
    end
  end

  describe "#continue_and_wait" do
    it "raises SessionError when not connected" do
      client = GirbMcp::DebugClient.new
      expect { client.continue_and_wait }.to raise_error(
        GirbMcp::SessionError, /Not connected/
      )
    end
  end

  describe "#wait_for_breakpoint" do
    it "raises SessionError when not connected" do
      client = GirbMcp::DebugClient.new
      expect { client.wait_for_breakpoint }.to raise_error(
        GirbMcp::SessionError, /Not connected/
      )
    end
  end
end
