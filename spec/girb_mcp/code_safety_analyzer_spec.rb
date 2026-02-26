# frozen_string_literal: true

RSpec.describe GirbMcp::CodeSafetyAnalyzer do
  describe ".analyze" do
    context "safe code" do
      it "returns empty array for simple expressions" do
        expect(described_class.analyze("user.name")).to eq([])
      end

      it "returns empty array for ActiveRecord queries" do
        expect(described_class.analyze("Order.where(status: :pending).count")).to eq([])
      end

      it "returns empty array for variable inspection" do
        expect(described_class.analyze("local_variables")).to eq([])
      end

      it "allows File.read (read-only operation)" do
        expect(described_class.analyze("File.read('config.yml')")).to eq([])
      end

      it "allows File.exist? (read-only operation)" do
        expect(described_class.analyze("File.exist?('/tmp/test')")).to eq([])
      end
    end

    context "file operations" do
      it "detects File.write" do
        warnings = described_class.analyze("File.write('/tmp/test', 'data')")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:category]).to eq(:file_operations)
        expect(warnings.first[:matches]).to include("File.write/delete/unlink/rename")
      end

      it "detects File.delete" do
        warnings = described_class.analyze("File.delete('/tmp/test')")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:category]).to eq(:file_operations)
      end

      it "detects FileUtils" do
        warnings = described_class.analyze("FileUtils.rm_rf('/tmp/dir')")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("FileUtils")
      end

      it "detects IO.write" do
        warnings = described_class.analyze("IO.write('/tmp/test', 'data')")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("IO.write")
      end
    end

    context "system commands" do
      it "detects system()" do
        warnings = described_class.analyze('system("ls -la")')
        expect(warnings.length).to eq(1)
        expect(warnings.first[:category]).to eq(:system_commands)
        expect(warnings.first[:matches]).to include("system()")
      end

      it "detects exec()" do
        warnings = described_class.analyze('exec("/bin/sh")')
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("exec()")
      end

      it "detects backtick commands" do
        warnings = described_class.analyze('`whoami`')
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("backtick command")
      end

      it "detects %x{}" do
        warnings = described_class.analyze('%x{ls}')
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("%x{}")
      end

      it "detects Open3" do
        warnings = described_class.analyze('Open3.capture2("ls")')
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("Open3")
      end

      it "detects IO.popen" do
        warnings = described_class.analyze('IO.popen("ls")')
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("IO.popen")
      end

      it "detects spawn()" do
        warnings = described_class.analyze('spawn("ls")')
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("spawn()")
      end
    end

    context "process manipulation" do
      it "detects Process.kill" do
        warnings = described_class.analyze("Process.kill('TERM', pid)")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:category]).to eq(:process_manipulation)
      end

      it "detects exit!" do
        warnings = described_class.analyze("exit!")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("exit!")
      end

      it "detects abort" do
        warnings = described_class.analyze("abort")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("abort")
      end
    end

    context "network operations" do
      it "detects Net::HTTP" do
        warnings = described_class.analyze("Net::HTTP.get(URI('http://example.com'))")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:category]).to eq(:network_operations)
        expect(warnings.first[:matches]).to include("Net::HTTP")
      end

      it "detects TCPSocket" do
        warnings = described_class.analyze("TCPSocket.new('localhost', 80)")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("TCPSocket")
      end

      it "detects Faraday" do
        warnings = described_class.analyze("Faraday.get('http://example.com')")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("Faraday")
      end

      it "detects HTTParty" do
        warnings = described_class.analyze("HTTParty.get('http://example.com')")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("HTTParty")
      end
    end

    context "destructive data operations" do
      it "detects destroy_all" do
        warnings = described_class.analyze("User.destroy_all")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:category]).to eq(:destructive_data)
        expect(warnings.first[:matches]).to include(".destroy_all")
      end

      it "detects delete_all" do
        warnings = described_class.analyze("Order.delete_all")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include(".delete_all")
      end

      it "detects update_all" do
        warnings = described_class.analyze("User.update_all(active: false)")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include(".update_all")
      end

      it "detects DROP TABLE SQL" do
        warnings = described_class.analyze('ActiveRecord::Base.connection.execute("DROP TABLE users")')
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("DROP/TRUNCATE SQL")
      end

      it "detects TRUNCATE TABLE SQL" do
        warnings = described_class.analyze('ActiveRecord::Base.connection.execute("TRUNCATE TABLE orders")')
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include("DROP/TRUNCATE SQL")
      end
    end

    context "multiple categories" do
      it "detects patterns across multiple categories" do
        code = 'system("curl http://example.com"); File.write("/tmp/out", result)'
        warnings = described_class.analyze(code)

        categories = warnings.map { |w| w[:category] }
        expect(categories).to include(:file_operations)
        expect(categories).to include(:system_commands)
      end
    end
  end

  describe ".format_warnings" do
    it "returns nil for empty warnings" do
      expect(described_class.format_warnings([])).to be_nil
    end

    it "formats single category warning" do
      warnings = [{ category: :file_operations, matches: ["File.write/delete/unlink/rename"] }]
      result = described_class.format_warnings(warnings)

      expect(result).to include("WARNING:")
      expect(result).to include("File system operations: File.write/delete/unlink/rename")
      expect(result).to include("evaluate_code should only be used for investigating runtime state")
    end

    it "formats multiple category warnings" do
      warnings = [
        { category: :file_operations, matches: ["File.write/delete/unlink/rename"] },
        { category: :system_commands, matches: ["system()"] },
      ]
      result = described_class.format_warnings(warnings)

      expect(result).to include("File system operations:")
      expect(result).to include("System command execution:")
    end

    it "joins multiple matches with commas" do
      warnings = [{ category: :file_operations, matches: ["File.write/delete/unlink/rename", "FileUtils"] }]
      result = described_class.format_warnings(warnings)

      expect(result).to include("File.write/delete/unlink/rename, FileUtils")
    end
  end
end
