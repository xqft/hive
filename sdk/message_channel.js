// Async iterable channel for mid-turn message injection.
// Bridges push-based stdin messages to the pull-based streamInput API.

export function createChannel() {
  let resolve = null;
  const queue = [];
  let closed = false;

  return {
    push(value) {
      if (closed) return;
      if (resolve) {
        const r = resolve;
        resolve = null;
        r({ value, done: false });
      } else {
        queue.push(value);
      }
    },

    close() {
      closed = true;
      if (resolve) resolve({ done: true });
    },

    [Symbol.asyncIterator]() {
      return {
        next() {
          if (queue.length > 0)
            return Promise.resolve({ value: queue.shift(), done: false });
          if (closed) return Promise.resolve({ done: true });
          return new Promise((r) => {
            resolve = r;
          });
        },
        return() {
          closed = true;
          return Promise.resolve({ done: true });
        },
      };
    },
  };
}
