# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::RemoveBreakpoint do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  let(:bp_list) do
    <<~BP
      #1  BP - Line  file.rb:10 (line)
      #2  BP - Method  User#save (call)
      #3  BP - Catch  "NoMethodError"
    BP
  end

  describe ".call" do
    context "by breakpoint number" do
      it "deletes by number" do
        allow(client).to receive(:send_command).with("delete 2").and_return("")

        response = described_class.call(
          breakpoint_number: 2,
          server_context: server_context,
        )
        expect(client).to have_received(:send_command).with("delete 2")
      end
    end

    context "by file and line" do
      it "finds and removes matching breakpoint" do
        allow(client).to receive(:send_command).with("info breakpoints").and_return(bp_list)
        allow(client).to receive(:send_command).with("delete 1").and_return("")

        response = described_class.call(
          file: "file.rb", line: 10,
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("Deleted breakpoint #1")
        expect(text).to include("file.rb:10")
      end

      it "reports when no matching breakpoint found" do
        allow(client).to receive(:send_command).with("info breakpoints").and_return(bp_list)

        response = described_class.call(
          file: "other.rb", line: 99,
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("No breakpoint found")
      end

      it "removes breakpoint specs from manager" do
        allow(client).to receive(:send_command).with("info breakpoints").and_return(bp_list)
        allow(client).to receive(:send_command).with("delete 1").and_return("")
        expect(manager).to receive(:remove_breakpoint_specs_matching).with("file.rb:10")

        described_class.call(file: "file.rb", line: 10, server_context: server_context)
      end
    end

    context "by method" do
      it "finds and removes method breakpoint" do
        allow(client).to receive(:send_command).with("info breakpoints").and_return(bp_list)
        allow(client).to receive(:send_command).with("delete 2").and_return("")

        response = described_class.call(
          method: "User#save",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("Deleted method breakpoint #2")
      end

      it "reports when no matching method breakpoint found" do
        allow(client).to receive(:send_command).with("info breakpoints").and_return(bp_list)

        response = described_class.call(
          method: "Order#cancel",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("No method breakpoint found")
      end
    end

    context "by exception class" do
      it "finds and removes catch breakpoint" do
        allow(client).to receive(:send_command).with("info breakpoints").and_return(bp_list)
        allow(client).to receive(:send_command).with("delete 3").and_return("")

        response = described_class.call(
          exception_class: "NoMethodError",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("Deleted catch breakpoint #3")
      end

      it "removes catch breakpoint specs from manager" do
        allow(client).to receive(:send_command).with("info breakpoints").and_return(bp_list)
        allow(client).to receive(:send_command).with("delete 3").and_return("")
        expect(manager).to receive(:remove_breakpoint_specs_matching).with("catch NoMethodError")

        described_class.call(exception_class: "NoMethodError", server_context: server_context)
      end
    end

    context "invalid parameters" do
      it "returns error when no valid parameters" do
        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("Error:")
        expect(text).to include("Provide")
      end
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(
        breakpoint_number: 1,
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("Error: No session")
    end
  end
end
