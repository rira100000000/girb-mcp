# frozen_string_literal: true

require "girb_mcp"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

# Helper to build a mock DebugClient
def build_mock_client(connected: true, pid: "12345", paused: true, trap_context: false)
  client = instance_double(GirbMcp::DebugClient,
    connected?: connected,
    pid: pid,
    paused: paused,
    trap_context: trap_context,
    wait_thread: nil,
    stderr_file: nil,
    stdout_file: nil,
    script_file: nil,
    script_args: nil,
    pending_http: nil,
  )
  allow(client).to receive(:send_command).and_return("")
  allow(client).to receive(:send_command_no_wait)
  allow(client).to receive(:send_continue).and_return("")
  allow(client).to receive(:check_current_exception).and_return(nil)
  allow(client).to receive(:cleanup_one_shot_breakpoints).and_return(nil)
  allow(client).to receive(:process_finished?).and_return(false)
  allow(client).to receive(:disconnect)
  allow(client).to receive(:read_stdout_output).and_return(nil)
  allow(client).to receive(:read_stderr_output).and_return(nil)
  allow(client).to receive(:in_trap_context?).and_return(trap_context)
  allow(client).to receive(:escape_trap_context!).and_return(nil)
  allow(client).to receive(:ensure_paused).and_return("")
  allow(client).to receive(:repause).and_return("")
  allow(client).to receive(:continue_and_wait).and_return({ type: :timeout, output: "" })
  allow(client).to receive(:wait_for_breakpoint).and_return({ type: :timeout, output: "" })
  allow(client).to receive(:pending_http=)
  client
end

# Helper to build a mock SessionManager
def build_mock_manager(client: nil)
  client ||= build_mock_client
  manager = instance_double(GirbMcp::SessionManager)
  allow(manager).to receive(:client).and_return(client)
  allow(manager).to receive(:record_breakpoint)
  allow(manager).to receive(:clear_breakpoint_specs)
  allow(manager).to receive(:remove_breakpoint_specs_matching)
  allow(manager).to receive(:restore_breakpoints).and_return([])
  allow(manager).to receive(:cleanup_dead_sessions).and_return([])
  allow(manager).to receive(:active_sessions).with(any_args).and_return([])
  allow(manager).to receive(:disconnect)
  allow(manager).to receive(:timeout).and_return(1800)
  allow(manager).to receive(:connect).and_return({
    success: true, pid: "12345", output: "stopped at line 1", session_id: "session_12345",
  })
  manager
end

# Helper to extract text from MCP::Tool::Response
def response_text(response)
  response.content.first[:text]
end
