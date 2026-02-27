#!/bin/bash
set -e

# Remove stale PID file (if server was killed previously)
rm -f tmp/pids/server.pid

# DB setup: create, migrate, seed (idempotent)
bin/rails db:prepare

exec "$@"
