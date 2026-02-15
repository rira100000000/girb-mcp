# frozen_string_literal: true

RSpec.describe GirbMcp::ExitMessageBuilder do
  describe ".detect_exception" do
    it "returns nil for nil input" do
      expect(described_class.detect_exception(nil)).to be_nil
    end

    it "returns nil for empty string" do
      expect(described_class.detect_exception("")).to be_nil
    end

    it "detects exception from Ruby stack trace format" do
      output = "/path/to/file.rb:10:in `method': undefined method 'foo' for nil (NoMethodError)"
      result = described_class.detect_exception(output)
      expect(result).to eq("NoMethodError: undefined method 'foo' for nil")
    end

    it "detects exception from simple format" do
      output = "RuntimeError: something went wrong"
      result = described_class.detect_exception(output)
      expect(result).to eq("RuntimeError: something went wrong")
    end

    it "detects namespaced exceptions" do
      output = "/file.rb:5:in `run': connection failed (Net::ReadTimeout)"
      result = described_class.detect_exception(output)
      expect(result).to eq("Net::ReadTimeout: connection failed")
    end

    it "returns nil for output without exceptions" do
      expect(described_class.detect_exception("Hello world")).to be_nil
    end

    it "detects simple Error format" do
      output = "ArgumentError: wrong number of arguments (given 0, expected 1)"
      result = described_class.detect_exception(output)
      expect(result).to eq("ArgumentError: wrong number of arguments (given 0, expected 1)")
    end
  end

  describe ".build_rerun_hint" do
    it "returns generic hint when no client" do
      result = described_class.build_rerun_hint(nil)
      expect(result).to include("run_script(file: '...'")
    end

    it "returns generic hint when client has no script_file" do
      client = build_mock_client
      result = described_class.build_rerun_hint(client)
      expect(result).to include("run_script(file: '...'")
    end

    it "returns specific hint with script_file" do
      client = build_mock_client
      allow(client).to receive(:script_file).and_return("test.rb")
      result = described_class.build_rerun_hint(client)
      expect(result).to include("run_script(file: 'test.rb'")
      expect(result).to include("restore_breakpoints: true")
    end

    it "includes args when present" do
      client = build_mock_client
      allow(client).to receive(:script_file).and_return("test.rb")
      allow(client).to receive(:script_args).and_return(["--verbose", "input.txt"])
      result = described_class.build_rerun_hint(client)
      expect(result).to include("test.rb")
      expect(result).to include("args:")
    end
  end

  describe ".wait_for_process" do
    it "returns nil when client is nil" do
      expect(described_class.wait_for_process(nil)).to be_nil
    end

    it "returns nil when no wait_thread" do
      client = build_mock_client
      expect(described_class.wait_for_process(client)).to be_nil
    end
  end

  describe ".build_exit_message" do
    it "includes header" do
      client = build_mock_client
      result = described_class.build_exit_message("Program finished.", nil, client)
      expect(result).to include("Program finished.")
    end

    it "includes debugger output when present" do
      client = build_mock_client
      result = described_class.build_exit_message("Done.", "some debugger output", client)
      expect(result).to include("Debugger output:")
      expect(result).to include("some debugger output")
    end

    it "includes exception info when detected" do
      client = build_mock_client
      allow(client).to receive(:read_stderr_output).and_return(
        "/file.rb:10:in `run': boom (RuntimeError)"
      )
      result = described_class.build_exit_message("Done.", nil, client)
      expect(result).to include("Unhandled exception: RuntimeError: boom")
    end

    it "shows stdout/stderr when available" do
      client = build_mock_client
      allow(client).to receive(:read_stdout_output).and_return("Hello from stdout")
      allow(client).to receive(:read_stderr_output).and_return("Warning from stderr")
      result = described_class.build_exit_message("Done.", nil, client)
      expect(result).to include("Program output (stdout):")
      expect(result).to include("Hello from stdout")
      expect(result).to include("Process stderr:")
      expect(result).to include("Warning from stderr")
    end

    it "shows connect-session tip when no captured output" do
      client = build_mock_client
      result = described_class.build_exit_message("Done.", nil, client)
      expect(result).to include("stdout/stderr are not captured for sessions started with 'connect'")
      expect(result).to include("run_script")
    end

    it "shows rerun hint for run_script sessions" do
      client = build_mock_client
      allow(client).to receive(:read_stdout_output).and_return("output")
      allow(client).to receive(:script_file).and_return("test.rb")
      result = described_class.build_exit_message("Done.", nil, client)
      expect(result).to include("This debug session has ended")
      expect(result).to include("run_script(file: 'test.rb'")
    end

    it "shows crash debugging hint for exceptions with captured output" do
      client = build_mock_client
      allow(client).to receive(:read_stdout_output).and_return("output")
      allow(client).to receive(:read_stderr_output).and_return(
        "/file.rb:10:in `x': oops (NoMethodError)"
      )
      allow(client).to receive(:script_file).and_return("test.rb")
      result = described_class.build_exit_message("Done.", nil, client)
      expect(result).to include("To debug the crash")
      expect(result).to include("set_breakpoint(exception_class: 'NoMethodError')")
    end

    it "handles exit status success" do
      wait_thread = instance_double(Thread)
      status = instance_double(Process::Status, success?: true, signaled?: false, exitstatus: 0)
      allow(wait_thread).to receive(:join).and_return(wait_thread)
      allow(wait_thread).to receive(:value).and_return(status)

      client = build_mock_client
      allow(client).to receive(:wait_thread).and_return(wait_thread)
      result = described_class.build_exit_message("Done.", nil, client)
      expect(result).to include("Exit status: 0 (success)")
    end

    it "handles exit status error" do
      wait_thread = instance_double(Thread)
      status = instance_double(Process::Status, success?: false, signaled?: false, exitstatus: 1)
      allow(wait_thread).to receive(:join).and_return(wait_thread)
      allow(wait_thread).to receive(:value).and_return(status)

      client = build_mock_client
      allow(client).to receive(:wait_thread).and_return(wait_thread)
      result = described_class.build_exit_message("Done.", nil, client)
      expect(result).to include("Exit status: 1 (error)")
    end

    it "handles signal-killed process" do
      wait_thread = instance_double(Thread)
      status = instance_double(Process::Status, success?: false, signaled?: true, termsig: 9)
      allow(wait_thread).to receive(:join).and_return(wait_thread)
      allow(wait_thread).to receive(:value).and_return(status)

      client = build_mock_client
      allow(client).to receive(:wait_thread).and_return(wait_thread)
      result = described_class.build_exit_message("Done.", nil, client)
      expect(result).to include("Killed by signal 9")
    end
  end
end
