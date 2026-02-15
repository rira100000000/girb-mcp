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

  # INTERNAL_CODE_PATTERNS and MAX_SKIP_ATTEMPTS are private singleton-class
  # constants, so we test the behaviour they drive via skip_internal_code
  # rather than referencing them directly.
end
