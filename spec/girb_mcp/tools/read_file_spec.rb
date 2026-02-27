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

      it "shows helpful error for relative path with no session" do
        allow(manager).to receive(:client)
          .and_raise(GirbMcp::SessionError, "No active session")

        response = described_class.call(
          path: "app/models/user.rb",
          server_context: server_context,
        )
        text = response_text(response)
        expect(text).to include("no active debug session")
        expect(text).to include("absolute path")
      end

      it "uses absolute paths as-is" do
        response = described_class.call(path: tmpfile.path, server_context: server_context)
        text = response_text(response)
        expect(text).to include("10 lines")
        # Should NOT call Dir.pwd for absolute paths
        expect(client).not_to have_received(:send_command).with("p Dir.pwd")
      end
    end

    context "remote file reading (Docker/TCP)" do
      let(:remote_client) { build_mock_client(remote: true) }
      let(:remote_manager) { build_mock_manager(client: remote_client) }
      let(:remote_context) { { session_manager: remote_manager } }

      it "reads file via debug session for remote connections" do
        allow(remote_client).to receive(:send_command)
          .with("p File.exist?(\"/app/test.rb\")")
          .and_return('=> "true"')
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/test.rb\").size")
          .and_return("=> 3")
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/test.rb\")[0..2].join")
          .and_return("=> \"line 1\\nline 2\\nline 3\\n\"")

        response = described_class.call(path: "/app/test.rb", server_context: remote_context)
        text = response_text(response)

        expect(text).to include("[remote]")
        expect(text).to include("3 lines")
        expect(text).to include("1: line 1")
        expect(text).to include("3: line 3")
      end

      it "returns error when remote file not found" do
        allow(remote_client).to receive(:send_command)
          .with("p File.exist?(\"/app/missing.rb\")")
          .and_return('=> "false"')

        response = described_class.call(path: "/app/missing.rb", server_context: remote_context)
        text = response_text(response)

        expect(text).to include("Error: File not found on remote process")
        expect(text).to include("/app/missing.rb")
      end

      it "reads specific line range from remote file" do
        allow(remote_client).to receive(:send_command)
          .with("p File.exist?(\"/app/test.rb\")")
          .and_return('=> "true"')
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/test.rb\").size")
          .and_return("=> 10")
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/test.rb\")[2..4].join")
          .and_return("=> \"line 3\\nline 4\\nline 5\\n\"")

        response = described_class.call(
          path: "/app/test.rb",
          start_line: 3,
          end_line: 5,
          server_context: remote_context,
        )
        text = response_text(response)

        expect(text).to include("[remote]")
        expect(text).to include("lines 3-5 of 10")
        expect(text).to include("3: line 3")
        expect(text).to include("5: line 5")
      end

      it "resolves relative paths via remote cwd" do
        allow(remote_client).to receive(:send_command)
          .with("p Dir.pwd")
          .and_return('=> "/app"')
        allow(remote_client).to receive(:send_command)
          .with("p File.exist?(\"/app/config/routes.rb\")")
          .and_return('=> "true"')
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/config/routes.rb\").size")
          .and_return("=> 1")
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/config/routes.rb\")[0..0].join")
          .and_return("=> \"routes\\n\"")

        response = described_class.call(path: "config/routes.rb", server_context: remote_context)
        text = response_text(response)

        expect(text).to include("[remote]")
        expect(text).to include("/app/config/routes.rb")
      end

      it "returns error when line count query fails" do
        allow(remote_client).to receive(:send_command)
          .with("p File.exist?(\"/app/test.rb\")")
          .and_return('=> "true"')
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/test.rb\").size")
          .and_return("=> nil")

        response = described_class.call(path: "/app/test.rb", server_context: remote_context)
        text = response_text(response)

        expect(text).to include("Error reading remote file")
        expect(text).to include("failed to get line count")
      end

      it "fetches file in multiple chunks when exceeding REMOTE_CHUNK_SIZE" do
        # 80 lines > REMOTE_CHUNK_SIZE(50), so needs 2 chunks: [0..49] and [50..79]
        allow(remote_client).to receive(:send_command)
          .with("p File.exist?(\"/app/big.rb\")")
          .and_return('=> "true"')
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/big.rb\").size")
          .and_return("=> 80")
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/big.rb\")[0..49].join")
          .and_return("=> \"#{(1..50).map { |i| "line #{i}\\n" }.join}\"")
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/big.rb\")[50..79].join")
          .and_return("=> \"#{(51..80).map { |i| "line #{i}\\n" }.join}\"")

        response = described_class.call(path: "/app/big.rb", server_context: remote_context)
        text = response_text(response)

        expect(text).to include("80 lines")
        expect(text).to include("1: line 1")
        expect(text).to include("50: line 50")
        expect(text).to include("51: line 51")
        expect(text).to include("80: line 80")
      end

      it "returns partial result when chunk fetch returns nil mid-way" do
        allow(remote_client).to receive(:send_command)
          .with("p File.exist?(\"/app/partial.rb\")")
          .and_return('=> "true"')
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/partial.rb\").size")
          .and_return("=> 80")
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/partial.rb\")[0..49].join")
          .and_return("=> \"#{(1..50).map { |i| "line #{i}\\n" }.join}\"")
        allow(remote_client).to receive(:send_command)
          .with("p File.readlines(\"/app/partial.rb\")[50..79].join")
          .and_return("=> nil")

        response = described_class.call(path: "/app/partial.rb", server_context: remote_context)
        text = response_text(response)

        # Should return the 50 lines from the first chunk with partial warning
        expect(text).to include("1: line 1")
        expect(text).to include("50: line 50")
        expect(text).not_to include("51: line 51")
        expect(text).to include("partial: fetch failed after line 50")
      end

      it "falls back to local reading for non-remote connections" do
        response = described_class.call(path: tmpfile.path, server_context: server_context)
        text = response_text(response)

        expect(text).not_to include("[remote]")
        expect(text).to include("10 lines")
      end
    end
  end

  describe "MAX_LINES" do
    it "is 500" do
      expect(GirbMcp::Tools::ReadFile::MAX_LINES).to eq(500)
    end
  end
end
