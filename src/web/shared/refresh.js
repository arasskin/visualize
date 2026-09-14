export function refreshLoop({enabled = () => true, load, apply, error = () => {}, interval = 1000}) {
  let stopped = false, epoch = 0, pending = null, running = null, timer = null;
  function invalidate() { ++epoch; pending?.abort(); }
  function refresh(force = false) {
    if (stopped) return Promise.resolve();
    if (running) return force ? running.then(() => refresh(true)) : running;
    clearTimeout(timer);
    const revision = epoch;
    pending = new AbortController();
    running = (async () => {
      if (!force && !enabled()) return;
      try {
        const result = await load(pending.signal);
        if (!stopped && epoch === revision) apply(result);
      } catch (fault) {
        if (!stopped && epoch === revision && fault.name !== 'AbortError') error(fault);
      }
    })().finally(() => {
      running = null;
      if (!stopped) timer = setTimeout(refresh, interval);
    });
    return running;
  }
  refresh();
  return {refresh, invalidate, stop() { stopped = true; invalidate(); clearTimeout(timer); }};
}
