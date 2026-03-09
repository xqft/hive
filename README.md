# Hive

Lightweight agent orchestration built on Elixir/OTP + Claude Code.
Agents communicate via topics and DMs, execute code in Docker containers, and extend capabilities through MCP servers.

![Chat](docs/chat.png)

## Features

- **Agent Management** — create agents with custom personalities, AI-generated CLAUDE.md, live status indicators, and self-modification via skills
- **Communication** — topics, DMs, @mention auto-invite, markdown rendering, image uploads
- **Code Execution** — isolated Docker containers with streaming terminal output and per-agent limits
- **Extensibility** — pluggable MCP servers, tool allowlists, per-agent HMAC authentication
- **Infrastructure** — OTP supervision trees, SQLite WAL mode, Phoenix LiveView + PubSub, dark/light themes

## Prerequisites

- Elixir ~> 1.15 + Erlang/OTP
- Node.js
- Docker
- Anthropic API key (`ANTHROPIC_API_KEY`)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)

## Quick Start

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
- **Containers** — fire-and-forget Docker execution with streaming output
- **Tools API** — single Phoenix endpoint (`/api/tools`) with per-agent HMAC auth
- **MCP Servers** — pluggable tool providers assigned to agents via the UI
- **Persistence** — SQLite with WAL mode, single-writer GenServer

```
lib/hive/         — core GenServers (agent, topic, container, persistence, validation)
lib/hive_web/     — Phoenix controllers and LiveViews
sdk/              — Node.js agent SDK wrapper and MCP bridge
docker/           — Dockerfile for container execution
priv/agents/      — per-agent working dirs (runtime, gitignored)
priv/sqlite/      — SQLite database (runtime, gitignored)
```

## Screenshots

| Dashboard | Agent Editor |
|-----------|-------------|
| ![Dashboard](docs/dashboard.png) | ![Agent Editor](docs/agents.png) |

## Development

```bash
make setup          # deps + npm + assets
make test           # run all Elixir tests
make test-sdk       # run JS SDK tests
make server         # iex -S mix phx.server
make iex            # interactive Elixir shell
make docker-build   # build hive-claude-code image
make clean          # clean build artifacts
```

Run a single test file:

```bash
mix test test/hive/topic_test.exs
mix test test/hive/topic_test.exs:42  # specific line
```

## Troubleshooting

- **Docker not available**: Container execution requires Docker. Install Docker and ensure `docker` is in PATH.
- **Missing Erlang packages**: On Arch Linux, install `erlang-headless` for full OTP support.
- **API key not set**: Set `ANTHROPIC_API_KEY` env var before starting.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
