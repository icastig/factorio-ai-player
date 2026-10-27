#!/usr/bin/env bash
# Start the Factorio headless test server with RCON.
# Usage: start-server.sh <save.zip>   (log goes to ~/fai/server.log)
set -euo pipefail
SAVE="${1:-$HOME/fai/saves/m0.zip}"
cd "$HOME/fai/factorio"
exec ./bin/x64/factorio \
  --start-server "$SAVE" \
  --server-settings "$HOME/fai/server-settings.json" \
  --rcon-port 27015 \
  --rcon-password fai-local \
  --port 34197 \
  > "$HOME/fai/server.log" 2>&1
