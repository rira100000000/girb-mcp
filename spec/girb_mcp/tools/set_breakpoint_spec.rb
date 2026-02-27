# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::SetBreakpoint do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    context "line breakpoint" do
      it "sets a line breakpoint" do
        allow(client).to receive(:send_command)
          .with("break app/models/user.rb:10")
          .and_return("#1  BP - Line  app/models/user.rb:10 (line)")

        response = described_class.call(
          file: "app/models/user.rb",
          line: 10,
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("BP - Line")
        expect(text).to include("user.rb:10")
      end

      it "sets a conditional breakpoint" do
        allow(client).to receive(:send_command)
          .with("break file.rb:10 if: user.id == 1")
          .and_return("#1  BP - Line  file.rb:10 (line)")

        response = described_class.call(
          file: "file.rb",
          line: 10,
          condition: "user.id == 1",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("BP - Line")
      end

      it "records breakpoint for preservation" do
        allow(client).to receive(:send_command).and_return("#1  BP - Line  f.rb:10 (line)")
        expect(manager).to receive(:record_breakpoint).with("break f.rb:10")

        described_class.call(file: "f.rb", line: 10, server_context: server_context)
      end

      it "does not record one-shot breakpoints" do
        allow(client).to receive(:send_command).and_return("#1  BP - Line  f.rb:10 (line)")
        allow(client).to receive(:register_one_shot)
        expect(manager).not_to receive(:record_breakpoint)

        response = described_class.call(
          file: "f.rb", line: 10, one_shot: true,
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("one-shot")
      end

      it "registers one-shot breakpoint number on client" do
        allow(client).to receive(:send_command).and_return("#3  BP - Line  f.rb:10 (line)")
        expect(client).to receive(:register_one_shot).with(3)

        described_class.call(
          file: "f.rb", line: 10, one_shot: true,
          server_context: server_context,
        )
      end

      it "annotates return event warning" do
        allow(client).to receive(:send_command).and_return("#1  BP - Line  f.rb:10 (return)")

        response = described_class.call(file: "f.rb", line: 10, server_context: server_context)
        text = response_text(response)
        expect(text).to include("WARNING")
      end

      it "annotates call event warning for class/def lines" do
        allow(client).to receive(:send_command).and_return("#1  BP - Line  f.rb:1 (call)")

        response = described_class.call(file: "f.rb", line: 1, server_context: server_context)
        text = response_text(response)
        expect(text).to include("WARNING - Stop event (call)")
        expect(text).to include("method entry event")
      end
    end

    context "method breakpoint" do
      it "sets a method breakpoint" do
        allow(client).to receive(:send_command)
          .with("break User#save")
          .and_return("#1  BP - Method  User#save (call)")

        response = described_class.call(
          method: "User#save",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("BP - Method")
      end

      it "sets a conditional method breakpoint" do
        allow(client).to receive(:send_command)
          .with("break User#save if: user.valid?")
          .and_return("#1  BP - Method  User#save (call)")

        described_class.call(
          method: "User#save",
          condition: "user.valid?",
          server_context: server_context,
        )
      end

      it "records method breakpoint for preservation" do
        allow(client).to receive(:send_command).and_return("#1  BP - Method  User#save (call)")
        expect(manager).to receive(:record_breakpoint).with("break User#save")

        described_class.call(method: "User#save", server_context: server_context)
      end
    end

    context "exception breakpoint" do
      it "sets a catch breakpoint" do
        allow(client).to receive(:send_command)
          .with("catch NoMethodError")
          .and_return('#1  BP - Catch  "NoMethodError"')

        response = described_class.call(
          exception_class: "NoMethodError",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("BP - Catch")
      end

      it "records catch breakpoint" do
        allow(client).to receive(:send_command).and_return('#1  BP - Catch  "NoMethodError"')
        expect(manager).to receive(:record_breakpoint).with("catch NoMethodError")

        described_class.call(
          exception_class: "NoMethodError",
          server_context: server_context,
        )
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
        file: "f.rb", line: 1,
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("Error: No session")
    end

    context "condition syntax validation" do
      it "warns on syntax error in line breakpoint condition" do
        allow(client).to receive(:send_command)
          .with("break file.rb:10 if: user.id ==")
          .and_return("#1  BP - Line  file.rb:10 (line)")
        allow(client).to receive(:send_command)
          .with(/RubyVM::InstructionSequence\.compile/)
          .and_return('=> "syntax error, unexpected end-of-input"')

        response = described_class.call(
          file: "file.rb", line: 10, condition: "user.id ==",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("WARNING")
        expect(text).to include("syntax error")
        expect(text).to include("never fire")
      end

      it "warns on syntax error in method breakpoint condition" do
        allow(client).to receive(:send_command)
          .with("break User#save if: user.id ==")
          .and_return("#1  BP - Method  User#save (call)")
        allow(client).to receive(:send_command)
          .with(/RubyVM::InstructionSequence\.compile/)
          .and_return('=> "syntax error, unexpected end-of-input"')

        response = described_class.call(
          method: "User#save", condition: "user.id ==",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("WARNING")
        expect(text).to include("syntax error")
      end

      it "does not warn when condition is valid" do
        allow(client).to receive(:send_command)
          .with("break file.rb:10 if: user.id == 1")
          .and_return("#1  BP - Line  file.rb:10 (line)")
        allow(client).to receive(:send_command)
          .with(/RubyVM::InstructionSequence\.compile/)
          .and_return("=> nil")

        response = described_class.call(
          file: "file.rb", line: 10, condition: "user.id == 1",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).not_to include("WARNING")
      end

      it "silently ignores validation errors (e.g., trap context)" do
        allow(client).to receive(:send_command)
          .with("break file.rb:10 if: x > 1")
          .and_return("#1  BP - Line  file.rb:10 (line)")
        allow(client).to receive(:send_command)
          .with(/RubyVM::InstructionSequence\.compile/)
          .and_raise(GirbMcp::TimeoutError, "timeout")

        response = described_class.call(
          file: "file.rb", line: 10, condition: "x > 1",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).not_to include("WARNING")
        expect(text).to include("BP - Line")
      end

      it "does not validate when no condition is given" do
        allow(client).to receive(:send_command)
          .with("break file.rb:10")
          .and_return("#1  BP - Line  file.rb:10 (line)")

        response = described_class.call(
          file: "file.rb", line: 10,
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).not_to include("WARNING")
        expect(client).not_to have_received(:send_command).with(/RubyVM::InstructionSequence/)
      end
    end
  end
end
