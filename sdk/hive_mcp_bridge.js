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
  { name: "send_message", description: "Post a message to a topic. Defaults to the active topic if omitted.",
    inputSchema: { type: "object", properties: {
      topic: { type: "string", description: "Topic name to post to (defaults to active topic)" },
      text: { type: "string", description: "Message text" }
    }, required: ["text"] }},
  { name: "send_dm", description: "Send a direct message to another agent or the human user.",
    inputSchema: { type: "object", properties: {
      to: { type: "string", description: "Recipient name (agent name or 'human')" },
      text: { type: "string", description: "Message text" }
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
  { name: "delete_topic", description: "Permanently delete a topic and all its messages",
    inputSchema: { type: "object", properties: {
      topic: { type: "string", description: "Topic name to delete" }
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
  { name: "create_agent", description: "Create a new agent. The agent starts immediately.",
    inputSchema: { type: "object", properties: {
      name: { type: "string", description: "Agent name (alphanumeric, hyphens, underscores)" },
      description: { type: "string", description: "What this agent does" },
      personality: { type: "string", description: "Agent personality/instructions (becomes CLAUDE.md)" }
    }, required: ["name"] }},
  { name: "delete_agent", description: "Delete an agent permanently, including its working directory.",
    inputSchema: { type: "object", properties: {
      name: { type: "string", description: "Agent name to delete" }
    }, required: ["name"] }},
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
  { name: "upload_media", description: "Upload a base64-encoded file. Returns a URL. For images use ![alt](url), for other files use [filename](url) in send_message/send_dm.",
    inputSchema: { type: "object", properties: {
      data: { type: "string", description: "Base64-encoded file data" },
      media_type: { type: "string", description: "MIME type of the file (e.g. image/png, application/pdf, text/plain)" },
      filename: { type: "string", description: "Original filename (optional, used for display)" }
    }, required: ["data", "media_type"] }},
  { name: "view_image", description: "View an uploaded file by URL. Returns images visually; returns other files as base64.",
    inputSchema: { type: "object", properties: {
      url: { type: "string", description: "File URL (e.g. /uploads/abc.png)" }
    }, required: ["url"] }},
  { name: "tmux_send", description: "Send text and/or keys to the workspace terminal. Set wait_ms > 0 to wait and return terminal output in one call. Use this instead of Bash for running commands.",
    inputSchema: { type: "object", properties: {
      text: { type: "string", description: "Text to type (literal characters)" },
      keys: { type: "string", description: "Special key: Enter, C-c, C-d, Up, Down, Tab, Escape, etc." },
      wait_ms: { type: "number", description: "Ms to wait then return screen content (0 = fire-and-forget, default 0)" }
    }}},
  { name: "tmux_read", description: "Read the current terminal screen content without sending input. Useful to check on long-running commands or see current state.",
    inputSchema: { type: "object", properties: {
      wait: { type: "number", description: "Ms to wait before reading (default 1000, max 30000)" }
    }}},
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

    // view_image returns an image content block for the agent to see
    if (name === "view_image" && data.ok && data.result && data.result.base64) {
      return { content: [{ type: "image", data: data.result.base64, mimeType: data.result.media_type }] };
    }

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
