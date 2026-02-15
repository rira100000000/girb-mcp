# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::GetContext do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    before do
      allow(client).to receive(:send_command).with("list").and_return("=> 1| x = 1")
      allow(client).to receive(:send_command).with("info locals").and_return("x = 1")
      allow(client).to receive(:send_command).with("info ivars").and_return("@name = \"Alice\"")
      allow(client).to receive(:send_command).with("bt").and_return("#0 main at file.rb:1")
      allow(client).to receive(:send_command).with("info breakpoints").and_return("No breakpoints")
      allow(client).to receive(:send_command).with("p __return_value__").and_return("=> NameError")
    end

    it "returns all context sections" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("=== Current Location ===")
      expect(text).to include("=== Local Variables ===")
      expect(text).to include("=== Instance Variables ===")
      expect(text).to include("=== Call Stack ===")
      expect(text).to include("=== Breakpoints ===")
    end

    it "includes tip about inspect tools" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("evaluate_code")
      expect(text).to include("inspect_object")
    end

    it "annotates truncated values" do
      allow(client).to receive(:send_command).with("info locals").and_return(
        "long_var = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, ...]"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("[truncated]")
      expect(text).to include("1 truncated")
    end

    it "shows return value when available" do
      allow(client).to receive(:send_command).with("p __return_value__").and_return("=> 42")

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Return Value")
      expect(text).to include("42")
      expect(text).to include("ALREADY been executed")
    end

    it "shows exception context with return value" do
      allow(client).to receive(:send_command).with("p __return_value__").and_return("=> nil")
      allow(client).to receive(:check_current_exception).and_return("RuntimeError: boom")

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Exception in scope: RuntimeError: boom")
    end

    it "handles timeout on individual sections" do
      allow(client).to receive(:send_command).with("bt").and_raise(
        GirbMcp::TimeoutError, "timeout"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("=== Call Stack ===")
      expect(text).to include("(timed out)")
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end
  end

  describe "TRUNCATION_PATTERN" do
    it "matches truncated arrays" do
      expect("x = [1, 2, 3, ...]").to match(GirbMcp::Tools::GetContext::TRUNCATION_PATTERN)
    end

    it "matches truncated hashes" do
      expect('x = {"a"=>1, "b"=>2, ...}').to match(GirbMcp::Tools::GetContext::TRUNCATION_PATTERN)
    end

    it "matches truncated strings" do
      expect('x = "very long string..."').to match(GirbMcp::Tools::GetContext::TRUNCATION_PATTERN)
    end

    it "does not match non-truncated values" do
      expect("x = [1, 2, 3]").not_to match(GirbMcp::Tools::GetContext::TRUNCATION_PATTERN)
    end
  end
end
