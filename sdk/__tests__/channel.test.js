import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createChannel } from "../message_channel.js";

describe("message_channel", () => {
  it("push before pull — values are queued and returned in order", async () => {
    const ch = createChannel();
    ch.push("a");
    ch.push("b");
    ch.push("c");

    const iter = ch[Symbol.asyncIterator]();
    assert.deepEqual(await iter.next(), { value: "a", done: false });
    assert.deepEqual(await iter.next(), { value: "b", done: false });
    assert.deepEqual(await iter.next(), { value: "c", done: false });
  });

  it("pull before push — next() resolves when push is called", async () => {
    const ch = createChannel();
    const iter = ch[Symbol.asyncIterator]();

    const pending = iter.next();
    ch.push("delayed");

    assert.deepEqual(await pending, { value: "delayed", done: false });
  });

  it("close — pending next() resolves with done", async () => {
    const ch = createChannel();
    const iter = ch[Symbol.asyncIterator]();

    const pending = iter.next();
    ch.close();

    const result = await pending;
    assert.equal(result.done, true);
  });

  it("close after push — queued values are still returned before done", async () => {
    const ch = createChannel();
    ch.push("x");
    ch.close();

    const iter = ch[Symbol.asyncIterator]();
    assert.deepEqual(await iter.next(), { value: "x", done: false });

    const result = await iter.next();
    assert.equal(result.done, true);
  });

  it("return() — terminates iteration", async () => {
    const ch = createChannel();
    const iter = ch[Symbol.asyncIterator]();

    ch.push("a");
    assert.deepEqual(await iter.next(), { value: "a", done: false });

    await iter.return();
    const result = await iter.next();
    assert.equal(result.done, true);
  });

  it("push after close — values are silently dropped", async () => {
    const ch = createChannel();
    ch.close();
    ch.push("ignored");

    const iter = ch[Symbol.asyncIterator]();
    const result = await iter.next();
    assert.equal(result.done, true);
  });

  it("for-await-of — works with channel", async () => {
    const ch = createChannel();
    ch.push(1);
    ch.push(2);
    ch.push(3);
    ch.close();

    const collected = [];
    for await (const val of ch) {
      collected.push(val);
    }

    assert.deepEqual(collected, [1, 2, 3]);
  });

  it("object values — works with SDK message objects", async () => {
    const ch = createChannel();
    const msg = {
      type: "user",
      message: { role: "user", content: [{ type: "text", text: "hello" }] },
      parent_tool_use_id: null,
      session_id: "test-session",
    };

    ch.push(msg);
    ch.close();

    const iter = ch[Symbol.asyncIterator]();
    const result = await iter.next();
    assert.deepEqual(result.value, msg);
  });
});
