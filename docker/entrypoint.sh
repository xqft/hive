#!/bin/bash
set -e

COLS=${HIVE_TERM_COLS:-200}
ROWS=${HIVE_TERM_ROWS:-50}

tmux new-session -d -s main -x "$COLS" -y "$ROWS"

# Ensure tmux passes the OAuth token to all new windows/panes
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  tmux set-environment -g CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_CODE_OAUTH_TOKEN"
fi

# Keep container alive while tmux session exists.
# Periodically save pane content so it can be retrieved after container stops.
while tmux has-session -t main 2>/dev/null; do
  tmux capture-pane -p -S - -t main > /tmp/last_output.txt 2>/dev/null || true
  sleep 1
done
