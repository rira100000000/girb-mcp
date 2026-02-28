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

    context "mutation operations" do
      it "detects .save!" do
        warnings = described_class.analyze("user.save!")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:category]).to eq(:mutation_operations)
        expect(warnings.first[:matches]).to include(".save!")
      end

      it "detects .save (without ?)" do
        warnings = described_class.analyze("user.save")
        expect(warnings.length).to eq(1)
        expect(warnings.first[:matches]).to include(".save")
      end

      it "does not flag .save?" do
        warnings = described_class.analyze("user.save?")
        mutation_warnings = warnings.select { |w| w[:category] == :mutation_operations }
        expect(mutation_warnings).to be_empty
      end

      it "detects .update!" do
        warnings = described_class.analyze("user.update!(name: 'test')")
        expect(warnings.first[:category]).to eq(:mutation_operations)
        expect(warnings.first[:matches]).to include(".update!")
      end

      it "detects .update()" do
        warnings = described_class.analyze("user.update(name: 'test')")
        expect(warnings.first[:category]).to eq(:mutation_operations)
        expect(warnings.first[:matches]).to include(".update")
      end

      it "detects .update without parentheses" do
        warnings = described_class.analyze("user.update name: 'test'")
        expect(warnings.first[:category]).to eq(:mutation_operations)
        expect(warnings.first[:matches]).to include(".update")
      end

      it "detects .create!" do
        warnings = described_class.analyze("User.create!(name: 'test')")
        expect(warnings.first[:category]).to eq(:mutation_operations)
        expect(warnings.first[:matches]).to include(".create!")
      end

      it "detects .create()" do
        warnings = described_class.analyze("User.create(name: 'test')")
        expect(warnings.first[:category]).to eq(:mutation_operations)
        expect(warnings.first[:matches]).to include(".create")
      end

      it "detects .create without parentheses" do
        warnings = described_class.analyze("User.create name: 'test'")
        expect(warnings.first[:category]).to eq(:mutation_operations)
        expect(warnings.first[:matches]).to include(".create")
      end

      it "detects .destroy (without _all)" do
        warnings = described_class.analyze("user.destroy")
        expect(warnings.first[:category]).to eq(:mutation_operations)
        expect(warnings.first[:matches]).to include(".destroy")
      end

      it "does not flag .destroy_all as mutation (separate category)" do
        warnings = described_class.analyze("User.destroy_all")
        categories = warnings.map { |w| w[:category] }
        expect(categories).to include(:destructive_data)
        # destroy_all should NOT also match .destroy in mutation_operations
        mutation = warnings.find { |w| w[:category] == :mutation_operations }
        expect(mutation).to be_nil
      end

      it "detects .touch" do
        warnings = described_class.analyze("user.touch")
        expect(warnings.first[:matches]).to include(".touch")
      end

      it "detects .increment!" do
        warnings = described_class.analyze("counter.increment!")
        expect(warnings.first[:matches]).to include(".increment!")
      end

      it "detects .decrement!" do
        warnings = described_class.analyze("counter.decrement!")
        expect(warnings.first[:matches]).to include(".decrement!")
      end

      it "detects .toggle!" do
        warnings = described_class.analyze("user.toggle!(:active)")
        expect(warnings.first[:matches]).to include(".toggle!")
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

    context "mutation-only compact format" do
      it "uses compact Note format for single mutation match" do
        warnings = [{ category: :mutation_operations, matches: [".save!"] }]
        result = described_class.format_warnings(warnings)

        expect(result).to start_with("Note:")
        expect(result).to include("Data mutation detected (.save!)")
        expect(result).to include("acknowledge_mutations")
        expect(result).not_to include("WARNING:")
      end

      it "lists all matches in compact format for multiple mutation matches" do
        warnings = [{ category: :mutation_operations, matches: [".save!", ".update"] }]
        result = described_class.format_warnings(warnings)

        expect(result).to start_with("Note:")
        expect(result).to include(".save!, .update")
        expect(result).not_to include("WARNING:")
      end

      it "uses verbose WARNING format when mutation is mixed with other categories" do
        warnings = [
          { category: :mutation_operations, matches: [".save!"] },
          { category: :system_commands, matches: ["system()"] },
        ]
        result = described_class.format_warnings(warnings)

        expect(result).to include("WARNING:")
        expect(result).to include("Data mutation")
        expect(result).to include("System command execution")
        expect(result).not_to start_with("Note:")
      end
    end
  end

  describe ".filter_acknowledged" do
    it "removes acknowledged categories" do
      warnings = [
        { category: :mutation_operations, matches: [".save!"] },
        { category: :file_operations, matches: ["File.write/delete/unlink/rename"] },
      ]
      filtered = described_class.filter_acknowledged(warnings, Set[:mutation_operations])

      expect(filtered.size).to eq(1)
      expect(filtered.first[:category]).to eq(:file_operations)
    end

    it "returns all warnings when nothing is acknowledged" do
      warnings = [{ category: :mutation_operations, matches: [".save!"] }]
      expect(described_class.filter_acknowledged(warnings, Set.new)).to eq(warnings)
    end

    it "returns all warnings when acknowledged_categories is nil" do
      warnings = [{ category: :mutation_operations, matches: [".save!"] }]
      expect(described_class.filter_acknowledged(warnings, nil)).to eq(warnings)
    end
  end
end
