# Changelog

## 0.1.1 — 2026-03-01

### Bug Fixes

- **Fix stale `pause` protocol messages causing session deadlock on remote connections** — For remote/Docker connections, `auto_repause!` sent 3–4 `pause PID\n` messages but only 1 was consumed; the rest accumulated in the debug gem's read buffer and fired as unexpected SIGURGs after `c` (continue), re-pausing the process with no client connected and blocking future connections. Fixed by adding a `check_paused` method that waits for the process to pause without sending a new `pause` message, and using it for all retry attempts in `auto_repause!`, `disconnect`, and `connect` (force_reset). Now only 1 `pause` message is sent per repause cycle.

- **Fix `auto_repause!` returning true while process is still running** — After `trigger_request` completes without hitting a breakpoint, `auto_repause!` reported success but `@paused` was actually `false`, causing all subsequent operations (`evaluate_code`, `set_breakpoint`, `disconnect`) to fail with "Process is not paused". Root cause: `attempt_trap_escape!` used passive `ensure_paused` (no SIGURG) instead of active `repause` when escape failed, leaving the process unpaused. Fixed by:
  - Using active `repause` in `attempt_trap_escape!` when escape fails
  - Adding recovery repause in `auto_repause!` after failed trap escape
  - Returning actual `client.paused` state from `attempt_repause_after_no_hit` instead of unconditional `true`

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
