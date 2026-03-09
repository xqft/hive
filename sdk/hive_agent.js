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

// ---------------------------------------------------------------------------
// Helpers for streaming intermediate events to Elixir
// ---------------------------------------------------------------------------

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function createDebouncer(buildMsg, delay = 100) {
  let timer = null;
  let accumulated = "";

  function push(text) {
    accumulated += text;
    if (timer) clearTimeout(timer);
    timer = setTimeout(flush, delay);
  }

  function flush() {
    if (timer) { clearTimeout(timer); timer = null; }
    if (accumulated) {
      emit(buildMsg(accumulated));
      accumulated = "";
    }
  }

  return { push, flush };
}

// ---------------------------------------------------------------------------

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
      "mcp__hive__create_agent", "mcp__hive__delete_agent",
      "mcp__hive__write_skill", "mcp__hive__read_skill", "mcp__hive__delete_skill",
      "mcp__hive__write_claude_md",
      "mcp__hive__upload_media", "mcp__hive__view_image"
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
      settings: { effortLevel: "max" },
      systemPrompt,
      includePartialMessages: true,
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

    // Tracking state for stream events
    let currentToolInput = "";
    let currentToolName = "";
    let currentToolUseId = "";

    const thinkingDebouncer = createDebouncer(
      (text) => ({ type: "thinking", text }),
      100
    );
    const textDebouncer = createDebouncer(
      (text) => ({ type: "text", text }),
      100
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

      // --- Stream event handling (intermediate events for scratchpad) ---
      if (event.type === "stream_event" && event.event) {
        const raw = event.event;

        if (raw.type === "content_block_start" && raw.content_block?.type === "tool_use") {
          currentToolName = raw.content_block.name || "";
          currentToolUseId = raw.content_block.id || "";
          currentToolInput = "";
          emit({ type: "tool_use_start", toolName: currentToolName, toolInput: {}, toolUseId: currentToolUseId });
        } else if (raw.type === "content_block_delta") {
          if (raw.delta?.type === "thinking_delta") {
            thinkingDebouncer.push(raw.delta.thinking || "");
          } else if (raw.delta?.type === "text_delta") {
            textDebouncer.push(raw.delta.text || "");
          } else if (raw.delta?.type === "input_json_delta") {
            currentToolInput += (raw.delta.partial_json || "");
          }
        } else if (raw.type === "content_block_stop") {
          // Flush any pending text/thinking
          thinkingDebouncer.flush();
          textDebouncer.flush();
          // If we accumulated tool input, emit updated tool_use_start with full input
          if (currentToolInput && currentToolUseId) {
            let parsedInput = {};
            try { parsedInput = JSON.parse(currentToolInput); } catch (_) {}
            emit({ type: "tool_use_start", toolName: currentToolName, toolInput: parsedInput, toolUseId: currentToolUseId });
          }
          currentToolInput = "";
          currentToolName = "";
          currentToolUseId = "";
        }
      }

      // --- tool_result events from SDK ---
      if (event.type === "tool_result") {
        const output = event.output || event.content || "";
        emit({ type: "tool_result", toolUseId: event.toolUseId || event.tool_use_id || "", output: typeof output === "string" ? output : JSON.stringify(output) });
      }

      // --- Existing session / result handling ---
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
        // Flush any remaining debounced content at end of turn
        thinkingDebouncer.flush();
        textDebouncer.flush();

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
