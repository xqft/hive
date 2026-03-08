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
  { name: "execute_in_container", description: "Launch isolated Claude Code in Docker for code/file/bash/web tasks. Fire-and-forget — you'll be notified when done.",
    inputSchema: { type: "object", properties: {
      task: { type: "string", description: "Task description" },
      repo: { type: "string", description: "Git repo URL to clone" },
      files: { type: "string", description: "Relevant files to focus on" },
      context: { type: "string", description: "Additional context" },
      timeout_minutes: { type: "number", description: "Timeout in minutes (default 10)" }
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
