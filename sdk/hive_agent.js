// sdk/hive_agent.js — spawned by the Elixir GenServer
import { query } from "@anthropic-ai/claude-agent-sdk";
import * as readline from "readline";
import * as fs from "fs";

const agentName = process.argv[2];
const mcpConfigPath = process.argv[3];
const agentDir = process.argv[4]; // priv/agents/{name}/
const systemPromptPath = process.argv[5]; // path to dynamic context
const resumeSessionId = process.argv[6] || null;

const mcpConfig = JSON.parse(fs.readFileSync(mcpConfigPath, "utf8"));
let sessionId = resumeSessionId;

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

  const batch = pending.splice(0, pending.length).join("\n");

  try {
    // Build allowedTools
    const hiveTools = [
      "mcp__hive__send_message", "mcp__hive__send_dm",
      "mcp__hive__create_topic", "mcp__hive__join_topic",
      "mcp__hive__leave_topic", "mcp__hive__get_topic_history",
      "mcp__hive__list_agents", "mcp__hive__list_topics",
      "mcp__hive__execute_in_container", "mcp__hive__check_execution",
      "mcp__hive__write_skill", "mcp__hive__read_skill", "mcp__hive__delete_skill",
      "mcp__hive__write_claude_md"
    ];

    const extraToolPatterns = [];
    for (const [name, tools] of Object.entries(mcpConfig.toolFilters || {})) {
      for (const tool of tools) {
        extraToolPatterns.push(`mcp__${name}__${tool}`);
      }
    }

    // Read dynamic context
    let dynamicContext = "";
    try {
      dynamicContext = fs.readFileSync(systemPromptPath, "utf8");
    } catch (e) {
      // File might not exist yet on first run
    }

    const options = {
      systemPrompt: dynamicContext,
      allowedTools: ["Skill", ...hiveTools, ...extraToolPatterns],
      settingSources: ["project"],
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

  processNext();
}
