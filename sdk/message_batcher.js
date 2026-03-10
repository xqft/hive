// Extracted from hive_agent.js for testability.
// Batches stdin lines using setImmediate so multi-line messages
// from a single Port.command arrive as one batch.

export function createBatcher(onBatch) {
  let pending = [];
  let processing = false;
  let flushScheduled = false;
  let midTurnHandler = null;

  function pushLine(line) {
    pending.push(line);
    if (!flushScheduled) {
      flushScheduled = true;
      setImmediate(() => {
        flushScheduled = false;
        if (processing && midTurnHandler) {
          // Mid-turn: route to streamInput instead of queueing
          const msg = pending.splice(0, pending.length).join("\n");
          midTurnHandler(msg);
        } else if (!processing && pending.length > 0) {
          flush();
        }
      });
    }
  }

  function flush() {
    if (pending.length === 0) {
      processing = false;
      onBatch(null); // null signals idle
      return;
    }

    processing = true;
    const batch = pending.splice(0, pending.length).join("\n");

    // onBatch returns a promise (or thenable) for async processing
    Promise.resolve(onBatch(batch)).then(() => {
      flush();
    }).catch(() => {
      flush();
    });
  }

  return {
    pushLine,
    isProcessing: () => processing,
    setMidTurnHandler(fn) { midTurnHandler = fn; },
    clearMidTurnHandler() { midTurnHandler = null; },
  };
}
