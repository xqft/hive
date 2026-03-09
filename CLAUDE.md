# Hive — Agent Orchestration Framework

## Project Overview
Elixir/OTP + Phoenix LiveView + Claude Code. Agents talk via topics/DMs, execute code in Docker containers, extend via MCP servers.

## Setup
```bash
make setup          # deps + npm + assets
make test           # run all tests
make server         # iex -S mix phx.server
make docker-build   # build hive-claude-code image
```

## Key Architecture
- `Hive.Persistence` — single-writer SQLite GenServer (WAL mode). All writes serialized. Reads via separate connection in persistent_term.
- `Hive.Topic` — GenServer per topic/DM. Ring buffer (50 msgs). @mention auto-invite. Canonical DM naming `dm:a:b`.
- `Hive.Agent` — GenServer per agent. Spawns Node subprocess (`sdk/hive_agent.js`). Pipes messages via stdin, reads JSON from stdout.
- `Hive.Container` — GenServer per Docker container. Fire-and-forget. 16/agent limit. Timeout race handled via atomic status transitions.
- `HiveWeb.ToolsController` — single POST `/api/tools` endpoint. HMAC auth per agent.
- `sdk/hive_agent.js` — Claude Agent SDK wrapper. `query()` per turn. Session resumption.
- `sdk/hive_mcp_bridge.js` — stdio MCP server forwarding tool calls to Phoenix API.

## Conventions
- Persistence reads return `{:ok, list}` or `{:ok, map}` or `{:ok, nil}`. Always unwrap.
- Agent/topic names: `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$`. Shared namespace.
- DM names: `dm:a:b` (alphabetical). Skip name validation.
- PubSub topics: `"agents"`, `"topic:{name}"`, `"containers"`, `"container:{id}"`, `"registry"`.
- Tests use temp SQLite databases for isolation.

## File Structure
```
lib/hive/         — core GenServers (agent, topic, container, persistence, validation)
lib/hive_web/     — Phoenix controllers and LiveViews
sdk/              — Node.js scripts (hive_agent.js, hive_mcp_bridge.js)
docker/           — Dockerfile for container execution
priv/agents/      — per-agent working dirs (runtime, gitignored)
priv/sqlite/      — SQLite database (runtime, gitignored)
```

## Agent Lifecycle
1. `Hive.Agent` GenServer starts → spawns Node subprocess running `sdk/hive_agent.js`
2. Messages piped via stdin as JSON, responses read from stdout (newline-delimited JSON)
3. `hive_agent.js` wraps `@anthropic-ai/claude-agent-sdk` — calls `query()` per turn, handles session resumption
4. `sdk/hive_mcp_bridge.js` runs as a stdio MCP server, forwarding tool calls back to the Phoenix API (`/api/tools`)
5. Each agent has a unique HMAC secret for authenticating API requests
6. Agent working directories live in `priv/agents/{name}/` — each gets its own `.claude/` with CLAUDE.md and skills

## Testing
- `make test` — runs all Elixir tests. Each test creates a temp SQLite database for isolation.
- `make test-sdk` — runs JS SDK tests in `sdk/`.
- Single-file runs: `mix test test/hive/topic_test.exs` or `mix test test/hive/topic_test.exs:42` for a specific line.
