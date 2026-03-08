#!/usr/bin/env node
// Mock SDK for Agent GenServer tests.
// Reads stdin lines, batches them (same setImmediate pattern as real SDK),
// writes predictable JSON responses to stdout.
// Writes received batches to stderr for test observability.

import * as readline from "readline";

const rl = readline.createInterface({ input: process.stdin });
let pending = [];
let processing = false;
let flushScheduled = false;

rl.on("line", (line) => {
  pending.push(line);
  if (!processing && !flushScheduled) {
    flushScheduled = true;
    setImmediate(() => {
      flushScheduled = false;
      if (!processing && pending.length > 0) processNext();
    });
  }
});

function processNext() {
  if (pending.length === 0) {
    processing = false;
    process.stdout.write(JSON.stringify({ type: "status", status: "idle" }) + "\n");
    return;
  }

  processing = true;
  process.stdout.write(JSON.stringify({ type: "status", status: "thinking" }) + "\n");

  const batch = pending.splice(0, pending.length).join("\n");

  // Write the received batch to stderr for test observability
  process.stderr.write(JSON.stringify({ type: "batch_received", content: batch }) + "\n");

  // Emit a session ID on first batch
  const sessionId = `mock-session-${Date.now()}`;
  process.stdout.write(JSON.stringify({ type: "session", sessionId }) + "\n");

  // Simulate brief processing, then go idle
  setImmediate(() => processNext());
}

rl.on("close", () => {
  process.exit(0);
});
