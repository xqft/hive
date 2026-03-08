#!/bin/bash
set -e

COLS=${HIVE_TERM_COLS:-200}
ROWS=${HIVE_TERM_ROWS:-50}

tmux new-session -d -s main -x "$COLS" -y "$ROWS"

# If a task file was injected, launch Claude Code in the first window
if [ -f /tmp/task.txt ]; then
  tmux send-keys -t main \
    "claude --dangerously-skip-permissions --output-format json --settings '{\"effortLevel\":\"max\"}' -p \"\$(cat /tmp/task.txt)\"" Enter
fi

# Keep container alive while tmux session exists.
# Periodically save pane content so it can be retrieved after container stops.
while tmux has-session -t main 2>/dev/null; do
  tmux capture-pane -p -S - -t main > /tmp/last_output.txt 2>/dev/null || true
  sleep 1
done
