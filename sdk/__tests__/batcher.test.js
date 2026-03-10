import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { createBatcher } from "../message_batcher.js";

// Helper: wait for setImmediate to fire
function nextTick() {
  return new Promise((resolve) => setImmediate(resolve));
}

// Helper: wait for multiple ticks to ensure all microtasks settle
async function settle(n = 3) {
  for (let i = 0; i < n; i++) await nextTick();
}

describe("message_batcher", () => {
  it("multi-line batch — pushes 5 lines synchronously, onBatch called once with all joined", async () => {
    const batches = [];
    let resolveProcessing;

    const batcher = createBatcher((batch) => {
      if (batch === null) return; // idle signal
      batches.push(batch);
      return new Promise((resolve) => { resolveProcessing = resolve; });
    });

    // Push 5 lines synchronously (simulates Port.command multi-line)
    batcher.pushLine("line 1");
    batcher.pushLine("line 2");
    batcher.pushLine("line 3");
    batcher.pushLine("line 4");
    batcher.pushLine("line 5");

    // Let setImmediate fire
    await settle();

    assert.equal(batches.length, 1, "should have exactly one batch");
    assert.equal(batches[0], "line 1\nline 2\nline 3\nline 4\nline 5");

    // Complete processing
    resolveProcessing();
    await settle();
  });

  it("sequential messages — push line, wait for callback, push next, get 2 batches", async () => {
    const batches = [];
    const resolvers = [];

    const batcher = createBatcher((batch) => {
      if (batch === null) return;
      batches.push(batch);
      return new Promise((resolve) => { resolvers.push(resolve); });
    });

    // First message
    batcher.pushLine("first");
    await settle();
    assert.equal(batches.length, 1);
    assert.equal(batches[0], "first");

    // Complete first processing
    resolvers[0]();
    await settle();

    // Second message
    batcher.pushLine("second");
    await settle();
    assert.equal(batches.length, 2);
    assert.equal(batches[1], "second");

    resolvers[1]();
    await settle();
  });

  it("overlapping — lines pushed while processing are queued and processed after", async () => {
    const batches = [];
    const resolvers = [];

    const batcher = createBatcher((batch) => {
      if (batch === null) return;
      batches.push(batch);
      return new Promise((resolve) => { resolvers.push(resolve); });
    });

    // First batch
    batcher.pushLine("batch1-line1");
    batcher.pushLine("batch1-line2");
    await settle();
    assert.equal(batches.length, 1);
    assert.equal(batches[0], "batch1-line1\nbatch1-line2");

    // Push more lines while first batch is still processing
    batcher.pushLine("batch2-line1");
    batcher.pushLine("batch2-line2");
    assert.ok(batcher.isProcessing(), "should still be processing first batch");

    // Complete first batch
    resolvers[0]();
    await settle();

    // Second batch should have been processed
    assert.equal(batches.length, 2);
    assert.equal(batches[1], "batch2-line1\nbatch2-line2");

    resolvers[1]();
    await settle();
  });

  it("empty lines — included in batch, not dropped", async () => {
    const batches = [];
    let resolveProcessing;

    const batcher = createBatcher((batch) => {
      if (batch === null) return;
      batches.push(batch);
      return new Promise((resolve) => { resolveProcessing = resolve; });
    });

    batcher.pushLine("before");
    batcher.pushLine("");
    batcher.pushLine("after");
    await settle();

    assert.equal(batches.length, 1);
    assert.equal(batches[0], "before\n\nafter");

    resolveProcessing();
    await settle();
  });

  it("idle signal — null sent after all processing completes", async () => {
    const calls = [];

    const batcher = createBatcher((batch) => {
      calls.push(batch);
      // Synchronous return (no promise) for simplicity
    });

    batcher.pushLine("hello");
    await settle(5);

    // Should see: batch "hello", then null (idle)
    assert.ok(calls.includes("hello"), "should have received the batch");
    assert.ok(calls.includes(null), "should have received idle signal");
  });

  it("mid-turn handler — messages during processing go to handler, not queue", async () => {
    const batches = [];
    const midTurnMessages = [];
    let resolveProcessing;

    const batcher = createBatcher((batch) => {
      if (batch === null) return;
      batches.push(batch);
      return new Promise((resolve) => { resolveProcessing = resolve; });
    });

    // Start processing first message
    batcher.pushLine("first");
    await settle();
    assert.equal(batches.length, 1);
    assert.equal(batches[0], "first");

    // Set mid-turn handler while processing
    batcher.setMidTurnHandler((msg) => midTurnMessages.push(msg));

    // Push messages while processing — should go to mid-turn handler
    batcher.pushLine("mid-turn-1");
    batcher.pushLine("mid-turn-2");
    await settle();

    assert.equal(midTurnMessages.length, 1, "mid-turn handler should receive one batched message");
    assert.equal(midTurnMessages[0], "mid-turn-1\nmid-turn-2");
    assert.equal(batches.length, 1, "no new batches should be created");

    // Complete processing
    resolveProcessing();
    await settle();
  });

  it("mid-turn handler cleared — messages queue normally again", async () => {
    const batches = [];
    const midTurnMessages = [];
    const resolvers = [];

    const batcher = createBatcher((batch) => {
      if (batch === null) return;
      batches.push(batch);
      return new Promise((resolve) => { resolvers.push(resolve); });
    });

    // Start processing
    batcher.pushLine("first");
    await settle();
    assert.equal(batches.length, 1);

    // Set then clear mid-turn handler
    batcher.setMidTurnHandler((msg) => midTurnMessages.push(msg));
    batcher.clearMidTurnHandler();

    // Push while processing — should queue for next batch (no handler)
    batcher.pushLine("queued");
    await settle();
    assert.equal(midTurnMessages.length, 0, "cleared handler should not receive messages");

    // Complete first batch — queued message should flush as next batch
    resolvers[0]();
    await settle();
    assert.equal(batches.length, 2);
    assert.equal(batches[1], "queued");

    resolvers[1]();
    await settle();
  });

  it("mid-turn handler — only active during processing", async () => {
    const batches = [];
    const midTurnMessages = [];

    const batcher = createBatcher((batch) => {
      if (batch === null) return;
      batches.push(batch);
    });

    // Set handler before any processing
    batcher.setMidTurnHandler((msg) => midTurnMessages.push(msg));

    // Push when not processing — should go through normal batch flow
    batcher.pushLine("normal");
    await settle(5);

    assert.equal(batches.length, 1, "should process normally when not in processing state");
    assert.equal(batches[0], "normal");
    assert.equal(midTurnMessages.length, 0, "handler should not be called when not processing");
  });
});
