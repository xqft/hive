// sdk/hive_agent.js — spawned by the Elixir GenServer
import { query } from "@anthropic-ai/claude-agent-sdk";
import * as readline from "readline";
import * as fs from "fs";
import { createBatcher } from "./message_batcher.js";

const agentName = process.argv[2];
const mcpConfigPath = process.argv[3];
const agentDir = process.argv[4]; // priv/agents/{name}/
const systemPromptPath = process.argv[5]; // path to dynamic context
const resumeSessionId = process.argv[6] || null;

const mcpConfig = JSON.parse(fs.readFileSync(mcpConfigPath, "utf8"));
let sessionId = resumeSessionId;

const rl = readline.createInterface({ input: process.stdin });
const batcher = createBatcher(async (batch) => {
  if (batch === null) {
    process.stdout.write(JSON.stringify({ type: "status", status: "idle" }) + "\n");
    return;
  }
  process.stdout.write(JSON.stringify({ type: "status", status: "thinking" }) + "\n");
  await processNext(batch);
});
rl.on("line", (line) => batcher.pushLine(line));

async function processNext(batch) {

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

    // Read CLAUDE.md (agent identity/personality)
    let claudeMd = "";
    try {
      claudeMd = fs.readFileSync(`${agentDir}/CLAUDE.md`, "utf8");
    } catch (e) {
      // CLAUDE.md should always exist, but fallback gracefully
    }

    // Read dynamic context (other agents, topics)
    let dynamicContext = "";
    try {
      dynamicContext = fs.readFileSync(systemPromptPath, "utf8");
    } catch (e) {
      // File might not exist yet on first run
    }

    // Combine: CLAUDE.md identity + dynamic context
    const systemPrompt = claudeMd + "\n\n" + dynamicContext;

    const options = {
      model: "claude-opus-4-6",
      effort: "high",
      systemPrompt,
      allowedTools: ["Skill", ...hiveTools, ...extraToolPatterns],
      settingSources: [],  // Don't load filesystem settings, we provide everything
      mcpServers: Object.fromEntries(
        Object.entries(mcpConfig.mcpServers).map(([name, cfg]) => [
          name,
          {
            command: cfg.command,
            args: cfg.args,
            ...(cfg.env ? { env: cfg.env } : {})
          }
        ])
      ),
      cwd: agentDir,
      ...(sessionId ? { resume: sessionId } : {})
    };

    process.stderr.write(
      `[hive-sdk] starting turn agent=${agentName} resume_session=${sessionId || "new"}\n`
    );

    for await (const event of query({ prompt: batch, options })) {
      let extra = "";
      if (event.type === "system") {
        extra = ` mcp=${JSON.stringify(event.mcp_servers)} tools=${(event.tools||[]).filter(t=>t.startsWith("mcp")).join(",")}`;
      } else if (event.type === "result") {
        extra = ` is_error=${event.is_error} result=${JSON.stringify((event.result || "").slice(0, 500))}`;
      } else if (event.type === "rate_limit_event") {
        extra = ` ${JSON.stringify(event)}`;
      }
      process.stderr.write(`[hive-sdk] event: ${event.type} ${event.subtype || ""}${extra}\n`);
      const nextSessionId = event.sessionId || event.session_id;

      if (nextSessionId && nextSessionId !== sessionId) {
        sessionId = nextSessionId;
        process.stderr.write(
          `[hive-sdk] session updated agent=${agentName} session=${sessionId}\n`
        );
        process.stdout.write(
          JSON.stringify({ type: "session", sessionId }) + "\n"
        );
      }

      if (event.type === "result") {
        if (event.is_error) {
          process.stdout.write(
            JSON.stringify({ type: "error", message: event.result || "unknown SDK error" }) + "\n"
          );
        }
      }
    }
  } catch (err) {
    process.stdout.write(
      JSON.stringify({ type: "error", message: err.message }) + "\n"
    );
  }
}
