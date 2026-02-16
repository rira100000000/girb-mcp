# frozen_string_literal: true

require "tempfile"

RSpec.describe GirbMcp::Tools::ReadFile do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    let(:tmpfile) do
      file = Tempfile.new(["test", ".rb"])
      file.write((1..10).map { |i| "line #{i}\n" }.join)
      file.flush
      file
    end

    after { tmpfile.close! }

    it "reads entire file" do
      response = described_class.call(path: tmpfile.path, server_context: server_context)
      text = response_text(response)
      expect(text).to include("10 lines")
      expect(text).to include("1: line 1")
      expect(text).to include("10: line 10")
    end

    it "reads a specific line range" do
      response = described_class.call(
        path: tmpfile.path,
        start_line: 3,
        end_line: 5,
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("lines 3-5")
      expect(text).to include("3: line 3")
      expect(text).to include("5: line 5")
      expect(text).not_to include("1: line 1")
    end

    it "returns error for non-existent file" do
      response = described_class.call(
        path: "/nonexistent/file.rb",
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("Error: File not found")
    end

    it "truncates files exceeding MAX_LINES" do
      # Create a file with more than MAX_LINES lines
      big_file = Tempfile.new(["big", ".rb"])
      big_file.write((1..600).map { |i| "line #{i}\n" }.join)
      big_file.flush

      response = described_class.call(path: big_file.path, server_context: server_context)
      text = response_text(response)
      expect(text).to include("truncated")
      expect(text).to include("lines 1-500")

      big_file.close!
    end

    it "clamps start_line to 0" do
      response = described_class.call(
        path: tmpfile.path,
        start_line: -5,
        end_line: 3,
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("1: line 1")
    end

    context "relative path resolution" do
      it "resolves relative paths against debug session working directory" do
        # Create a file in a known directory
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), "puts 'hello'\n")

        allow(client).to receive(:send_command)
          .with("p Dir.pwd")
          .and_return("=> \"#{dir}\"")

        response = described_class.call(path: "app.rb", server_context: server_context)
        text = response_text(response)

        expect(text).to include("puts 'hello'")
        expect(text).to include(dir)
      ensure
        FileUtils.rm_rf(dir)
      end

      it "falls back to local CWD when no debug session" do
        allow(manager).to receive(:client)
          .and_raise(GirbMcp::SessionError, "No active session")

        response = described_class.call(
          path: "/nonexistent/relative.rb",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("Error: File not found")
      end

      it "uses absolute paths as-is" do
        response = described_class.call(path: tmpfile.path, server_context: server_context)
        text = response_text(response)
        expect(text).to include("10 lines")
        # Should NOT call Dir.pwd for absolute paths
        expect(client).not_to have_received(:send_command).with("p Dir.pwd")
      end
    end
  end

  describe "MAX_LINES" do
    it "is 500" do
      expect(GirbMcp::Tools::ReadFile::MAX_LINES).to eq(500)
    end
  end
end
