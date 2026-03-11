// Extracted from hive_agent.js for testability.
// Batches stdin lines using setImmediate so multi-line messages
// from a single Port.command arrive as one batch.

export function createBatcher(onBatch) {
  let pending = [];
  let processing = false;
  let flushScheduled = false;
  let midTurnHandler = null;
  let injectedCount = 0;

  function pushLine(line) {
    pending.push(line);
    if (!flushScheduled) {
      flushScheduled = true;
      setImmediate(() => {
        flushScheduled = false;
        if (processing && midTurnHandler) {
          // Mid-turn: inject new messages without removing from pending
          const newMessages = pending.slice(injectedCount);
          if (newMessages.length > 0) {
            midTurnHandler(newMessages.join("\n"));
            injectedCount = pending.length;
          }
        } else if (!processing && pending.length > 0) {
          flush();
        }
      });
    }
  }

  function flush() {
    injectedCount = 0;
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
