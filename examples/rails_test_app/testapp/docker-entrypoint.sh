#!/bin/bash
set -e

# Remove stale PID file (if server was killed previously)
rm -f tmp/pids/server.pid

# DB setup: create, migrate, seed (idempotent)
env -u RUBY_DEBUG_OPEN -u RUBY_DEBUG_PORT -u RUBY_DEBUG_HOST bin/rails db:prepare

exec "$@"
