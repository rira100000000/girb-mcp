# Changelog

## 0.1.0 — 2026-03-01

Initial release.

### Features

- **MCP server** with STDIO and Streamable HTTP transports
- **21 debugging tools**: connect, evaluate_code, inspect_object, get_context, get_source, read_file, list_files, set_breakpoint, remove_breakpoint, continue_execution, step, next, finish, run_script, trigger_request, disconnect, and more
- **Rails integration**: auto-detected rails_info, rails_routes, rails_model tools
- **Docker support**: TCP and Unix socket connections with automatic remote file reading
- **Signal trap context handling**: auto-escape on connect and after trigger_request
- **Code safety checker**: warns about dangerous operations in evaluate_code
- **Session management**: multiple concurrent sessions with automatic timeout cleanup
- **girb-rails CLI**: launch Rails server with debug enabled in one command
