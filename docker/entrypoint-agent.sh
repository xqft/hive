#!/bin/bash
set -e

# Fix ownership if volume was initialized by root
if [ -d /workspace ] && [ "$(stat -c '%u' /workspace)" != "$(id -u)" ]; then
  sudo chown -R "$(id -u):$(id -g)" /workspace 2>/dev/null || true
fi

# Background tmux session for user shell access
tmux new-session -d -s shell -x 200 -y 50 2>/dev/null || true
tmux set-option -g history-limit 10000

# SDK as foreground process (stdin/stdout connected to Hive via docker -i)
cd /workspace
exec node /opt/hive/hive_agent.js "$@"
