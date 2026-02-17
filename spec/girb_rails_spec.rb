# frozen_string_literal: true

load File.expand_path("../exe/girb-rails", __dir__)

RSpec.describe GirbRails do
  describe ".parse_args" do
    context "with no arguments" do
      it "defaults to 'server' subcommand" do
        result = described_class.parse_args([])
        expect(result[:rails_args]).to eq(["server"])
        expect(result[:debug_port]).to be_nil
        expect(result[:show_help]).to be false
      end
    end

    context "with a subcommand" do
      it "passes through 's'" do
        result = described_class.parse_args(["s"])
        expect(result[:rails_args]).to eq(["s"])
      end

      it "passes through 'server'" do
        result = described_class.parse_args(["server"])
        expect(result[:rails_args]).to eq(["server"])
      end

      it "passes through 'console'" do
        result = described_class.parse_args(["console"])
        expect(result[:rails_args]).to eq(["console"])
      end
    end

    context "with rails options" do
      it "passes through server options" do
        result = described_class.parse_args(["server", "-p", "4000"])
        expect(result[:rails_args]).to eq(["server", "-p", "4000"])
      end

      it "auto-prepends 'server' when first arg is a flag" do
        result = described_class.parse_args(["-p", "4000"])
        expect(result[:rails_args]).to eq(["server", "-p", "4000"])
      end
    end

    context "with --debug-port" do
      it "parses --debug-port with space separator" do
        result = described_class.parse_args(["--debug-port", "3333"])
        expect(result[:debug_port]).to eq(3333)
        expect(result[:rails_args]).to eq(["server"])
      end

      it "parses --debug-port= syntax" do
        result = described_class.parse_args(["--debug-port=3333"])
        expect(result[:debug_port]).to eq(3333)
        expect(result[:rails_args]).to eq(["server"])
      end

      it "combines --debug-port with subcommand and options" do
        result = described_class.parse_args(["--debug-port", "3333", "s", "-p", "4000"])
        expect(result[:debug_port]).to eq(3333)
        expect(result[:rails_args]).to eq(["s", "-p", "4000"])
      end

      it "raises on missing port value" do
        expect { described_class.parse_args(["--debug-port"]) }.to raise_error(ArgumentError, /requires a port number/)
      end

      it "raises on non-numeric port" do
        expect { described_class.parse_args(["--debug-port", "abc"]) }.to raise_error(ArgumentError, /requires a valid port number/)
      end

      it "raises on zero port" do
        expect { described_class.parse_args(["--debug-port", "0"]) }.to raise_error(ArgumentError, /requires a valid port number/)
      end

      it "raises on negative port" do
        expect { described_class.parse_args(["--debug-port", "-1"]) }.to raise_error(ArgumentError, /requires a valid port number/)
      end
    end

    context "with --help / -h" do
      it "sets show_help for --help" do
        result = described_class.parse_args(["--help"])
        expect(result[:show_help]).to be true
      end

      it "sets show_help for -h" do
        result = described_class.parse_args(["-h"])
        expect(result[:show_help]).to be true
      end

      it "passes through --help after subcommand to rails" do
        result = described_class.parse_args(["server", "--help"])
        expect(result[:show_help]).to be false
        expect(result[:rails_args]).to eq(["server", "--help"])
      end
    end

    context "server auto-completion" do
      it "prepends 'server' when no args given" do
        result = described_class.parse_args([])
        expect(result[:rails_args]).to eq(["server"])
      end

      it "prepends 'server' when only --debug-port given" do
        result = described_class.parse_args(["--debug-port", "3333"])
        expect(result[:rails_args]).to eq(["server"])
      end

      it "does not prepend 'server' when subcommand given" do
        result = described_class.parse_args(["console"])
        expect(result[:rails_args]).to eq(["console"])
      end
    end
  end

  describe ".build_env" do
    context "outside Docker" do
      it "sets RUBY_DEBUG_OPEN" do
        env = described_class.build_env(debug_port: nil, docker: false)
        expect(env).to eq({ "RUBY_DEBUG_OPEN" => "true" })
      end

      it "adds RUBY_DEBUG_PORT when specified" do
        env = described_class.build_env(debug_port: 3333, docker: false)
        expect(env).to eq({
          "RUBY_DEBUG_OPEN" => "true",
          "RUBY_DEBUG_PORT" => "3333",
        })
      end
    end

    context "inside Docker" do
      it "sets HOST and default PORT" do
        env = described_class.build_env(debug_port: nil, docker: true)
        expect(env).to eq({
          "RUBY_DEBUG_HOST" => "0.0.0.0",
          "RUBY_DEBUG_PORT" => "12321",
        })
      end

      it "uses specified port over default" do
        env = described_class.build_env(debug_port: 5555, docker: true)
        expect(env).to eq({
          "RUBY_DEBUG_HOST" => "0.0.0.0",
          "RUBY_DEBUG_PORT" => "5555",
        })
      end
    end
  end

  describe ".docker?" do
    it "checks for /.dockerenv" do
      allow(File).to receive(:exist?).with("/.dockerenv").and_return(true)
      expect(described_class.docker?).to be true
    end

    it "returns false when /.dockerenv is absent" do
      allow(File).to receive(:exist?).with("/.dockerenv").and_return(false)
      expect(described_class.docker?).to be false
    end
  end

  describe ".print_help" do
    it "outputs usage information" do
      io = StringIO.new
      described_class.print_help(io)
      output = io.string
      expect(output).to include("Usage: girb-rails")
      expect(output).to include("--debug-port")
      expect(output).to include("Examples:")
    end
  end
end
