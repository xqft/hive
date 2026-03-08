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
});
