# Changelog

## Renamed: `girb-mcp` → `debug-mcp` (2026-04-28)

This gem was previously released on RubyGems as `girb-mcp`. It has been renamed to
`debug-mcp` to better reflect its purpose: an MCP server for Ruby's debug gem.

The first `debug-mcp` release is **0.1.2** (see entry below for internal-namespace
changes). If you used `girb-mcp`, replace it with `debug-mcp` in your Gemfile and
MCP client config:

```ruby
# Gemfile
gem "debug-mcp"  # was: gem "girb-mcp"
```

```json
// MCP client config
{
  "mcpServers": {
    "debug-mcp": {                // was: "girb-mcp"
      "command": "debug-mcp",     // was: "girb-mcp"
      "args": []
    }
  }
}
```

The executable `girb-rails` was likewise renamed to `debug-rails`.

The version history for 0.1.0 and 0.1.1 below was originally published under the
name `girb-mcp`; the implementation is unchanged.

## 0.1.2 — 2026-04-28

First release under the `debug-mcp` name.

### Changes

- **Rename internal namespace from `girb` to `debug_mcp`** — Globals, symbols, and
  log paths injected into the debugged Ruby process are now namespaced with
  `debug_mcp` to match the gem name:
  - `$_girb_orig_int`, `$_girb_int_at` → `$_debug_mcp_orig_int`, `$_debug_mcp_int_at`
    (SIGINT trap save/restore)
  - `$__girb_err`, `$__girb_cap` → `$__debug_mcp_err`, `$__debug_mcp_cap`
    (`evaluate_code` error capture and stdout redirect)
  - `:girb_health_check` → `:debug_mcp_health_check` (force_reset health probe)
  - `/tmp/girb_debug.log` → `/tmp/debug_mcp.log` (internal debug log)

  This is internal to debug-mcp and does not change any public API. If you wrote
  Ruby code that read these globals from the debugged process directly, update
  the names accordingly.

- **Add `base64` runtime dependency** — `base64` was removed from Ruby's default
  gems in 3.4.0. `debug-mcp` uses `Base64.strict_encode64` to safely transmit
  multi-line / non-ASCII code over the debug gem's line-based protocol, so it is
  now declared explicitly in the gemspec to avoid `LoadError` on Ruby 3.4+.

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
- **debug-rails CLI**: launch Rails server with debug enabled in one command
