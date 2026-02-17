# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::RunScript do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "returns error when file not found" do
      response = described_class.call(
        file: "/nonexistent/script.rb",
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("Error: File not found")
    end

    it "returns error when rdbg not available" do
      allow(File).to receive(:exist?).and_return(true)
      allow_any_instance_of(Object).to receive(:system)
        .with("which rdbg > /dev/null 2>&1")
        .and_return(false)

      response = described_class.call(file: "test.rb", server_context: server_context)
      text = response_text(response)
      expect(text).to include("rdbg")
      expect(text).to include("not found")
    end

    it "clears breakpoint specs by default" do
      allow(File).to receive(:exist?).and_return(false)
      expect(manager).to receive(:clear_breakpoint_specs)

      described_class.call(file: "/nonexistent.rb", server_context: server_context)
    end

    it "does not clear specs when restore_breakpoints is true" do
      allow(File).to receive(:exist?).and_return(false)
      expect(manager).not_to receive(:clear_breakpoint_specs)

      described_class.call(
        file: "/nonexistent.rb",
        restore_breakpoints: true,
        server_context: server_context,
      )
    end

    it "clears specs when explicit breakpoints are provided even with restore" do
      allow(File).to receive(:exist?).and_return(false)
      expect(manager).to receive(:clear_breakpoint_specs)

      described_class.call(
        file: "/nonexistent.rb",
        breakpoints: ["User#save"],
        restore_breakpoints: true,
        server_context: server_context,
      )
    end
  end

  describe "skip_internal_code" do
    let(:client) { build_mock_client }

    it "skips multiple consecutive internal code stops" do
      # Simulate: stop at bundled_gems.rb → continue → stop at rubygems/ → continue → stop at user code
      call_count = 0
      allow(client).to receive(:send_continue) do
        call_count += 1
        case call_count
        when 1 then "stopped at /path/rubygems/core.rb:5"
        when 2 then "stopped at app/models/user.rb:10"
        end
      end

      output, skipped = described_class.send(:skip_internal_code, client, "stopped at /path/bundled_gems.rb:1")
      expect(skipped).to be true
      expect(call_count).to eq(2)
      expect(output).to include("app/models/user.rb")
    end

    it "does not skip user code" do
      output, skipped = described_class.send(:skip_internal_code, client, "stopped at app/models/user.rb:10")
      expect(skipped).to be false
      expect(client).not_to have_received(:send_continue)
    end

    it "returns after MAX_SKIP_ATTEMPTS even if still internal" do
      allow(client).to receive(:send_continue).and_return("stopped at /path/bundled_gems.rb:99")

      output, skipped = described_class.send(:skip_internal_code, client, "stopped at /path/bundled_gems.rb:1")
      expect(skipped).to be true
      expect(client).to have_received(:send_continue).exactly(5).times
    end
  end
end
