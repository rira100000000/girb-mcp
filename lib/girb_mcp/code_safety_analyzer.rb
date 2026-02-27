# frozen_string_literal: true

module GirbMcp
  module CodeSafetyAnalyzer
    DANGEROUS_PATTERNS = {
      file_operations: [
        [/\bFile\s*\.\s*(write|delete|unlink|rename|chmod|chown)\b/, "File.write/delete/unlink/rename"],
        [/\bFileUtils\b/, "FileUtils"],
        [/\bIO\s*\.\s*(write|binwrite)\b/, "IO.write"],
        [/\bDir\s*\.\s*(mkdir|rmdir|delete|unlink)\b/, "Dir.mkdir/rmdir"],
      ],
      system_commands: [
        [/\bsystem\s*\(/, "system()"],
        [/\bexec\s*\(/, "exec()"],
        [/\bspawn\s*\(/, "spawn()"],
        [/`[^`]+`/, "backtick command"],
        [/%x\{/, "%x{}"],
        [/%x\[/, "%x[]"],
        [/%x\(/, "%x()"],
        [/\bOpen3\b/, "Open3"],
        [/\bIO\s*\.\s*popen\b/, "IO.popen"],
      ],
      process_manipulation: [
        [/\bProcess\s*\.\s*(kill|fork|exit)\b/, "Process.kill/fork/exit"],
        [/\bfork\s*[\s({]/, "fork"],
        [/\bexit!/, "exit!"],
        [/\babort\b/, "abort"],
      ],
      network_operations: [
        [/\bNet::HTTP\b/, "Net::HTTP"],
        [/\bTCPSocket\b/, "TCPSocket"],
        [/\bUDPSocket\b/, "UDPSocket"],
        [/\bFaraday\b/, "Faraday"],
        [/\bHTTParty\b/, "HTTParty"],
        [/\bopen-uri\b/, "open-uri"],
        [/\bURI\s*\.\s*open\b/, "URI.open"],
        [/\bRestClient\b/, "RestClient"],
      ],
      destructive_data: [
        [/\.destroy_all\b/, ".destroy_all"],
        [/\.delete_all\b/, ".delete_all"],
        [/\.update_all\b/, ".update_all"],
        [/\b(DROP|TRUNCATE)\s+(TABLE|DATABASE)\b/i, "DROP/TRUNCATE SQL"],
      ],
      mutation_operations: [
        [/\.save!/, ".save!"],
        [/\.save\b(?![!?])/, ".save"],
        [/\.update![\s(]/, ".update!"],
        [/\.update[\s(]/, ".update"],
        [/\.create![\s(]/, ".create!"],
        [/\.create[\s(]/, ".create"],
        [/\.destroy!/, ".destroy!"],
        [/\.destroy\b(?![_!])/, ".destroy"],
        [/\.touch\b/, ".touch"],
        [/\.increment!/, ".increment!"],
        [/\.decrement!/, ".decrement!"],
        [/\.toggle!/, ".toggle!"],
      ],
    }.freeze

    # Filter out warnings whose categories have been acknowledged.
    def self.filter_acknowledged(warnings, acknowledged_categories)
      return warnings if acknowledged_categories.nil? || acknowledged_categories.empty?

      warnings.reject { |w| acknowledged_categories.include?(w[:category]) }
    end

    # Analyze code for dangerous patterns.
    # Returns an array of warnings: [{ category:, label:, matches: }]
    def self.analyze(code)
      warnings = []

      DANGEROUS_PATTERNS.each do |category, patterns|
        matches = []
        patterns.each do |regexp, label|
          matches << label if code.match?(regexp)
        end
        next if matches.empty?

        warnings << { category: category, matches: matches }
      end

      warnings
    end

    CATEGORY_LABELS = {
      file_operations: "File system operations",
      system_commands: "System command execution",
      process_manipulation: "Process manipulation",
      network_operations: "Network operations",
      destructive_data: "Destructive data operations",
      mutation_operations: "Data mutation (modifies database records)",
    }.freeze

    # Format warnings into human-readable text.
    # Returns nil if no warnings.
    def self.format_warnings(warnings)
      return nil if warnings.empty?

      lines = []
      lines << "WARNING: Potentially dangerous operations detected in code."
      lines << "evaluate_code should only be used for investigating runtime state."
      lines << "Use the agent's own tools for file/system/network operations."
      lines << ""

      warnings.each do |w|
        label = CATEGORY_LABELS[w[:category]] || w[:category].to_s
        lines << "  #{label}: #{w[:matches].join(", ")}"
      end

      lines.join("\n")
    end
  end
end
