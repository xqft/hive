#!/bin/bash
set -e

COLS=${HIVE_TERM_COLS:-200}
ROWS=${HIVE_TERM_ROWS:-50}

tmux new-session -d -s main -x "$COLS" -y "$ROWS"

# Keep container alive while tmux session exists.
# Periodically save pane content so it can be retrieved after container stops.
while tmux has-session -t main 2>/dev/null; do
  tmux capture-pane -p -S - -t main > /tmp/last_output.txt 2>/dev/null || true
  sleep 1
done
