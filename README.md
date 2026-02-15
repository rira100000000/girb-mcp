# girb-mcp

[日本語版 (Japanese)](README.ja.md)

MCP (Model Context Protocol) server that gives LLM agents access to the runtime context of executing Ruby processes.

LLM agents like Claude Code can connect to a paused Ruby process, inspect variables, evaluate code, set breakpoints, and control execution — all through MCP tool calls.

## What it does

Existing Ruby/Rails MCP servers only provide static analysis or application-level APIs. girb-mcp goes further: it connects to **running Ruby processes** via the debug gem and exposes their runtime state to LLM agents.

```
Claude Code → connect(host: "localhost", port: 12345)
Claude Code → get_context()
  → local variables, instance variables, call stack
Claude Code → evaluate_code(code: "user.valid?")
  → false
Claude Code → evaluate_code(code: "user.errors.full_messages")
  → ["Email can't be blank"]
Claude Code → continue_execution()
```

## Installation

```ruby
gem "girb-mcp"
```

Or install directly:

```
gem install girb-mcp
```

Requires Ruby >= 3.2.0.

## Quick Start

### 1. Start a Ruby process with the debugger

```bash
# Script
rdbg --open --port=12345 my_script.rb

# Or with environment variables
RUBY_DEBUG_OPEN=true RUBY_DEBUG_PORT=12345 ruby my_script.rb

# Or add `debugger` / `binding.break` in your code and run with rdbg
rdbg --open my_script.rb
```

### 2. Configure Claude Code

Add to your `~/.claude/settings.json` (or project `.claude/settings.json`):

```json
{
  "mcpServers": {
    "girb-mcp": {
      "command": "girb-mcp",
      "args": []
    }
  }
}
```

If using Bundler:

```json
{
  "mcpServers": {
    "girb-mcp": {
      "command": "bundle",
      "args": ["exec", "girb-mcp"]
    }
  }
}
```

### 3. Debug with Claude Code

Ask Claude Code to connect and debug:

> "Connect to the debug session on port 12345 and show me the current state"

> "Set a breakpoint at app/models/user.rb line 42 and send a GET request to /users/1"

## Usage

```
Usage: girb-mcp [options]
    -t, --transport TRANSPORT        Transport type: stdio (default) or http
    -p, --port PORT                  HTTP port (default: 6029, only for http transport)
        --host HOST                  HTTP host (default: 127.0.0.1, only for http transport)
        --session-timeout SECONDS    Session timeout in seconds (default: 1800)
    -v, --version                    Show version
    -h, --help                       Show this help
```

### STDIO transport (default)

Standard transport for Claude Code and other MCP clients. No additional configuration needed.

```bash
girb-mcp
```

### HTTP transport (Streamable HTTP)

For browser-based clients or other HTTP-compatible MCP clients.

```bash
girb-mcp --transport http --port 8080
```

The MCP endpoint will be available at `http://127.0.0.1:8080/mcp`.

### Session timeout

Debug sessions are automatically cleaned up after 30 minutes of inactivity. Adjust with:

```bash
girb-mcp --session-timeout 3600  # 1 hour
```

The session manager also detects and cleans up sessions whose target process has exited.

## Tools

### Discovery & Connection

| Tool | Description |
|------|-------------|
| `list_debug_sessions` | List available debug sessions (Unix sockets) |
| `connect` | Connect to a debug session via socket path or TCP |
| `list_paused_sessions` | List currently connected sessions |

### Investigation

| Tool | Description |
|------|-------------|
| `evaluate_code` | Execute Ruby code in the stopped binding |
| `inspect_object` | Get class, value, and instance variables of an object |
| `get_context` | Local variables, instance variables, call stack, breakpoints |
| `get_source` | Source code of a method or class |
| `read_file` | Read source files with optional line range |

### Execution Control

| Tool | Description |
|------|-------------|
| `set_breakpoint` | Set a line breakpoint (file + line) or catch an exception class |
| `remove_breakpoint` | Remove a breakpoint by file + line, exception class, or number |
| `continue_execution` | Resume execution until next breakpoint or exit |
| `step` | Step into the next method call |
| `next` | Step over to the next line |
| `finish` | Run until the current method/block returns |
| `run_debug_command` | Execute any raw debugger command |

### Entry Points

| Tool | Description |
|------|-------------|
| `run_script` | Start a Ruby script under rdbg and connect to it |
| `trigger_request` | Send an HTTP request to a Rails app under debug |

## Workflows

### Debug a Ruby script

```
Agent: run_script(file: "my_script.rb")
Agent: get_context()
Agent: evaluate_code(code: "result")
Agent: next()
Agent: evaluate_code(code: "result")
Agent: continue_execution()
```

### Catch and debug exceptions

```
Agent: run_script(file: "my_script.rb")
Agent: set_breakpoint(exception_class: "NoMethodError")
Agent: continue_execution()
  → Execution pauses BEFORE the exception propagates
Agent: get_context()
Agent: evaluate_code(code: "$!.message")
```

### Debug a Rails request

```
Agent: connect(host: "localhost", port: 12345)
Agent: set_breakpoint(file: "app/controllers/users_controller.rb", line: 15)
Agent: trigger_request(method: "GET", url: "http://localhost:3000/users/1")
Agent: get_context()
Agent: evaluate_code(code: "@user.attributes")
Agent: continue_execution()
```

### Connect to an existing breakpoint

```bash
# Terminal: your app hits a `debugger` statement
rdbg --open my_app.rb
```

```
Agent: list_debug_sessions()
Agent: connect(path: "/tmp/rdbg-1000/rdbg-12345")
Agent: get_context()
Agent: evaluate_code(code: "local_variables.map { |v| [v, binding.local_variable_get(v)] }.to_h")
```

## How it works

```
┌─────────────┐  STDIO or Streamable HTTP ┌───────────┐    TCP/Unix Socket    ┌──────────────┐
│ Claude Code  │ ◄──────────────────────► │ girb-mcp  │ ◄──────────────────► │ Ruby process │
│ (MCP Client) │       (JSON-RPC)         │(MCP Server)│    debug gem proto   │  (rdbg)      │
└─────────────┘                           └───────────┘                      └──────────────┘
```

1. girb-mcp runs as an MCP server communicating via STDIO (default) or Streamable HTTP
2. The debug gem (`rdbg --open`) exposes a socket on the target Ruby process
3. girb-mcp connects to that socket using the debug gem's wire protocol
4. MCP tool calls are translated to debugger commands and results are returned
5. Idle sessions are automatically cleaned up after a configurable timeout

## Part of the girb family

girb-mcp is part of the [girb](https://github.com/rira100000000/girb) family:

- **girb** — AI-powered IRB assistant (interactive, for humans)
- **girb-mcp** — MCP server for LLM agents (programmatic, for agents)
- **girb-ruby_llm** — LLM provider for girb via ruby_llm
- **girb-gemini** — LLM provider for girb via Gemini API

## Development

```bash
git clone https://github.com/rira100000000/girb-mcp.git
cd girb-mcp
bundle install
```

## License

MIT
