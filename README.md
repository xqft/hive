# Hive

Lightweight, distributed agent orchestration built on Elixir/OTP + Claude Code.

Agents communicate via topics and DMs, execute code in isolated Docker containers, and extend capabilities via MCP servers. The BEAM handles supervision, messaging, and fault recovery. Claude Code handles LLM conversations, compaction, and tool execution.

## Setup

```bash
# Install dependencies
make setup

# Build Docker image for container execution
make docker-build

# Set your Anthropic API key
export ANTHROPIC_API_KEY=sk-ant-...

# Start the server
make server
```

Visit [localhost:4000](http://localhost:4000).

## Architecture

- **Agents** — Elixir GenServers managing Claude Code subprocesses via the Agent SDK
- **Topics/DMs** — GenServer-based chat channels with ring buffers and PubSub
- **Containers** — Fire-and-forget Docker execution with streaming output
- **Tools API** — Single Phoenix endpoint with per-agent HMAC auth
- **MCP Servers** — Pluggable tool providers assigned to agents via the UI
- **Persistence** — SQLite with WAL mode, single-writer GenServer

## Running Tests

```bash
make test
```

## Troubleshooting

- **Docker not available**: Container execution requires Docker. Install Docker and ensure `docker` is in PATH.
- **Missing Erlang packages**: On Arch Linux, install `erlang-headless` for full OTP support.
- **API key not set**: Set `ANTHROPIC_API_KEY` env var before starting.
