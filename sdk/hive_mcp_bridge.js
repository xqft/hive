// sdk/hive_mcp_bridge.js — spawned by Claude Code as stdio MCP server
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const agentName = process.argv[2];
const secret = process.argv[3];
const hiveUrl = process.argv[4] || "http://localhost:4000";

const TOOLS = [
  { name: "send_message", description: "Post a message to the active topic. topic is optional when replying in the current topic context.",
    inputSchema: { type: "object", properties: {
      topic: { type: "string", description: "Topic name to post to" },
      text: { type: "string", description: "Message text" }
    }, required: ["text"] }},
  { name: "send_dm", description: "Send a direct message to another agent or 'human'. If the current turn came from a topic, include reason to make the out-of-band DM explicit.",
    inputSchema: { type: "object", properties: {
      to: { type: "string", description: "Agent name or 'human'" },
      text: { type: "string", description: "Message text" },
      reason: { type: "string", description: "Required when sending a DM from a topic-triggered turn" }
    }, required: ["text"] }},
  { name: "create_topic", description: "Create a new topic, optionally invite agents",
    inputSchema: { type: "object", properties: {
      name: { type: "string", description: "Topic name" },
      description: { type: "string", description: "Topic description" },
      invite: { type: "array", items: { type: "string" }, description: "Agent names to invite" }
    }, required: ["name"] }},
  { name: "join_topic", description: "Join an existing topic",
    inputSchema: { type: "object", properties: {
      topic: { type: "string" }
    }, required: ["topic"] }},
  { name: "leave_topic", description: "Leave a topic",
    inputSchema: { type: "object", properties: {
      topic: { type: "string" }
    }, required: ["topic"] }},
  { name: "get_topic_history", description: "Read last N messages (max 50) from a topic",
    inputSchema: { type: "object", properties: {
      topic: { type: "string" },
      n: { type: "number", description: "Number of messages (default 20, max 50)" }
    }, required: ["topic"] }},
  { name: "list_agents", description: "List all agents with names, descriptions, and status",
    inputSchema: { type: "object", properties: {} }},
  { name: "list_topics", description: "List all topics with descriptions and subscriber counts",
    inputSchema: { type: "object", properties: {} }},
  { name: "execute_in_container", description: "Launch an isolated Docker container with a bash shell in a tmux session. Use send_to_container to run commands interactively. For coding tasks, start Claude Code with: send_to_container(id, 'claude --dangerously-skip-permissions'). You'll be notified when the container exits or times out.",
    inputSchema: { type: "object", properties: {
      task: { type: "string", description: "Optional label describing what this container is for (for tracking)" },
      timeout_minutes: { type: "number", description: "Timeout in minutes (default 10, max 60)" }
    } }},
  { name: "check_execution", description: "Check container status and recent terminal output",
    inputSchema: { type: "object", properties: {
      container_id: { type: "string" }
    }, required: ["container_id"] }},
  { name: "send_to_container", description: "Send input to a container's tmux session. Use 'input' for shell commands (auto-appends Enter). Use 'keys' for raw key sequences (e.g. 'Enter', 'C-c', 'Up', 'Down'). Can target specific tmux windows.",
    inputSchema: { type: "object", properties: {
      container_id: { type: "string", description: "Container ID" },
      input: { type: "string", description: "Text to type followed by Enter (for shell commands)" },
      keys: { type: "string", description: "Raw tmux key names, space-separated (e.g. 'Enter', 'C-c', 'Up Up Enter'). Use for TUI navigation." },
      window: { type: "string", description: "Target tmux window index (default '0')" }
    }, required: ["container_id"] }},
  { name: "capture_container_output", description: "Capture the current terminal output from a container's tmux session. Use to check what's on screen.",
    inputSchema: { type: "object", properties: {
      container_id: { type: "string", description: "Container ID" },
      window: { type: "string", description: "Target tmux window index (default '0')" }
    }, required: ["container_id"] }},
  { name: "container_new_window", description: "Create a new tmux window in a container",
    inputSchema: { type: "object", properties: {
      container_id: { type: "string", description: "Container ID" },
      name: { type: "string", description: "Window name" },
      command: { type: "string", description: "Command to run in new window" }
    }, required: ["container_id", "name"] }},
  { name: "container_list_windows", description: "List tmux windows in a container",
    inputSchema: { type: "object", properties: {
      container_id: { type: "string", description: "Container ID" }
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

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: params } = request.params;
  try {
    const res = await fetch(`${hiveUrl}/api/tools`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${secret}`
      },
      body: JSON.stringify({ agent: agentName, tool: name, params: params || {} })
    });
    const data = await res.json();
    const text = data.ok
      ? (typeof data.result === "string" ? data.result : JSON.stringify(data.result, null, 2))
      : `Error: ${data.error}`;
    return { content: [{ type: "text", text }] };
  } catch (err) {
    return { content: [{ type: "text", text: `Error: ${err.message}` }] };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
