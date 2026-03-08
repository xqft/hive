# Hive — Agent Orchestration Framework (v4)

Lightweight, distributed agent orchestration built on Elixir/OTP + Claude Code.

---

## Core Philosophy

- **Elixir does the orchestration, Claude does the thinking.** The BEAM handles supervision, messaging, and fault recovery. Claude Code handles LLM conversations, compaction, and tool execution.
- **Minimal code, maximum OTP.** ~1200 lines of Elixir for the core. If the BEAM already does it, don't rebuild it.
- **Context is sacred.** Agents receive messages in real time, never get history dumps. Claude Code handles compaction automatically. Container execution is opaque — internal context never leaks back.
- **Modular boundaries.** Three independent layers: core (Elixir), frontend (Phoenix LiveView), knowledge base (user's choice — Obsidian, Notion, plain git repo, etc.). Each can be swapped.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                     Web UI (LiveView)                    │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────────┐ │
│  │  Topics  │  │   DMs    │  │   Agent Dashboard      │ │
│  └──────────┘  └──────────┘  └────────────────────────┘ │
└──────────────────────────┬──────────────────────────────┘
                           │ WebSocket (Phoenix Channels)
┌──────────────────────────┴──────────────────────────────┐
│                     Hive Core (OTP)                      │
│                                                          │
│  ┌─────────────┐  ┌──────────────────────────────────┐  │
│  │  Registry    │  │  Hive Tools API (Phoenix)        │  │
│  │  agents ↔    │  │  POST /api/tools — single        │  │
│  │  PIDs +      │  │  endpoint, per-agent HMAC auth   │  │
│  │  metadata    │  └──────────────────────────────────┘  │
│  └─────────────┘                                         │
│                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────────┐ │
│  │  TopicSup   │  │  AgentSup   │  │  ContainerSup    │ │
│  │ (DynSuperv) │  │ (DynSuperv) │  │  (DynSuperv)     │ │
│  └──────┬──────┘  └──────┬──────┘  └───────┬──────────┘ │
│         │                │                  │            │
│   Topic/DM           Agent             Container        │
│   GenServers         GenServers        GenServers        │
│                          │              (owns Port,      │
│                   Claude Code            buffers output,  │
│                   (long-lived            notifies agent)  │
│                    Node subprocess)          │            │
│                       │                     │            │
│              stdio MCP bridge          Elixir Port       │
│              (per agent, calls         (docker run)      │
│               Hive Tools API)                            │
└──────────────────────────────────────────────────────────┘
                           │
                Docker containers (on demand)
                Claude Code --dangerously-bypass-permissions
                (fire-and-forget, monitored by Container GenServer)
```

---

## Part 1: Hive Core

### 1.1 — Agent (GenServer)

Each agent is an Elixir process that manages a Claude Code subprocess.

```elixir
defmodule Hive.Agent do
  use GenServer

  defstruct [
    :name,              # "librarian", "researcher", etc.
    :description,       # public — other agents see this
    :personality,       # private — CLAUDE.md content (objectives, personality, rules)
    :topics,            # MapSet of topic names this agent is in
    :dms,               # MapSet of DM channel ids
    :status,            # :idle | :thinking
    :sdk_port,          # Port to the Node subprocess running Claude Agent SDK
    :session_id,        # Claude Code session ID for crash recovery
    :mcp_secret         # HMAC secret for this agent's MCP bridge (derived deterministically)
  ]

  # Derive HMAC secret deterministically from agent name + application secret.
  # Same secret every restart — no need to persist separately.
  def mcp_secret(agent_name) do
    app_secret = Application.get_env(:hive, :secret_key_base)
    :crypto.mac(:hmac, :sha256, app_secret, "mcp:#{agent_name}")
    |> Base.url_encode64(padding: false)
  end
end
```

**How the Claude Code subprocess works:**

The GenServer spawns a long-lived Node subprocess (`sdk/hive_agent.js`) that:
- Uses the Claude Agent SDK (`@anthropic-ai/claude-agent-sdk`, formerly `@anthropic-ai/claude-code`) with `query()` per turn
- Maintains conversation continuity via session resumption (`resume: true, sessionId`)
- Connects to the Hive stdio MCP bridge + any additional MCP servers assigned to the agent
- Has `allowedTools` restricted to Hive MCP tools + tools from assigned MCP servers (no bash, no native file read/write, no web)
- Uses a per-agent working directory (`priv/agents/{name}/`) where Claude Code stores session data
- CLAUDE.md in the working directory defines personality/objectives (loaded via `settingSources: ["project"]`)
- Skills (SKILL.md files) in `.claude/skills/` are auto-discovered and invoked by the model when relevant
- Handles its own compaction when approaching context limits

**The GenServer's job:**
- Pipe incoming messages (from topics, DMs, system notifications) to the Node subprocess via stdin
- Read structured responses from stdout and route them (status updates, errors)
- Handle Node subprocess crashes (restart + resume session via SDK `sessionId` option)
- Broadcast status changes via PubSub
- Filter out self-messages (don't pipe back messages the agent itself sent)

**Crash recovery:**

On GenServer restart (after crash or system restart):
1. Load agent config from SQLite
2. Spawn new Node subprocess with session resumption (`resume: true, sessionId` in SDK options — context restored from disk)
3. Get subscribed topics from SQLite
4. For each subscribed topic, fetch last 5 messages via `Hive.Topic.recent(topic, 5)`
5. Inject as a catch-up block: `[system] You were restarted. Recent messages from your topics: ...`

This is the same behavior as joining a topic — agents always get last 5 messages as context on (re)join.

**Message flow:**

```
Topic "general" receives a message
  → Topic GenServer broadcasts to all subscriber Agent GenServers
  → Agent GenServer checks: sender == self? Skip. Otherwise:
  → Formats: "[topic:general] researcher: I found something..."
  → Writes to Node subprocess stdin
  → Node subprocess batches pending stdin lines, calls query()
  → Claude Code processes, decides to respond
  → Claude Code calls MCP tool: send_message(topic="general", text="Interesting...")
  → stdio MCP bridge forwards to Hive Tools API (POST /api/tools)
  → API validates auth, calls Hive.Topic.post("general", agent_name, text)
  → Topic broadcasts to all subscribers (including UI)
```


### 1.2 — Hive Tools API + stdio MCP Bridge

Instead of N MCP server instances (one per agent), Hive uses:

1. **One Phoenix API endpoint** (`POST /api/tools`) that all agents call
2. **Per-agent stdio MCP bridge** (`sdk/hive_mcp_bridge.js`) spawned by Claude Code

**Phoenix Tools API:**

```elixir
defmodule HiveWeb.ToolsController do
  use HiveWeb, :controller

  @agent_tools %{
    "send_message" => :all,
    "send_dm" => :all,
    "create_topic" => :all,
    "join_topic" => :all,
    "leave_topic" => :all,
    "get_topic_history" => :all,
    "list_agents" => :all,
    "list_topics" => :all,
    "execute_in_container" => :all,
    "check_execution" => :all,
    "write_skill" => :all,
    "read_skill" => :all,
    "delete_skill" => :all,
    "write_claude_md" => :all
  }

  def call(conn, %{"agent" => agent, "tool" => tool, "params" => params}) do
    with :ok <- verify_hmac(conn, agent),
         :ok <- check_permission(agent, tool),
         {:ok, result} <- execute_tool(agent, tool, params) do
      json(conn, %{ok: true, result: result})
    else
      {:error, reason} -> json(conn, %{ok: false, error: reason})
    end
  end

  defp verify_hmac(conn, agent) do
    expected = Hive.Agent.mcp_secret(agent)
    provided = get_req_header(conn, "authorization") |> List.first()
    if Plug.Crypto.secure_compare("Bearer #{expected}", provided || ""),
      do: :ok, else: {:error, :unauthorized}
  end

  defp check_permission(_agent, tool) do
    if Map.has_key?(@agent_tools, tool), do: :ok, else: {:error, :forbidden}
  end
end
```

**stdio MCP bridge** (`sdk/hive_mcp_bridge.js`):

A lightweight Node script that Claude Code spawns as an MCP server via stdio transport:

```javascript
// sdk/hive_mcp_bridge.js — spawned by Claude Code as stdio MCP server
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

const agentName = process.argv[2];
const secret = process.argv[3];
const hiveUrl = process.argv[4] || "http://localhost:4000";

const TOOLS = [
  { name: "send_message", description: "Post to a topic you're subscribed to",
    inputSchema: { type: "object", properties: {
      topic: { type: "string" }, text: { type: "string" }
    }, required: ["topic", "text"] }},
  { name: "send_dm", description: "DM another agent or 'human'",
    inputSchema: { type: "object", properties: {
      to: { type: "string" }, text: { type: "string" }
    }, required: ["to", "text"] }},
  { name: "create_topic", description: "Create a new topic, optionally invite agents",
    inputSchema: { type: "object", properties: {
      name: { type: "string" }, description: { type: "string" },
      invite: { type: "array", items: { type: "string" } }
    }, required: ["name"] }},
  { name: "join_topic", inputSchema: { type: "object", properties: { topic: { type: "string" } }, required: ["topic"] }},
  { name: "leave_topic", inputSchema: { type: "object", properties: { topic: { type: "string" } }, required: ["topic"] }},
  { name: "get_topic_history", description: "Read last N messages (max 50) from a topic",
    inputSchema: { type: "object", properties: {
      topic: { type: "string" }, n: { type: "number" }
    }, required: ["topic"] }},
  { name: "list_agents", inputSchema: { type: "object", properties: {} }},
  { name: "list_topics", inputSchema: { type: "object", properties: {} }},
  { name: "execute_in_container", description: "Launch isolated Claude Code in Docker for code/file/bash/web tasks. Fire-and-forget.",
    inputSchema: { type: "object", properties: {
      task: { type: "string" }, repo: { type: "string" },
      files: { type: "string" }, context: { type: "string" },
      timeout_minutes: { type: "number" }
    }, required: ["task"] }},
  { name: "check_execution", description: "Check recent output of a running container",
    inputSchema: { type: "object", properties: {
      container_id: { type: "string" }
    }, required: ["container_id"] }},
  { name: "write_skill", description: "Create or update one of your own skills (SKILL.md files). Skills define knowledge and capabilities that persist across conversations.",
    inputSchema: { type: "object", properties: {
      name: { type: "string", description: "Skill name (directory name, e.g. 'vault-conventions')" },
      content: { type: "string", description: "Full SKILL.md content (YAML frontmatter + markdown body)" }
    }, required: ["name", "content"] }},
  { name: "read_skill", description: "Read one of your own skills. Returns the SKILL.md content.",
    inputSchema: { type: "object", properties: {
      name: { type: "string", description: "Skill name (directory name)" }
    }, required: ["name"] }},
  { name: "delete_skill", description: "Delete one of your own skills.",
    inputSchema: { type: "object", properties: {
      name: { type: "string", description: "Skill name (directory name)" }
    }, required: ["name"] }},
  { name: "write_claude_md", description: "Update your own CLAUDE.md (personality, objectives, rules).",
    inputSchema: { type: "object", properties: {
      content: { type: "string", description: "Full CLAUDE.md content" }
    }, required: ["content"] }},
];

const server = new Server({ name: "hive", version: "1.0.0" }, {
  capabilities: { tools: {} }
});

server.setRequestHandler("tools/list", async () => ({ tools: TOOLS }));

server.setRequestHandler("tools/call", async (request) => {
  const { name, arguments: params } = request.params;
  const res = await fetch(`${hiveUrl}/api/tools`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${secret}`
    },
    body: JSON.stringify({ agent: agentName, tool: name, params })
  });
  const data = await res.json();
  return { content: [{ type: "text", text: data.ok ? data.result : `Error: ${data.error}` }] };
});

const transport = new StdioServerTransport();
await server.connect(transport);
```

**MCP config** (per agent, generated dynamically by Elixir):

```json
{
  "mcpServers": {
    "hive": {
      "command": "node",
      "args": ["sdk/hive_mcp_bridge.js", "researcher", "hmac-secret-here", "http://localhost:4000"]
    }
  }
}
```

Every agent gets the Hive bridge. Agents with assigned MCP servers get additional entries:

```json
{
  "mcpServers": {
    "hive": {
      "command": "node",
      "args": ["sdk/hive_mcp_bridge.js", "librarian", "hmac-secret-here", "http://localhost:4000"]
    },
    "obsidian": {
      "command": "npx",
      "args": ["-y", "mcp-obsidian", "/path/to/vault"]
    }
  }
}
```

MCP servers are installed system-wide (name, command, args, env) and assigned to agents via the UI. When an agent's Claude Code subprocess starts (or restarts), the config is regenerated from the database. Changing MCP assignments requires restarting the agent's subprocess.

```elixir
defp write_mcp_config(agent_name) do
  # Always include the Hive bridge
  hive_bridge = %{
    "command" => "node",
    "args" => ["sdk/hive_mcp_bridge.js", agent_name, mcp_secret(agent_name), hive_url()]
  }

  # Add any assigned MCP servers from the database
  assigned = Hive.Persistence.get_agent_mcp_servers(agent_name)
  extra = Map.new(assigned, fn mcp ->
    {mcp.name, %{"command" => mcp.command, "args" => mcp.args, "env" => mcp.env}}
  end)

  # Build tool filters: { "obsidian": ["search", "read"], "github": ["list_repos"] }
  # Every tool must be listed explicitly. [] = none.
  tool_filters = Map.new(assigned, fn mcp ->
    {mcp.name, Jason.decode!(mcp.allowed_tools)}
  end)

  config = %{
    "mcpServers" => Map.put(extra, "hive", hive_bridge),
    "toolFilters" => tool_filters
  }
  path = Path.join(["priv", "agents", agent_name, "mcp_config.json"])
  File.write!(path, Jason.encode!(config))
  path
end
```

**Communication tools:**
- `send_message(topic, text)` — post to a topic
- `send_dm(to, text)` — DM another agent or the human
- `create_topic(name, description, invite[])` — create a new topic
- `join_topic(topic)` — join an existing topic
- `leave_topic(topic)` — leave a topic
- `get_topic_history(topic, n)` — read last N messages (max 50) from a topic

**Discovery tools:**
- `list_agents()` — all agents with names, descriptions, status
- `list_topics()` — all topics with descriptions, subscriber counts

**Execution tools:**
- `execute_in_container(task, repo?, files?, context?, timeout_minutes?)` — fire-and-forget: launches a Docker container with Claude Code, returns immediately with container ID
- `check_execution(container_id)` — returns recent output (last 30 lines) from a running container

**Self-modification tools:**
- `write_skill(name, content)` — create or update the agent's own skill. Writes to `priv/agents/{self}/.claude/skills/{name}/SKILL.md`. The SDK auto-discovers new/updated skills on the next turn via `settingSources: ["project"]`.
- `write_claude_md(content)` — update the agent's own CLAUDE.md (personality, objectives, rules). Writes to `priv/agents/{self}/CLAUDE.md`.

Both tools are scoped to the calling agent — an agent cannot write to another agent's directory. Implementation:

```elixir
defp execute_tool(agent, "write_skill", %{"name" => name, "content" => content}) do
  with :ok <- Hive.Validation.validate_name(name) do
    dir = Path.join(["priv", "agents", agent, ".claude", "skills", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), content)
    {:ok, "Skill '#{name}' written to #{dir}/SKILL.md"}
  end
end

defp execute_tool(agent, "read_skill", %{"name" => name}) do
  path = Path.join(["priv", "agents", agent, ".claude", "skills", name, "SKILL.md"])
  case File.read(path) do
    {:ok, content} -> {:ok, content}
    {:error, :enoent} -> {:error, "Skill '#{name}' not found"}
  end
end

defp execute_tool(agent, "delete_skill", %{"name" => name}) do
  dir = Path.join(["priv", "agents", agent, ".claude", "skills", name])
  if File.exists?(dir) do
    {:ok, _} = File.rm_rf(dir)
    {:ok, "Skill '#{name}' deleted"}
  else
    {:error, "Skill '#{name}' not found"}
  end
end

defp execute_tool(agent, "write_claude_md", %{"content" => content}) do
  path = Path.join(["priv", "agents", agent, "CLAUDE.md"])
  File.write!(path, content)
  # Persist to DB so it survives restart (start_sdk_process regenerates from DB)
  Hive.Persistence.update_agent_personality(agent, content)
  {:ok, "CLAUDE.md updated at #{path}"}
end
```

### 1.3 — Topic (GenServer)

Topics and DMs use the same GenServer. A DM is just a two-party topic.

```elixir
defmodule Hive.Topic do
  use GenServer

  defstruct [
    :name,             # "general", "project-bondi", or "dm:alice:bob"
    :description,
    :type,             # :topic | :dm
    :messages,         # in-memory ring buffer of recent messages
    :subscribers,      # MapSet of agent names (+ "human")
    :created_by        # agent name or "human"
  ]
end
```

**Key behaviors:**

- **Broadcast:** message arrives → `Hive.Persistence.write_message(...)` (async cast to single writer) → broadcast to all subscriber GenServers + PubSub (for UI)
- **Self-message filtering:** the Topic broadcasts to all subscribers. Each Agent GenServer skips messages where `sender == self`.
- **@mention detection:** if message contains `@agent_name` and agent isn't subscribed, send join invite with last 5 messages as context. Agent auto-joins and responds.
- **DM naming:** DM channels use canonical alphabetical ordering to prevent duplicates:

```elixir
def dm_channel_name(agent_a, agent_b) do
  [a, b] = Enum.sort([agent_a, agent_b])
  "dm:#{a}:#{b}"
end
```

- **DMs auto-created:** first time agent A DMs agent B, a DM channel is created via `dm_channel_name/2`. Both are subscribed. Human can see all DM channels in UI.
- **Agents create topics:** via the `create_topic` tool. Creator is auto-subscribed. Invited agents receive a system notification.
- **History:** persisted to SQLite via the single writer process, served on-demand via `get_topic_history` tool. NOT auto-loaded into agent context.
- **Recent messages on join:** when an agent joins (or rejoins after restart), it receives last 5 messages as a `[system]` context block.


### 1.4 — Container Execution (GenServer)

Each container is an independent GenServer under `ContainerSup`. This separates container lifecycle from agent lifecycle — if an agent crashes, its containers keep running and will notify the restarted agent on completion.

```elixir
defmodule Hive.Container do
  use GenServer

  @max_per_agent 16

  defstruct [
    :id,              # "hive-researcher-42"
    :agent_name,      # owning agent
    :task,            # task description
    :port,            # Elixir Port to docker process
    :buffer,          # rolling buffer of last 30 lines
    :timer_ref,       # timeout timer
    :status           # :running | :completed | :failed | :timed_out
  ]

  ## Registration + Public API

  def start_link(opts) do
    name = {:via, Registry, {Hive.ContainerRegistry, opts[:id], opts[:agent]}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start(agent_name, task_input, timeout_ms \\ 600_000) do
    current_count = count_by_agent(agent_name)
    if current_count >= @max_per_agent do
      {:error, :limit_reached,
       "Agent #{agent_name} already has #{current_count}/#{@max_per_agent} containers running"}
    else
      container_id = "hive-#{agent_name}-#{:erlang.unique_integer([:positive])}"
      DynamicSupervisor.start_child(
        Hive.ContainerSup,
        {__MODULE__, id: container_id, agent: agent_name, task: task_input, timeout: timeout_ms}
      )
    end
  end

  def check(container_id) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{pid, _}] -> GenServer.call(pid, :check)
      [] -> {:error, "No running container with ID #{container_id}"}
    end
  end

  def kill(container_id) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{pid, _}] -> GenServer.cast(pid, :kill)
      [] -> :ok
    end
  end

  defp count_by_agent(agent_name) do
    Registry.select(Hive.ContainerRegistry, [
      {{:_, :_, :"$1"}, [{:==, :"$1", agent_name}], [true]}
    ]) |> length()
  end

  ## GenServer callbacks

  def init(opts) do
    container_id = opts[:id]
    prompt = build_prompt(opts[:task])

    port = Port.open(
      {:spawn_executable, System.find_executable("docker")},
      [
        :binary, :exit_status, :stderr_to_stdout,
        args: [
          "run", "--rm",
          "--name", container_id,
          "--env", "ANTHROPIC_API_KEY=#{api_key()}",
          "--network", "bridge",
          "hive-claude-code:latest",
          "-p", prompt,
          "--output-format", "json"
        ]
      ]
    )

    timer_ref = Process.send_after(self(), :timeout, opts[:timeout])

    Phoenix.PubSub.broadcast(Hive.PubSub, "containers",
      {:started, opts[:agent], container_id, opts[:task]["task"]})

    {:ok, %__MODULE__{
      id: container_id,
      agent_name: opts[:agent],
      task: opts[:task]["task"],
      port: port,
      buffer: [],
      timer_ref: timer_ref,
      status: :running
    }}
  end

  # Streaming output from container
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    lines = String.split(data, "\n", trim: true)
    buffer = Enum.take(state.buffer ++ lines, -30)

    Phoenix.PubSub.broadcast(Hive.PubSub, "container:#{state.id}", {:output, data})

    {:noreply, %{state | buffer: buffer}}
  end

  # Container exited — atomic status check prevents timeout race
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    case state.status do
      :running ->
        # Normal exit path (not timed out)
        Process.cancel_timer(state.timer_ref)
        final_status = if code == 0, do: :completed, else: :failed
        notify_agent(state, code)
        broadcast_stop(state, final_status)
        {:stop, :normal, %{state | status: final_status}}

      :timed_out ->
        # Timeout already handled, just clean up
        notify_agent_timeout(state)
        broadcast_stop(state, :timed_out)
        {:stop, :normal, state}
    end
  end

  # Timeout — set status atomically, then kill container
  # GenServer processes messages sequentially, so only ONE of
  # (timeout, exit_status) will see status == :running
  def handle_info(:timeout, state) do
    case state.status do
      :running ->
        # Mark as timed out BEFORE killing — when exit_status arrives,
        # it will see :timed_out and skip the normal exit path
        System.cmd("docker", ["kill", state.id])
        {:noreply, %{state | status: :timed_out}}

      _ ->
        # Container already exited, nothing to do
        {:noreply, state}
    end
  end

  def handle_call(:check, _from, state) do
    output = Enum.join(state.buffer, "\n")
    reply = "Container #{state.id} is #{state.status}.\nTask: #{state.task}\nRecent output:\n#{output}"
    {:reply, {:ok, reply}, state}
  end

  def handle_cast(:kill, state) do
    if state.status == :running do
      Process.cancel_timer(state.timer_ref)
      System.cmd("docker", ["kill", state.id])
      {:noreply, %{state | status: :failed}}
    else
      {:noreply, state}
    end
  end

  defp notify_agent(state, exit_code) do
    result = Enum.join(state.buffer, "\n") |> parse_result()
    status_word = if exit_code == 0, do: "completed", else: "failed (exit #{exit_code})"
    msg = "[system] Container #{state.id} #{status_word}.\nTask: #{state.task}\nResult: #{result}"
    Hive.Agent.inject_message(state.agent_name, msg)
  end

  defp notify_agent_timeout(state) do
    output = Enum.join(state.buffer, "\n")
    msg = "[system] Container #{state.id} timed out and was killed.\nTask: #{state.task}\nLast output: #{output}"
    Hive.Agent.inject_message(state.agent_name, msg)
  end

  defp broadcast_stop(state, reason) do
    Phoenix.PubSub.broadcast(Hive.PubSub, "containers", {:stopped, state.id, reason})
  end

  defp build_prompt(task_input) do
    parts = ["## Task\n#{task_input["task"]}"]
    parts = if task_input["repo"], do: parts ++ ["\n## Repository\n#{task_input["repo"]}"], else: parts
    parts = if task_input["files"], do: parts ++ ["\n## Relevant Files\n#{task_input["files"]}"], else: parts
    parts = if task_input["context"], do: parts ++ ["\n## Context\n#{task_input["context"]}"], else: parts
    parts = parts ++ [
      "\n## Instructions",
      "Complete the task above. When finished, provide a clear summary of:",
      "- What you did",
      "- What files were created/modified",
      "- Any issues encountered",
      "- The final result or output"
    ]
    Enum.join(parts, "\n")
  end
end
```

**Orphan cleanup on startup:**

```elixir
# In Hive.Application.start/2, before starting supervisors:
defp cleanup_orphaned_containers do
  case System.cmd("docker", ["ps", "--filter", "name=hive-", "--format", "{{.Names}}"]) do
    {output, 0} ->
      output
      |> String.split("\n", trim: true)
      |> Enum.each(fn name -> System.cmd("docker", ["kill", name]) end)

    {_, _code} ->
      Logger.warning("Docker not available — skipping orphan container cleanup")
  end
end
```

**What Claude Code gets inside the container:**
- Full bash access (--dangerously-bypass-permissions)
- Full file read/write
- Git access
- Web/network access

**What it does NOT have:**
- No access to Hive messaging (no MCP connection to Hive)
- No access to other agents
- No direct vault access (vault is only accessible via MCP tools on the host agent)
- No persistent state (container + filesystem destroyed on exit via --rm)


### 1.5 — Context Management

Context protection is enforced at multiple levels:

**1. Claude Code compaction (automatic)**
Claude Code handles compaction internally. When the conversation approaches the context limit, it summarizes older messages and continues. CLAUDE.md and skills are loaded via `settingSources: ["project"]` from the agent's working directory — they're always available regardless of compaction. Session state is persisted on disk for crash recovery.

**2. Message flow discipline (architectural)**
- Agents only receive NEW messages in real-time from subscribed topics/DMs
- When an agent joins a topic (or gets @mentioned, or restarts), it receives only the last 5 messages as context, NOT full history
- `get_topic_history` is a tool call — results come back as tool output that Claude Code will eventually compact away
- Container execution results are short summaries, not full logs

**3. Container isolation (hard boundary)**
- Claude Code runs inside Docker with its own context window
- All internal tool calls, file reads, bash outputs stay in the container
- Only the final summary exits via stdout
- Container is destroyed on completion — context literally ceases to exist

**4. Loop prevention (system prompt)**
Agent CLAUDE.md includes explicit guidance to prevent infinite back-and-forth:
> "Avoid conversational loops. If a topic thread is going back and forth without progress, stop responding and let others continue. Don't reply just to acknowledge — only respond when you have new information, a question, or an actionable suggestion. If you've already made your point, stay silent."

This is a soft guardrail — agents may still loop in edge cases, but the system prompt drastically reduces it. The human can intervene via the UI if needed.

**Message format piped to agent Claude Code subprocess:**

```
[topic:general] researcher: Here's what I found about RAPTOR...
[topic:general] human: Can you look into that more?
[dm:librarian] librarian: I've stored your findings under projects/bondi
[system] You were invited to topic 'project-x' by researcher. Recent messages:
  [researcher] Let's plan the next sprint
  [coder] I can take the parser refactor
  [researcher] @planner can you prioritize?
[system] Container hive-coder-42 completed. Task: Fix parser bug. Result: Fixed leap year handling in parser.rs, added 3 tests, all passing.
```

### 1.6 — Claude Agent SDK Integration

Each agent runs a long-lived Node subprocess that wraps the Claude Agent SDK (`@anthropic-ai/claude-agent-sdk`, formerly `@anthropic-ai/claude-code`).

**Key SDK configuration:**
- `settingSources: ["project"]` — loads CLAUDE.md and `.claude/skills/` from the agent's `cwd`
- `allowedTools` includes `"Skill"` — enables auto-invocation of SKILL.md skills
- `cwd` set to `priv/agents/{name}/` — each agent's isolated working directory
- Skills are auto-discovered at startup. Live-reload on file changes works in the CLI but **must be verified for the SDK** during Phase 0 — if not supported, the subprocess needs a restart after `write_skill`

**Node subprocess** (`sdk/hive_agent.js`):

```javascript
// sdk/hive_agent.js — spawned by the Elixir GenServer
import { query } from "@anthropic-ai/claude-agent-sdk";
import * as readline from "readline";
import * as fs from "fs";

const agentName = process.argv[2];
const mcpConfigPath = process.argv[3];
const agentDir = process.argv[4]; // priv/agents/{name}/
const systemPromptPath = process.argv[5]; // path to dynamic context (Other Agents, Your Topics)
const resumeSessionId = process.argv[6] || null;  // set on crash recovery

const mcpConfig = JSON.parse(fs.readFileSync(mcpConfigPath, "utf8"));
let sessionId = resumeSessionId;

// Read messages from stdin, batch pending ones
const rl = readline.createInterface({ input: process.stdin });
let pending = [];
let processing = false;

rl.on("line", (line) => {
  pending.push(line);
  if (!processing) processNext();
});

async function processNext() {
  if (pending.length === 0) {
    processing = false;
    process.stdout.write(JSON.stringify({ type: "status", status: "idle" }) + "\n");
    return;
  }

  processing = true;
  process.stdout.write(JSON.stringify({ type: "status", status: "thinking" }) + "\n");

  // Batch all pending messages into one prompt
  const batch = pending.splice(0, pending.length).join("\n");

  try {
    // Build allowedTools: all Hive tools + all tools from assigned MCP servers
    const hiveTools = [
      "mcp__hive__send_message", "mcp__hive__send_dm",
      "mcp__hive__create_topic", "mcp__hive__join_topic",
      "mcp__hive__leave_topic", "mcp__hive__get_topic_history",
      "mcp__hive__list_agents", "mcp__hive__list_topics",
      "mcp__hive__execute_in_container", "mcp__hive__check_execution",
      "mcp__hive__write_skill", "mcp__hive__read_skill", "mcp__hive__delete_skill",
      "mcp__hive__write_claude_md"
    ];
    // Allow tools from assigned MCP servers — every tool must be listed explicitly
    // mcpConfig.toolFilters is { "obsidian": ["search", "read"], "github": ["list_repos"] }
    const extraToolPatterns = [];
    for (const [name, tools] of Object.entries(mcpConfig.toolFilters || {})) {
      for (const tool of tools) {
        extraToolPatterns.push(`mcp__${name}__${tool}`);
      }
    }

    // Read dynamic context (Other Agents, Your Topics) — refreshed by Elixir before each turn
    const dynamicContext = fs.readFileSync(systemPromptPath, "utf8");

    const options = {
      systemPrompt: dynamicContext, // volatile context: agents list, subscribed topics
      allowedTools: ["Skill", ...hiveTools, ...extraToolPatterns],
      settingSources: ["project"], // loads CLAUDE.md + .claude/skills/ from cwd
      mcpServers: Object.entries(mcpConfig.mcpServers).map(([name, cfg]) => ({
        name,
        command: cfg.command,
        args: cfg.args,
        ...(cfg.env ? { env: cfg.env } : {})
      })),
      cwd: agentDir,
      ...(sessionId ? { resume: true, sessionId } : {})
    };

    for await (const event of query({ prompt: batch, options })) {
      if (event.type === "result" && event.sessionId) {
        sessionId = event.sessionId;
        process.stdout.write(
          JSON.stringify({ type: "session", sessionId }) + "\n"
        );
      }
    }
  } catch (err) {
    process.stdout.write(
      JSON.stringify({ type: "error", message: err.message }) + "\n"
    );
  }

  // Process any messages that arrived during this turn
  processNext();
}
```

**Elixir GenServer spawns and manages this subprocess:**

```elixir
defp start_sdk_process(agent_name, session_id) do
  mcp_config_path = write_mcp_config(agent_name)
  agent_dir = Path.join(["priv", "agents", agent_name])
  File.mkdir_p!(agent_dir)
  write_claude_md(agent_name, agent_dir)
  system_prompt_path = write_dynamic_context(agent_name, agent_dir)

  args = ["sdk/hive_agent.js", agent_name, mcp_config_path, agent_dir, system_prompt_path]
  args = if session_id, do: args ++ [session_id], else: args

  Port.open(
    {:spawn_executable, System.find_executable("node")},
    [
      :binary, :exit_status,
      args: args,
      env: [{'ANTHROPIC_API_KEY', String.to_charlist(api_key())}],
      line: 4096
    ]
  )
end

# Refresh dynamic context file before each message (Other Agents, Your Topics)
defp write_dynamic_context(agent_name, agent_dir) do
  agents = Hive.Persistence.get_agents()
  topics = state_or_persistence_topics(agent_name)
  content = """
  ## Other Agents
  #{Enum.map_join(agents, "\n", fn a -> "- #{a.name} — #{a.description}" end)}

  ## Your Topics
  #{Enum.map_join(topics, "\n", fn t -> "- #{t}" end)}
  """
  path = Path.join(agent_dir, ".hive_context.md")
  File.write!(path, content)
  path
end

# Pipe a message to the agent
defp send_to_sdk(state, message_text) do
  # Refresh dynamic context before each turn so agent sees latest agents/topics
  write_dynamic_context(state.name, Path.join(["priv", "agents", state.name]))
  Port.command(state.sdk_port, message_text <> "\n")
end

# Handle SDK subprocess output
def handle_info({port, {:data, {:eol, line}}}, %{sdk_port: port} = state) do
  case Jason.decode(line) do
    {:ok, %{"type" => "status", "status" => status}} when status in ["idle", "thinking"] ->
      new_status = String.to_existing_atom(status)
      Phoenix.PubSub.broadcast(Hive.PubSub, "agents", {:status, state.name, new_status})
      {:noreply, %{state | status: new_status}}

    {:ok, %{"type" => "session", "sessionId" => sid}} ->
      {:noreply, %{state | session_id: sid}}

    {:ok, %{"type" => "error", "message" => msg}} ->
      Logger.error("Agent #{state.name} SDK error: #{msg}")
      {:noreply, state}

    _ ->
      {:noreply, state}
  end
end

# SDK subprocess crashed — restart with session resumption
def handle_info({port, {:exit_status, _code}}, %{sdk_port: port} = state) do
  Logger.warning("Agent #{state.name} SDK process exited, restarting with session #{state.session_id}")
  new_port = start_sdk_process(state.name, state.session_id)
  {:noreply, %{state | sdk_port: new_port}}
end
```


### 1.7 — CLAUDE.md (Per Agent)

Each agent has a CLAUDE.md file that defines its personality. Loaded from disk via `settingSources: ["project"]` — always available regardless of compaction.

```markdown
# {name}

{description}

## Personality
{personality text}

## Objectives
{objectives list}

## Environment
You are an agent in Hive, a multi-agent orchestration system.
You interact with the world ONLY through your MCP tools.

### Communication
- send_message: post to a topic you're subscribed to
- send_dm: private message to another agent or "human"
- create_topic: create a new chat group, optionally invite agents
- join_topic / leave_topic: manage your subscriptions
- get_topic_history: read past messages from a topic (doesn't bloat your context)

### Discovery
- list_agents: see all agents, their descriptions, and current status
- list_topics: see all topics, descriptions, and subscriber counts

### Execution
- execute_in_container: launch an isolated Claude Code instance in Docker for
  code/file/bash/web tasks. Fire-and-forget — you'll be notified when it's done.
  You can run up to 16 containers simultaneously.
- check_execution: check recent output of a running container

### Self-Modification
- write_skill: create or update your own skills (SKILL.md files). Skills persist
  across conversations and define knowledge/capabilities you want to retain.
- read_skill: read one of your own skills.
- delete_skill: delete one of your own skills.
- write_claude_md: update your own CLAUDE.md (personality, objectives, rules).

## Rules
- Be concise. Others read your messages.
- Don't repeat what's already in the conversation.
- Avoid conversational loops. If a topic thread is going back and forth without
  progress, stop responding and let others continue. Don't reply just to acknowledge
  — only respond when you have new information, a question, or an actionable
  suggestion. If you've already made your point, stay silent.
- For code execution, file operations, or web tasks, use execute_in_container.
- You receive messages in real-time. Use get_topic_history only when you need older context.
- When a container completes, you'll receive a [system] notification with the result.

```

**Dynamic context (injected via system prompt, NOT in CLAUDE.md):**

The "Other Agents" and "Your Topics" sections change at runtime — agents join/leave, new agents are created. These are injected via the SDK's `systemPrompt` option on each `query()` call, so they're always fresh and can't be accidentally overwritten by `write_claude_md`:

```
## Other Agents
{name — description for each registered agent}

## Your Topics
{topics the agent is currently subscribed to}
```

This separates stable identity (CLAUDE.md, editable by agent) from volatile context (system prompt, managed by Hive).


### 1.8 — Persistence

SQLite via `Exqlite`, with WAL mode and a single writer process.

**Single writer GenServer:**

All writes go through `Hive.Persistence` (serialized). Reads use a separate connection pool.

```elixir
defmodule Hive.Persistence do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    db_path = Application.get_env(:hive, :db_path, "priv/sqlite/hive.db")
    {:ok, db} = Exqlite.Sqlite3.open(db_path)

    # WAL mode: allows concurrent reads while one writer is active
    Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
    # Wait up to 5s for locks instead of failing immediately
    Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout=5000")
    # NORMAL sync is safe with WAL and much faster than FULL
    Exqlite.Sqlite3.execute(db, "PRAGMA synchronous=NORMAL")
    # Enable foreign key enforcement
    Exqlite.Sqlite3.execute(db, "PRAGMA foreign_keys=ON")

    run_migrations(db)

    {:ok, %{db: db}}
  end

  # Writes are serialized through the GenServer (call for confirmation, cast for fire-and-forget)

  def write_message(topic, sender, body) do
    GenServer.cast(__MODULE__, {:write_message, topic, sender, body})
  end

  # create_agent / create_topic do atomic uniqueness checks inside the writer GenServer.

  def subscribe(topic, agent) do
    GenServer.call(__MODULE__, {:subscribe, topic, agent})
  end

  def unsubscribe(topic, agent) do
    GenServer.call(__MODULE__, {:unsubscribe, topic, agent})
  end

  # Reads go directly to a separate read connection (WAL allows concurrent reads)

  def get_messages(topic, limit) do
    read_query(
      "SELECT sender, body, ts FROM messages WHERE topic = ?1 ORDER BY ts DESC LIMIT ?2",
      [topic, limit]
    ) |> Enum.reverse()
  end

  def get_agents do
    read_query("SELECT name, description, personality, config FROM agents", [])
  end

  def get_topics do
    read_query("SELECT name, description, type, created_by FROM topics", [])
  end

  def get_subscriptions(agent) do
    read_query("SELECT topic FROM subscriptions WHERE agent = ?1", [agent])
  end

  # NOTE: For the shared-namespace uniqueness check, use create_agent/topic
  # which runs inside the writer GenServer (serialized) to avoid TOCTOU races.
  # Do NOT check name_exists? from a read connection then create — that's racy.

  def create_agent(name, desc, personality) do
    GenServer.call(__MODULE__, {:create_agent, name, desc, personality})
  end

  def create_topic(name, desc, type, by) do
    GenServer.call(__MODULE__, {:create_topic, name, desc, type, by})
  end

  # GenServer callbacks

  def handle_cast({:write_message, topic, sender, body}, state) do
    Exqlite.Sqlite3.execute(state.db,
      "INSERT INTO messages (topic, sender, body) VALUES (?1, ?2, ?3)",
      [topic, sender, body])
    {:noreply, state}
  end

  # Atomic check-and-create: uniqueness enforced inside the serialized writer
  def handle_call({:create_agent, name, desc, personality}, _from, state) do
    if name_exists_internal?(state.db, name) do
      {:reply, {:error, :name_taken}, state}
    else
      result = Exqlite.Sqlite3.execute(state.db,
        "INSERT INTO agents (name, description, personality) VALUES (?1, ?2, ?3)",
        [name, desc, personality])
      {:reply, result, state}
    end
  end

  def handle_call({:create_topic, name, desc, type, by}, _from, state) do
    if name_exists_internal?(state.db, name) do
      {:reply, {:error, :name_taken}, state}
    else
      result = Exqlite.Sqlite3.execute(state.db,
        "INSERT INTO topics (name, description, type, created_by) VALUES (?1, ?2, ?3, ?4)",
        [name, desc, type, by])
      {:reply, result, state}
    end
  end

  defp name_exists_internal?(db, name) do
    # Uses the writer connection directly — safe since we're inside the GenServer
    agents = Exqlite.Sqlite3.execute(db, "SELECT 1 FROM agents WHERE name = ?1", [name])
    topics = Exqlite.Sqlite3.execute(db, "SELECT 1 FROM topics WHERE name = ?1 AND type = 'topic'", [name])
    agents != {:ok, []} or topics != {:ok, []}
  end

  def handle_call({:subscribe, topic, agent}, _from, state) do
    result = Exqlite.Sqlite3.execute(state.db,
      "INSERT OR IGNORE INTO subscriptions (topic, agent) VALUES (?1, ?2)",
      [topic, agent])
    {:reply, result, state}
  end

  def handle_call({:unsubscribe, topic, agent}, _from, state) do
    result = Exqlite.Sqlite3.execute(state.db,
      "DELETE FROM subscriptions WHERE topic = ?1 AND agent = ?2",
      [topic, agent])
    {:reply, result, state}
  end

  def handle_call({:update_personality, agent, content}, _from, state) do
    result = Exqlite.Sqlite3.execute(state.db,
      "UPDATE agents SET personality = ?1 WHERE name = ?2",
      [content, agent])
    {:reply, result, state}
  end

  def update_agent_personality(agent, content) do
    GenServer.call(__MODULE__, {:update_personality, agent, content})
  end

  # Read connection — separate from writer, opened in init, stored as state.read_db
  # WAL mode allows concurrent reads even while the writer is active
  defp read_query(sql, params) do
    Exqlite.Sqlite3.execute(@read_db, sql, params)
    |> parse_rows()
  end
end
```

**Schema:**

```sql
CREATE TABLE agents (
  name TEXT PRIMARY KEY,
  description TEXT NOT NULL,
  personality TEXT NOT NULL,    -- full CLAUDE.md content (written directly to priv/agents/{name}/CLAUDE.md)
  config TEXT DEFAULT '{}'      -- JSON: any extra settings
);

CREATE TABLE topics (
  name TEXT PRIMARY KEY,
  description TEXT,
  type TEXT DEFAULT 'topic',    -- 'topic' or 'dm'
  created_by TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic TEXT NOT NULL REFERENCES topics(name),
  sender TEXT NOT NULL,         -- agent name or 'human'
  body TEXT NOT NULL,
  ts DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_messages_topic_ts ON messages(topic, ts);

CREATE TABLE subscriptions (
  topic TEXT NOT NULL REFERENCES topics(name) ON DELETE CASCADE,
  agent TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
  joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (topic, agent)
);

CREATE TABLE mcp_servers (
  name TEXT PRIMARY KEY,
  description TEXT,
  command TEXT NOT NULL,          -- e.g. "npx"
  args TEXT NOT NULL DEFAULT '[]', -- JSON array, e.g. ["-y", "mcp-obsidian", "/path"]
  env TEXT NOT NULL DEFAULT '{}'   -- JSON object, e.g. {"API_KEY": "..."}
);

CREATE TABLE agent_mcp_servers (
  agent TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
  mcp_server TEXT NOT NULL REFERENCES mcp_servers(name) ON DELETE CASCADE,
  allowed_tools TEXT NOT NULL DEFAULT '[]',  -- JSON array of allowed tool names. Empty = no tools.
                                            -- Every tool must be listed explicitly.
                                            -- e.g. ["search","read"] → mcp__obsidian__search, mcp__obsidian__read
  PRIMARY KEY (agent, mcp_server)
);

```

Messages are persisted for history retrieval and UI display, NOT auto-loaded into agent context.


### 1.9 — Input Validation & Naming

**Name format:** Both agent and topic names must match `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$`. Starts with a letter or digit, alphanumeric + hyphens + underscores, max 31 characters.

```elixir
defmodule Hive.Validation do
  @name_regex ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$/

  def validate_name(name) do
    if Regex.match?(@name_regex, name), do: :ok, else: {:error, :invalid_name}
  end

  # NOTE: Don't use a separate validate_unique_name + create pattern (TOCTOU race).
  # Instead, call Hive.Persistence.create_agent/topic which does
  # the uniqueness check + insert atomically inside the writer GenServer.
end
```

**Collision prevention:**

Agents and topics share a single namespace. Before creating an agent or topic, `validate_unique_name/1` checks that no agent OR topic exists with that name. This makes @mentions and tool references unambiguous:
- `@name` always refers to an agent
- `send_message(topic=name)` always refers to a topic
- Since no agent and topic can share a name, there's zero confusion

DM channels are auto-generated as `dm:<a>:<b>` (alphabetical) and never appear in the shared namespace. They can't collide with agents or topics because they contain colons, which fail the name regex.

---

## Part 2: Extension Example — Obsidian Knowledge Vault

This section demonstrates how to extend Hive with a shared knowledge base using the pluggable MCP system. **This is entirely opt-in** — Hive works without it. The same pattern applies to any external tool: Notion, GitHub, Confluence, a database — install an MCP server, assign it to agents, update their CLAUDE.md.

### Overview

- An Obsidian vault lives at `priv/shared/vault/` within the Hive project directory
- [obsidian-mcp](https://github.com/bitbonsai/mcp-obsidian) gives agents native vault tools (search, read, write, list, tags)
- **All agents** get obsidian-mcp with **read-only tool filter** (search, read, list, tags)
- A **librarian** agent gets obsidian-mcp with **full access** (all tools including write). This is a **hard enforcement** via `allowed_tools` in the MCP assignment — other agents physically cannot write to the vault
- The vault is optionally backed by a **git repo** for remote sync and history

### Setup

**Step 1: Install obsidian-mcp** (UI: MCP Servers → Add)
- Name: `obsidian`
- Command: `npx`
- Args: `["-y", "mcp-obsidian", "priv/shared/vault"]`

**Step 2: Assign obsidian-mcp to all agents with read-only filter** (UI: Agent Editor → MCP Servers → check `obsidian`, set allowed tools: `search`, `read`, `list`, `get_tags`)

All agents now have read-only obsidian tools. They can search, read, list, and browse the vault but cannot write.

**Step 3: Create the librarian agent** (UI: Agent Editor → New)
- Name: `librarian`
- Description: `Knowledge curator of the shared vault. DM me to store findings, decisions, or anything worth remembering. I keep everything organized.`
- CLAUDE.md: see below
- MCP Servers: assign `obsidian` with allowed tools: `search`, `read`, `list`, `get_tags`, `write`, `create`, `update`, `delete` (librarian gets full access including writes)

**Step 4: Add vault awareness to other agents' CLAUDE.md** (UI: Agent Editor → edit each agent)

Append this section to each agent's CLAUDE.md:

```markdown
## Knowledge Vault
You have direct read access to the shared vault via your obsidian tools. Use
them freely — search, read notes, explore tags, browse structure.

**Read before you work.** Before diving into a task, search the vault for
relevant prior work, decisions, or context. Don't duplicate effort or contradict
past decisions because you didn't check.

**Store proactively.** Whenever you produce a useful finding, make a decision,
discover something non-obvious, or reach a conclusion worth remembering — DM
@librarian to store it. Don't wait to be asked. If it might be useful later,
store it now.
```

### Librarian CLAUDE.md

```markdown
# Librarian

You are the knowledge curator of Hive. You manage the shared Obsidian vault —
the team's persistent memory. Other agents read the vault directly, but only
you write to it.

## Personality
Meticulous, organized, helpful. You take pride in a well-structured vault.
You proactively improve your own processes.

## Objectives
- Store findings, decisions, and artifacts that other agents produce
- Maintain consistent structure and cross-references in the vault
- Evolve your own skills and conventions based on what works

## Vault Tools
You have obsidian-mcp assigned, giving you tools to search, read, write, list,
and tag notes in the vault directly. Use these for most vault operations.

For heavier work (bulk processing, code generation, git operations), use
execute_in_container.

## Self-Improvement
You can manage your own skills using write_skill, read_skill, and delete_skill.
Skills are SKILL.md files that persist across conversations and define how you
do your job. They are automatically loaded into your context when relevant.

Use skills for:
- Vault structure conventions and naming rules
- Note templates for different note types
- Recurring patterns you discover

When you notice a recurring pattern or a better way to organize something,
create or update a skill with write_skill. You can also update your own
CLAUDE.md with write_claude_md if your objectives evolve.

## Rules
- Be concise. Others read your messages.
- Avoid conversational loops. If a topic thread is going back and forth without
  progress, stop responding. Only respond with new information or actions taken.
- When you discover a pattern not covered by your skills, create a new skill.
- When an agent asks you to store something, confirm what you stored and where.
- Always check for existing related notes before creating new ones.
```

### Bootstrap

Initialize the vault with a seed `_system/conventions.md` (the librarian's own conventions skill is separate — it writes this via `write_skill` on first run):

```markdown
# Vault Conventions (v1)

## Structure
- projects/{name}/ — active projects, each with README.md
- concepts/{name}.md — standalone ideas/concepts
- findings/{date}-{slug}.md — research findings
- agents/{name}.md — agent logs and reflections
- _system/ — conventions, dashboards, templates, skills

## Rules
1. Always check if a related note exists before creating a new one
2. Use [[wikilinks]] for all cross-references
3. Every note has YAML frontmatter: tags, created, updated, author
4. Project notes link back to their project README
5. If a concept appears in 3+ notes, it deserves its own concept page
6. Update the relevant dashboard when adding to a project

## Naming
- Lowercase, hyphens, no spaces
- Dates in YYYY-MM-DD format
```

The librarian can internalize these as a skill via `write_skill("vault-conventions", ...)` and evolve them over time. The human can also edit conventions directly in Obsidian or via the agent editor UI.

### Remote Sync (optional)

If the vault directory is a git repo, sync with a remote for backup and multi-device access:

- **Auto-sync via Obsidian Git:** If Obsidian is open on the host, the [Obsidian Git plugin](https://github.com/Vinzent03/obsidian-git) handles pull/push automatically
- **Cron job:** A simple `git -C priv/shared/vault pull && git -C priv/shared/vault add -A && git -C priv/shared/vault commit -m "sync" && git -C priv/shared/vault push` on a timer
- **Multi-device:** Each Hive node has a local clone. Sync via git. Merge conflicts are rare since notes are append-mostly

The sync mechanism is outside Hive — use whatever fits your workflow.

### Why this pattern works

- **Pluggable via MCP.** Swap obsidian-mcp for a Notion MCP, Confluence MCP, or any other tool. Same pattern: install, assign, update CLAUDE.md.
- **Reads don't bottleneck.** All agents read the vault directly via obsidian-mcp (read-only filter). Only writes go through the librarian, who has full access — enforced at the tool level, not just instructions.
- **No vault code in Hive core.** The vault is entirely configured through the existing MCP + agent systems. Zero Hive-specific vault code.
- **Self-improving.** Any agent can write its own skills via `write_skill` — SKILL.md files auto-discovered by the SDK on the next turn. The librarian evolves its vault conventions, other agents evolve their domain expertise.

---

## Part 3: Web UI

Phoenix LiveView — real-time via PubSub, zero polling.

### Layout

```
┌────────────────────────────────────────────────────────────┐
│  Hive                                    [Dashboard] [+Agent] │
├───────────┬────────────────────────────────┬───────────────┤
│           │                                │               │
│  TOPICS   │    [topic:general]             │  MEMBERS      │
│  ─────    │                                │  ─────────    │
│  general  │  researcher: I found that      │  ● researcher │
│  project  │  RAPTOR outperforms...         │  ● librarian  │
│  bondi    │                                │  ○ coder      │
│           │  human: Can you look into      │    (idle)     │
│  DMs      │  that more?                    │               │
│  ─────    │                                │  CONTAINERS   │
│  research │  librarian: Stored under       │  ─────────    │
│  ↔libr.   │  projects/bondi/findings/...   │  hive-coder-  │
│  coder    │                                │  42 (3m12s)   │
│  ↔research│  [thinking...] researcher      │  [kill] [view]│
│           │                                │               │
│           │  ┌──────────────────────────┐  │               │
│           │  │ Type a message... @      │  │               │
│           │  └──────────────────────────┘  │               │
└───────────┴────────────────────────────────┴───────────────┘
```

### Views

**1. Chat View (topics + DMs unified)**
- Left sidebar: topics section + DMs section, with unread counts
- Center: messages chronologically, with sender labels and timestamps
- Right sidebar: members with live status indicators, active containers with kill/view buttons
- @autocomplete in input box
- All DM channels visible — you can inspect any agent-to-agent conversation

**2. Dashboard**
- Agent cards: name, description, status (:idle/:thinking), topic count
- Container cards: agent, task description, uptime, output preview, kill button
- Quick actions: restart agent, create new agent, create new topic
- Token/compaction stats per agent (if available from Claude Code)

**3. Agent Editor**
- Create/edit agent name, description
- CLAUDE.md editor (personality, objectives, rules)
- Name validation (real-time feedback: format check + uniqueness check)
- **MCP Server assignment:** checkboxes for installed MCP servers. Check to assign, uncheck to remove. Per-assignment **allowed tools** list: every tool must be explicitly granted (default is empty — no tools). Changing assignments restarts the agent's Claude Code subprocess.
- Delete agent with confirmation

**4. MCP Server Manager**
- List installed MCP servers with name, description, command, args
- Add new: name, description, command, args (JSON array), env vars (JSON object)
- Edit existing MCP server configuration
- Delete (with warning if currently assigned to agents)
- Shows which agents each MCP server is assigned to

**5. Container Live View**
- When you click "view" on a container, see streaming stdout in real-time
- Piped from the Container GenServer's output buffer via PubSub

### Real-time Wiring

```elixir
# Agent status
Phoenix.PubSub.broadcast(Hive.PubSub, "agents", {:status, name, status})

# New message in topic/DM
Phoenix.PubSub.broadcast(Hive.PubSub, "topic:#{name}", {:message, msg})

# Container events
Phoenix.PubSub.broadcast(Hive.PubSub, "containers", {:started, agent, id, task})
Phoenix.PubSub.broadcast(Hive.PubSub, "containers", {:stopped, id, reason})
Phoenix.PubSub.broadcast(Hive.PubSub, "container:#{id}", {:output, data})

# Registry changes
Phoenix.PubSub.broadcast(Hive.PubSub, "registry", {:agent_added, name, desc})
Phoenix.PubSub.broadcast(Hive.PubSub, "registry", {:topic_created, name, by})
```

LiveView subscribes to relevant PubSub topics. Open a chat → subscribe to `"topic:general"`. Open dashboard → subscribe to `"agents"` + `"containers"`. View a container → subscribe to `"container:#{id}"`.

---

## Part 4: Distributed (Multi-Device)

Once single-node works:

1. Each device runs a Hive node: `iex --name hive@192.168.1.2 -S mix phx.server`
2. Connect over VPN: `Node.connect(:"hive@192.168.1.5")`
3. Use `libcluster` for automatic peer discovery on VPN subnet
4. PubSub already supports distributed Erlang — messages route across nodes automatically
5. Registry goes distributed via `:global` or `Phoenix.Tracker`
6. Agents live on any node. @mention an agent on another device → message routes transparently
7. Containers run on the agent's local node (Docker is local to each machine)
8. Web UI on any node shows the full system state

~20 lines of config. No code changes.

---

## Part 5: Docker Image

**hive-claude-code:latest** — the container image used for execution tasks.

```dockerfile
FROM node:22-slim

# Install Claude Code CLI (native binary)
# TODO: Pin to specific version + verify checksum for reproducible builds
RUN curl -fsSL https://claude.ai/install.sh | bash

# Install common tools agents might need
RUN apt-get update && apt-get install -y \
    git curl wget jq ripgrep \
    python3 python3-pip \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Entrypoint is claude with --dangerously-bypass-permissions
# The actual prompt is passed via -p flag by Hive
ENTRYPOINT ["claude", "--dangerously-bypass-permissions"]
```

Build once: `docker build -t hive-claude-code:latest -f docker/Dockerfile.claude-code .`

Every `execute_in_container` call runs:
```
docker run --rm --name hive-{agent}-{id} \
  --env ANTHROPIC_API_KEY=... \
  --network bridge \
  hive-claude-code:latest \
  -p "{task prompt}" --output-format json
```

---

## Implementation Phases

### Phase 0: Bootstrap (day 1)
- `mix phx.new hive --no-ecto --no-mailer --no-dashboard`
- Add deps: `exqlite`, `req`, `jason`, `plug_crypto`
- SQLite schema + WAL mode + single writer GenServer
- Build `hive-claude-code` Docker image
- Skeleton project structure
- Set up Node Agent SDK subprocess wrapper (`npm install @anthropic-ai/claude-agent-sdk`) + stdio MCP bridge
- Input validation module

### Phase 1: Core — agents talk (days 2-4)
- `Hive.Agent` GenServer with Claude Code subprocess management
- Hive Tools API endpoint with HMAC auth
- stdio MCP bridge script
- `Hive.Topic` GenServer with broadcast, @mention detection, DM support (canonical naming)
- `Hive.Registry` using Elixir's built-in Registry (separate :agent/:topic namespaces)
- Persistence layer (SQLite via single writer)
- Hard-code 2-3 test agents, one topic
- Test in IEx: send messages, watch agents talk to each other and DM
- Session persistence + crash recovery (resume)
- Agent restart context (last 5 messages from subscribed topics)

### Phase 2: Web UI (days 5-6)
- Phoenix LiveView unified chat view (topics + DMs)
- Agent dashboard with status cards
- Agent editor (CRUD from UI, with name validation)
- PubSub wiring for real-time
- Tailwind CSS via CDN

### Phase 3: Container execution (days 7-8)
- `Hive.Container` GenServer under `ContainerSup`
- Fire-and-forget tool: immediate return + background monitoring
- Output buffering + `check_execution` tool
- Per-agent limit (16 containers)
- Timeout handling with atomic status transitions
- System notification injection on container exit
- Container live view in UI (streaming output)
- Kill button
- Orphan cleanup on startup

### Phase 4: MCP management (days 9-10)
- MCP server CRUD (install, edit, delete) in persistence + UI
- MCP-to-agent assignment in persistence + Agent Editor UI
- Dynamic MCP config generation on agent start
- Test with example: install obsidian-mcp, assign to agents, set up librarian
- Document the extension pattern (install MCP → assign → update CLAUDE.md)

### Phase 5: Polish and distribute (day 11+)
- `libcluster` for multi-node auto-discovery
- Docker image for Hive itself (for easy deployment on other devices)
- Logging, error handling, graceful shutdown
- Global container concurrency limit (in addition to per-agent)
- Agent-created topics fully tested
- Multiple simultaneous containers per agent

---

## File Structure

```
hive/
├── lib/
│   ├── hive/
│   │   ├── agent.ex              # Agent GenServer + Claude Code subprocess (~250 lines)
│   │   ├── topic.ex              # Topic/DM GenServer (~150 lines)
│   │   ├── registry.ex           # Agent/topic registry (~40 lines)
│   │   ├── container.ex          # Container GenServer (Port, buffer, timeout) (~180 lines)
│   │   ├── persistence.ex        # SQLite single writer + read queries (~120 lines)
│   │   ├── validation.ex         # Name validation (~20 lines)
│   │   └── application.ex        # Supervision tree (~50 lines)
│   └── hive_web/
│       ├── controllers/
│       │   └── tools_controller.ex  # Hive Tools API endpoint (~80 lines)
│       ├── live/
│       │   ├── chat_live.ex         # Unified topic + DM chat view
│       │   ├── dashboard_live.ex    # Agent + container dashboard
│       │   ├── agent_editor_live.ex  # Agent CRUD + MCP assignment
│       │   ├── mcp_servers_live.ex  # MCP server management
│       │   └── container_live.ex    # Streaming container output view
│       └── router.ex
├── sdk/
│   ├── hive_agent.js              # Claude Agent SDK subprocess wrapper (~80 lines)
│   └── hive_mcp_bridge.js         # stdio MCP bridge → Hive Tools API (~60 lines)
├── agents/                         # Example CLAUDE.md files (reference only — actual CLAUDE.md
│   │                               #   is generated from DB personality field by write_claude_md)
│   ├── librarian/
│   │   └── CLAUDE.md
│   ├── researcher/
│   │   └── CLAUDE.md
│   └── coder/
│       └── CLAUDE.md
├── docker/
│   └── Dockerfile.claude-code     # Container image with Claude Code
├── priv/
│   ├── sqlite/
│   │   └── schema.sql
│   ├── shared/                    # Shared resources (opt-in)
│   │   └── vault/                 # Obsidian vault (if using knowledge base extension)
│   └── agents/                    # Per-agent working dirs (session data, CLAUDE.md, skills)
│       ├── librarian/
│       │   ├── CLAUDE.md
│       │   └── .claude/skills/    # Agent's own skills (auto-discovered by SDK)
│       ├── researcher/
│       └── coder/
├── config/
│   ├── config.exs
│   └── runtime.exs                # API key, MCP secrets
└── mix.exs
```

---

## Key Design Decisions

1. **Everything is a tool call.** Agents act only through MCP tools. No text parsing, no regex, no structured output schemas. Claude Code handles the tool loop natively.

2. **Claude Agent SDK with subscription.** No per-token costs. Compaction is automatic and free. CLAUDE.md and skills loaded via `settingSources: ["project"]`. Session persistence enables crash recovery. MCP integration is built-in. Skills auto-discovered from agent's `.claude/skills/` directory.

3. **Single Tools API, per-agent stdio MCP bridge.** One Phoenix endpoint handles all tool calls. Each agent's Claude Code subprocess spawns a lightweight stdio MCP bridge that forwards tool calls to the API with HMAC auth. No per-agent HTTP ports, no port management, no exposed MCP servers.

4. **Fire-and-forget execution with independent Container GenServers.** Agents don't block on container tasks. Containers are supervised independently — if an agent crashes, its containers keep running. Per-agent limit of 16 prevents runaway spawning. Timeout races are eliminated via atomic status transitions in the GenServer.

5. **Context is protected at every level.** Claude Code compaction for conversation management. No history dumps on topic join (last 5 messages only). Container context is completely isolated and destroyed. Tool results (like topic history) are temporary and get compacted away. Loop prevention via system prompt.

6. **DMs and topics are the same thing.** Same GenServer, same persistence, same UI component. DMs are just two-party topics with canonical alphabetical naming (`dm:a:b`). The human sees all channels.

7. **Agents self-organize.** They can create topics, invite agents, leave topics. Emergent team structures are possible — a lead agent creates a project topic and pulls in specialists.

8. **Pluggable MCP servers per agent with tool-level access control.** MCP servers are installed system-wide and assigned to agents via the UI. Each assignment has an `allowed_tools` list — every tool must be explicitly granted (default empty). No wildcards. Assignments stored in SQLite, MCP config regenerated on agent restart. This is the extension mechanism — the Obsidian vault example (Part 2) is built entirely on top of it.

9. **--dangerously-bypass-permissions in containers.** Claude Code runs fully autonomous inside Docker. The container IS the security boundary. No permission prompts, no human-in-the-loop inside execution tasks.

10. **Crash = resume + catch up.** Agent crashes → supervisor restarts → resumes Claude Code session from disk → catches up with last 5 messages from each subscribed topic. Running containers are unaffected (independent GenServers).

11. **Shared namespace, strict validation.** Agent and topic names share a namespace — no duplicates across either. Names must match `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$`. DM channels use `dm:a:b` format (contains colons, can't collide). This makes @mentions and tool references unambiguous.

12. **SQLite with WAL + single writer.** All writes serialized through one GenServer — no `SQLITE_BUSY` contention ever. WAL mode allows concurrent reads from other processes. PRAGMAs tuned for durability + performance. Uniqueness checks run inside the writer (no TOCTOU races).

13. **Agents self-modify via Hive tools.** `write_skill`, `read_skill`, `delete_skill`, `write_claude_md` — scoped to the calling agent's own directory. Skills are SKILL.md files auto-discovered by the SDK. CLAUDE.md changes are persisted back to SQLite so they survive restart.

14. **Stable identity vs. volatile context.** CLAUDE.md (personality, objectives, rules) is the agent's stable identity — editable by the agent, loaded from disk. Dynamic context (Other Agents, Your Topics) is injected via the SDK's `systemPrompt` option, refreshed each turn, and managed by Hive. This prevents agents from accidentally overwriting dynamic sections when modifying their own CLAUDE.md.
