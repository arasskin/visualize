// Windows: the panels that float over the drawing, the terminal panes inside
// them, and the rail of tabs they hang from.
//
// ONE MODULE BECAUSE THEY ARE ONE THING. A panel is a window and a tab; the
// rail decides where the tab sits and the pane decides what the window shows,
// and each of the three calls the other two. Split into three files they
// would import in a circle, which is a way of saying they are not three.
//
// INDEPENDENT OF THE DRAWING. Nothing here resizes the graph and nothing here
// asks where the graph is. A window covers some of it and the drawing does
// not flinch -- they share a page and a z-order and nothing else.
//
// WHAT IT NEEDS FROM THE EDITOR is handed over by app.js at startup rather
// than imported: the config panel is a panel, so this would import the editor
// and the editor would import this.

import { makeTerminal, keyToBytes } from './term.js';
import { pane, fit, isTouched } from './graph.js';

// Set by `wire`, at startup, once everything exists.
let deps = {};
export function wire(parts) { Object.assign(deps, parts); }

// -- floating panels ---------------------------------------------------------
// A panel is a title bar you can drag, a body, and a grip in the corner. Click
// the bar and it collapses into just the bar -- so the same element is both
// the window and the button that opens it, and there is no separate toggle to
// keep in sync with it.
//
// Written once and used twice: the config editor and the harness terminal are
// the same furniture with different contents. A second copy of this logic
// would be a second place for the drag-versus-click rule to drift.

// Every panel that can be driven, by its root element -- a selection is a
// DOM node and the thing that opens and shuts is an object, so one has to
// find the other. Declared HERE, above the function that fills it: the
// config's panel is made while this file is still evaluating, so a `const`
// further down would be in its dead zone and throw on the way past.
const panelsByRoot = new Map();

export function makePanel(root, options = {}) {
  const bar = root.querySelector('.bar');
  const body = root.querySelector('.panel-body');
  const grip = root.querySelector('.grip');

  // Dragging the bar moves the panel; dragging the grip resizes it. Both are
  // the same gesture with a different thing on the end, so they share one
  // pointer-capture path.
  function grab(handle, onMove, onDrop) {
    handle.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();
      // Whichever panel you touched comes to the front. Without this the one
      // that happens to be later in the document always wins, and a panel can
      // hide under another with no way to raise it.
      raise(root);
      const box = root.getBoundingClientRect();
      const from = { x: e.clientX, y: e.clientY, w: box.width, h: box.height,
                     left: box.left, top: box.top, at: performance.now() };
      let moved = false;
      handle.setPointerCapture(e.pointerId);
      const move = (m) => {
        const dx = m.clientX - from.x, dy = m.clientY - from.y;
        // A few pixels of slop, so a click that wobbles still counts as a click.
        if (Math.abs(dx) > 3 || Math.abs(dy) > 3) moved = true;
        if (moved) onMove(dx, dy, from);
      };
      const drop = () => {
        handle.removeEventListener('pointermove', move);
        handle.removeEventListener('pointerup', drop);
        handle.removeEventListener('pointercancel', drop);
        handle.dragged = moved;
        if (onDrop) onDrop(moved);
      };
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', drop);
      handle.addEventListener('pointercancel', drop);
    });
  }

  // Keep the panel reachable: at least a bar's worth has to stay on screen, or
  // it can be dragged somewhere it can never be grabbed again.
  // `free` skips the clamp. The clamp is there so a DRAGGED panel cannot be
  // put somewhere it can never be grabbed again; a scrolled row is moving
  // tabs off the side on purpose, and they come back by scrolling the other
  // way -- clamped, they would pile up against the edge instead of leaving.
  function place(left, top, free) {
    const w = root.offsetWidth, edge = 28;
    root.style.left = (free ? left
      : Math.min(Math.max(left, edge - w), innerWidth - edge)) + 'px';
    root.style.top = Math.min(Math.max(top, 0), innerHeight - edge) + 'px';
  }

  // EVERY PANEL IS A TAB, so every panel answers to the rail -- there is no
  // option for it and no call site that could forget to pass one.
  grab(bar,
       (dx, dy, from) => {
         place(from.left + dx, from.top + dy);
         railDrag(panel);
       },
       (moved) => { if (moved) railDrop(panel); });
  grab(grip,
       (dx, dy, from) => {
         const w = Math.max(options.minWidth || 240, from.w + dx);
         const h = Math.max(options.minHeight || 120, from.h + dy);
         root.style.width = w + 'px';
         root.style.height = h + 'px';
         if (options.onResize) options.onResize(w, h);
         // THE EDGES OFFER THEMSELVES while you are dragging near them. Shown
         // from the edges the grip is actually approaching, so the guides
         // answer the question the hand is asking.
         //
         showEdges(nearEdges(root));
       },
       () => {
         // SNAPPED ON RELEASE, not while dragging. A window that jumped to
         // full height the moment you crossed the line would fight the hand
         // for the rest of the drag -- and there would be no way to stop just
         // short of an edge on purpose. Landing it on the drop makes the
         // guide a promise rather than a rule.
         //
         // BOTH EDGES IF BOTH WERE OFFERED: a grip let go in the corner fills
         // the corner, which is the one reading of two lit rails that is not
         // a surprise.
         const landing = nearEdges(root);
         if (landing.length) {
           const box = root.getBoundingClientRect();
           const want = Object.assign({}, ...landing.map((name) => EDGES[name].fill(box)));
           if (want.height !== undefined) {
             root.style.height = Math.max(options.minHeight || 120, want.height) + 'px';
           }
           // WRITTEN DOWN, because staying snapped is an INTENT and not a
           // measurement. Which edges a window reaches is a fact about right
           // now; that it was PUT there is a fact about what was asked for,
           // and it has to outlive the browser being resized, a neighbour
           // pushing it along, or anything else that moves the box out from
           // under it. See `resnap`.
           //
           // NOT FOR A TAB STILL ON THE RAIL, whose position belongs to the
           // row rather than to itself -- holding one against an edge fights
           // the packing and runs away. See the note in `resnap`.
           if (!onRail(panel)) root.dataset.snapped = landing.join(' ');
           const now = root.getBoundingClientRect();
           if (options.onResize) options.onResize(now.width, now.height);
         } else {
           // DRAGGED OFF THE EDGE IS UNSNAPPING. The hand that put it there
           // is the hand taking it away, and a window that no longer reaches
           // the rail should not spring back to it on the next resize.
           delete root.dataset.snapped;
         }
         showEdges([]);
       });

  const panel = {
    root, bar, body, grip,
    place,
    get shut() { return root.classList.contains('shut'); },
    open() { if (panel.shut) bar.click(); },
    toggle() { bar.click(); },
    // TELL THE INSIDE THE OUTSIDE MOVED. A terminal has to hear about a new
    // size so it can reflow the pty; `resnap` changes a window's size without
    // any grip being touched, so it needs the same call the grip makes.
    resized() {
      const box = root.getBoundingClientRect();
      if (options.onResize) options.onResize(box.width, box.height);
    },
  };
  panelsByRoot.set(root, panel);

  bar.addEventListener('click', () => {
    // A drag that ended on the bar is not a click asking to collapse it.
    if (bar.dragged) { bar.dragged = false; return; }
    const opening = root.classList.contains('shut');
    root.classList.toggle('shut', !opening);
    if (opening) {
      raise(root);
      // First open gets a default size; after that it keeps whatever the grip
      // was last dragged to.
      if (!root.style.width) root.style.width = options.width || 'min(46rem, 92vw)';
      if (!root.style.height) root.style.height = options.height || '22rem';
      if (options.onOpen) options.onOpen(panel);
    } else if (options.onShut) {
      options.onShut(panel);
    }
    // THE ROW MOVES WITH THE CLICK, not a quarter-second later. Opening a
    // panel changes what it takes up in the row, and waiting for the tick
    // that notices meant the neighbours visibly caught up afterwards --
    // the tick is for widths that change with nobody touching anything (a
    // pane retitling itself), not for the one case we are already in.
    if (onRail(panel)) packRail();
  });

  return panel;
}

// Panels stack in the order they were last touched. Kept as a counter rather
// than by reordering the DOM, because moving a live <div> would tear down the
// terminal's scroll position and any selection inside it.
let topmost = 5;
export function raise(root) { root.style.zIndex = ++topmost; }

// THE CONFIG PANEL IS A PANEL LIKE ANY OTHER, made here because the rail has
// to know about it from the start -- it is the first tab. What is inside it
// belongs to the editor, which hands over the two things this needs: the
// element, and what to focus when it opens.
export let configPanel = null;
export function makeConfigPanel(root, onOpen) {
  configPanel = makePanel(root, { minWidth: 240, minHeight: 120, onOpen });
  return configPanel;
}

// One number for the gap above and the gap to the left, so the row starts in
// a corner rather than at two unrelated distances from it.
export const inset = 12;

// ESCAPE PUTS THE PANEL AWAY when you are working in it. "In it" is where the
// focus is, not merely whether it is open: the panel can sit open while you
// pan the graph or type in the compose bar, and an escape meant for either of
// those should not also close the editor behind them.
//
// LAST of the escapes. The help sits over everything and takes it first; the
// compose bar takes it next, closing its list and then itself, since both are
// in front of the panel. Each of those returns before this runs, so this only
// ever sees an escape nothing else wanted.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  if (!configPanel || configPanel.shut) return;
  if (!configPanel.root.contains(document.activeElement)) return;
  e.preventDefault();
  // Focus goes with it: left on a row inside a shut panel, the keyboard
  // would be pointed at something nobody can see.
  document.activeElement.blur();
  configPanel.toggle();
});

// -- the terminal panes ------------------------------------------------------
// A pty on the server, an emulator here, and a poll loop between them. Polled
// rather than streamed: the page has to POST keystrokes regardless, so one
// endpoint returning "everything since chunk N" is both the live path and the
// catch-up path for a reload. An SSE stream would need a second mechanism for
// input and a way to resume when it drops.
//
// Written once and instantiated twice: the agent harness and the dev repl are
// the same pane speaking to different endpoint prefixes -- /pane/harness/*
// drives the supervisor's agent pty, /pane/repl/* a pty running ./repl
// against this server's own image. Nothing in here knows which one it is.
//
// THE /pane/ PREFIX EARNS ITS KEYSTROKES. "repl" names three things in this
// project -- the Janet repl the server hosts on a unix socket, the ./repl
// script that attaches a terminal to it, and this browser pane that runs
// that script in a pty -- so a route called /repl/poll read like it polled
// the Janet image rather than a terminal window. /pane/repl/poll cannot be
// misread: whatever else is going on, this is a pane talking.

export function makeTerminalPane(root, prefix) {
  const stateLine = root.querySelector('.state');
  const nameLabel = root.querySelector('.name');
  const screen = root.querySelector('.screen');


  // Follow the output the way a terminal does -- but only while the view is at
  // the bottom. The flag comes from the user's own scrolling, so scrolling up
  // to read mid-stream is honoured for as long as they stay up, and returning
  // to the bottom re-arms the follow. The pin itself happens in onPaint, after
  // the DOM has its new height: paints are deferred a frame, so pinning at
  // write time scrolls to the PREVIOUS frame's bottom -- and, measured there,
  // "am I at the bottom?" is off by up to a whole chunk, which is what made an
  // earlier version stop following fast streams.
  const paneBody = root.querySelector('.panel-body');
  let following = true;
  paneBody.addEventListener('scroll', () => {
    following = paneBody.scrollTop + paneBody.clientHeight
      >= paneBody.scrollHeight - 4;
  });
  // The pin runs only when the rendered line count moved: scrollHeight is a
  // forced layout, and a scroll-through-history repaint redraws the same 33
  // rows at display rate -- reading the layout back after every one of those
  // renders was half the jank the rAF pacing in term.js fixed the other
  // half of. Same row count, same height, nothing to pin.
  let paintedLines = 0;

  // NO GLIDE between the line-quantized frames a scrolling TUI paints --
  // tried, shipped, removed. The animation translated the live block by the
  // rows just scrolled and eased it to rest, and it read beautifully for a
  // single step. Under a continuous wheel it shook: reports flush every
  // 16ms, the program repaints per batch, and each new frame restarted the
  // 90ms ease from a fresh offset -- plus the translate slid the live block
  // against the history block above it, so the seam flickered. Line-stepped
  // frames are what every native terminal shows; they looked wrong here only
  // while the transport added up to 250ms per step. Streaming brought a step
  // to ~30ms, which is the regime iTerm lives in. The frames can simply be
  // shown.
  const term = makeTerminal(screen, {
    onPaint: (lines) => {
      const grew = lines !== paintedLines;
      paintedLines = lines;
      if (grew && following) paneBody.scrollTop = paneBody.scrollHeight;
    },
  });
  // -- the stall detector ----------------------------------------------------
  // The server side was exonerated at 7,900 reports/s with 16ms worst-case
  // turnaround; the ~10s scroll hangs therefore live somewhere in THIS
  // page or its browser. Instead of theorizing, record: main-thread stalls
  // (longtask entries) and gaps in the poll chain land in a ring, the worst
  // recent one is named in the state line, and window.__diag() dumps the
  // ring for a bug report. Costs nothing until something stalls.
  const diag = [];
  function diagNote(kind, ms) {
    diag.push({ t: Math.round(performance.now()), kind, ms: Math.round(ms) });
    if (diag.length > 60) diag.shift();
    // RECORDED, NOT ANNOUNCED. This used to write into the pane's state
    // line, which is the wrong channel twice over: the line is for things a
    // person acts on -- "exited", "server outdated" -- and a stall that has
    // already ended is not one of those, while a message that stays until
    // something overwrites it turns a moment into a permanent-looking
    // condition. The ring is still here for window.__diag() and it is still
    // what the next investigation reads; it just no longer shouts.
    console.debug(`visualize: ${kind} stall ${(ms / 1000).toFixed(1)}s`);
  }
  if (prefix === 'harness') window.__diag = () => diag.slice();
  if (typeof PerformanceObserver === 'function' && prefix === 'harness') {
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.duration > 250) diagNote('main-thread', entry.duration);
        }
      }).observe({ entryTypes: ['longtask'] });
    } catch (e) { /* longtask unsupported: the ring still gets poll gaps */ }
  }
  let lastPollDone = 0;
  // A version mismatch among page, server and supervisor, once seen, is
  // named in the state line until it stops being true. Two debugging
  // rounds were once spent on fixes that sat on disk while every process
  // kept running its birth code; this is what would have said so.
  let stampNote = '';
  // Server-side faults since this pane attached, named in the state line.
  let faultNote = '';

  let at = 0;              // how much of the session output we have consumed
  let polling = false;     // is the loop running? (see scheduleNextPoll)
  let pollFailures = 0;    // consecutive misses; three in a row means gone
  let generation = 0;      // bumped server-side per start, so a restart resets us

  // Every terminal request carries the token; without it the server answers 403.
  // See `permitted?` in src/core.janet for why localhost alone is not enough.
  async function post(path, body = {}, timeoutMs = 15000) {
    // THE TIMEOUT IS WHAT SURVIVES A SUSPEND. A fetch that is in flight when
    // the machine sleeps can come back neither resolved nor rejected, and the
    // poll chain -- guarded by pollInFlight -- then waits on it forever: no
    // polls, no error, a cursor still blinking because the blink is CSS. An
    // aborted request rejects like any failure and lands in the retry path.
    const response = await fetch(`/pane/${prefix}/${path}?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST',
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) throw new Error(await response.text());
    return response.json();
  }

  // How many rows and columns fit the panel right now. Measured from a real
  // character rather than assumed: the monospace face and its size come from
  // CSS, so hardcoding a cell size here would break the moment either changed.
  // Cached: the probe forces a synchronous layout, and the wheel handler asks
  // at trackpad rate -- a reflow per wheel tick, against a render per frame,
  // is layout thrash a person sees as jank. The size only changes with the
  // font, so syncSize (every geometry change passes through it) invalidates.
  let cell = null;
  function cellSize() {
    if (cell) return cell;
    const probe = document.createElement('span');
    probe.textContent = 'M';
    probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre';
    screen.appendChild(probe);
    const box = probe.getBoundingClientRect();
    probe.remove();
    cell = { w: box.width || 7, h: box.height || 16 };
    return cell;
  }

  function measure() {
    const { w: cw, h: ch } = cellSize();
    return {
      rows: Math.max(4, Math.floor((paneBody.clientHeight - 24) / ch)),
      cols: Math.max(20, Math.floor((paneBody.clientWidth - 12) / cw)),
    };
  }

  function setState(text) { stateLine.textContent = text; }

  // THE BAR SAYS WHAT IS RUNNING, from the argv the host reports rather than
  // from anything this page chose -- the two can differ, since the command
  // is read per request and the pane may have been started by a page that is
  // now closed.
  //
  // The LEAF of the path, because /bin/zsh and /opt/homebrew/bin/zsh are the
  // same answer to "what is this?" and a bar is a few characters wide.
  // WHAT THE TERMINAL IS RUNNING NOW, from the foreground process group the
  // host reads off the pty. A pane that has run `vim` says vim; when vim
  // exits and the shell is back, it says zsh again.
  //
  // Empty means the host could not tell -- an older supervisor, or a moment
  // between programs -- and the title is left alone rather than blanked.
  function setProgram(name) {
    if (!name) return;
    if (nameLabel.textContent === name) return;
    nameLabel.textContent = name;
    // The tab just changed width, so the row has to close up around it.
    if (typeof packRail === 'function') packRail();
  }

  function setName(argv) {
    if (!Array.isArray(argv) || !argv.length) return;
    // THE LEAF, and only the leaf. The pane's number used to ride along
    // because several tabs saying `zsh` were otherwise indistinguishable --
    // the cross beside each one tells them apart now, and a number was
    // never what anyone wanted to read.
    nameLabel.textContent = String(argv[0]).split('/').filter(Boolean).pop();
  }

  async function poll() {
    try {
      // The generation says which session `at` counts chunks in. Without it a
      // restarted agent leaves the page asking about chunks that no longer
      // exist, and the reply is empty forever.
      const askedAt = at, askedGen = generation;
      // `wait` invites the supervisor to PARK this request until it has
      // something to say -- the streaming transport. Output leaves the pty
      // and lands here ~10ms later instead of waiting out a poll timer. The
      // fetch timeout leaves 10s of headroom over the park.
      const out = await post('poll', { at: askedAt, generation: askedGen,
                                       wait: LONGPOLL_WAIT }, LONGPOLL_WAIT + 10000);
      // A reply saying "could not reach the supervisor" is a failed request
      // wearing a 200; treating its running=false/generation=0 as session
      // truth is what blanked the screen after a suspend. Absent -- the socket
      // file itself gone -- is different again: that is a supervisor shut down
      // for real, and the honest state is exited, not eternal reconnecting.
      setProgram(out.program);
      if (out.reachable === false) {
        if (out.absent) { setState('exited'); stopPolling(); return; }
        throw new Error('supervisor unreachable');
      }
      // A keystroke's echo won the race and moved the cursor; this reply is
      // answering a question that is no longer being asked. The chain is
      // already scheduling the next poll, which asks the right one.
      if (stale(askedAt, askedGen)) { pollFailures = 0; return; }
      // A restart on the server means our screen belongs to a dead session, so
      // it is cleared before the new session's output is drawn onto it.
      //
      // THE TEXT IN THIS REPLY IS NOT DISCARDED, and an earlier version's bug
      // was exactly that: it reset, set `at = 0` and returned. But `at` was
      // already 0 when the reply was requested, so the very next poll asked the
      // same question, got the same answer, and threw it away again -- forever.
      // The screen stayed blank while the server held the whole session, and
      // the cursor kept blinking because that is a CSS animation.
      if (out.generation !== generation) {
        generation = out.generation;
        at = 0;
        term.reset();
      }
      // A TORN STREAM IS NOT AN UPDATE. When the backlog cap trims past our
      // position, the reply's text starts BEYOND what we asked for --
      // `from` says so -- and begins mid-frame, possibly mid-escape (a
      // literal "[7C" painted on screen was this bug wearing its cause).
      // Writing it smears garbage over a stale grid. Reset instead, take
      // the new position, and ask the program to repaint whole: SIGWINCH
      // reaches anything full-screen, and a line program's next output
      // starts clean anyway.
      if (out.from > askedAt && askedAt > 0 && out.generation === askedGen) {
        term.reset();
        at = out.at;
        lastOutput = performance.now();
        post('redraw').catch(() => {});
      } else if (out.text) {
        term.write(out.text);
        at = out.at;
        // Output just arrived, so the next poll should be immediate: an agent
        // mid-response has more coming, and this is what keeps streaming smooth
        // rather than stepping along at the idle delay.
        lastOutput = performance.now();
        // Following the output happens in the emulator's onPaint, once the
        // new height exists to scroll to.
      }
      // SERVER FAULTS SURFACE IN THE PANE. They used to go only to stderr,
      // which nobody working in this page can see -- so a tool for making a
      // codebase visible hid its own failures. The count is cheap to carry
      // and the detail is one repl call away, or ./pane faults.
      if (out.faults) faultNote = out.faults > 0
        ? `${out.faults} server fault${out.faults > 1 ? 's' : ''}` : '';
      if (out.serverStamp) {
        stampNote = window.STAMP && out.serverStamp !== window.STAMP
          ? 'page outdated — reload'
          : (out.stamp && out.stamp !== out.serverStamp
              ? 'supervisor outdated — restart the session to update' : '');
      }
      // Order is severity: a version mismatch explains everything else, a
      // fault is the next most useful thing to know, and "exited" is the
      // ordinary end of a session.
      setState(stampNote || faultNote || (out.running ? '' : 'exited'));
      if (!out.running) stopPolling();
      pollFailures = 0;
      // A gap longer than a park can explain is a stall. ONE THRESHOLD, and
      // it is the park's own length plus slack: the previous version used a
      // tighter 5s bound whenever the last reply carried text, reasoning
      // that mid-stream means more is coming -- but output followed by
      // quiet is how every burst ENDS, so the first park after any output
      // tripped it. It reported "stalled 20.0s (poll-gap)" for a pane
      // working exactly as designed, which is worse than reporting nothing:
      // a warning that cries wolf teaches you to ignore the channel real
      // warnings arrive on.
      const done = performance.now();
      if (lastPollDone && done - lastPollDone > LONGPOLL_WAIT + 8000) {
        diagNote('poll-gap', done - lastPollDone);
      }
      lastPollDone = done;
      // A reply that says `waited` came from a supervisor that parks; the
      // next ask should already be on its way when output arrives, so the
      // chain re-polls with no timer at all. Judged per reply, not once:
      // the supervisor under this page can change across a restart, and an
      // old one that ignores `wait` answers instantly without the marker --
      // chaining on THAT would be a busy-spin, so it keeps its timers.
      streaming = !!out.waited;
    } catch (e) {
      // A SINGLE dropped request must not kill the terminal. The server answers
      // hundreds of polls an hour, and one 500 -- a transient race, a supervisor
      // mid-restart -- used to flip the panel to "disconnected" and stop polling
      // for good, leaving a live agent invisible behind a dead pane. Three in a
      // row means it is really gone.
      pollFailures++;
      // NEVER a terminal state. The server is on 127.0.0.1 and will come back
      // -- from a restart, from the machine waking -- so the loop drops to a
      // slow reconnect cadence rather than stopping. Stopping is what left a
      // dead panel behind a live agent after every suspend.
      setState(pollFailures >= 3 ? 'reconnecting...' : 'retrying...');
    }
  }

  // -- pacing ------------------------------------------------------------------
  // The server echoes a keystroke in about 4ms. Everything a person feels as lag
  // is added on this side, so the loop is built to spend as little of it as
  // possible while still going quiet when nothing is happening.
  //
  // A CHAIN, NOT AN INTERVAL. setInterval fires whether or not the previous
  // request came back, so a slow round trip stacks requests that then race --
  // and each carries an `at` from before the last reply, so the same output
  // arrives twice. Each poll now schedules the next one after it finishes.
  //
  // THE DELAY ADAPTS. Idle, there is nothing to see and 250ms costs nothing.
  // Busy, output is arriving and the next poll should already be in flight. The
  // floor is 0 -- an immediate re-poll -- because when the agent is streaming,
  // the round trip itself is the pacing.
  const IDLE_DELAY = 250;
  const BUSY_DELAY = 0;
  // How long one poll may park server-side before answering empty. Under the
  // supervisor's own 25s cap; the page's fetch timeout rides 10s above it.
  const LONGPOLL_WAIT = 20000;
  let streaming = false;
  // How long output keeps the loop in its fast mode after the last byte, so a
  // pause between two chunks of the same response does not drop it back to idle.
  const BUSY_WINDOW = 900;

  let lastOutput = 0;
  let pollTimer = null;
  let pollInFlight = false;

  // A REPLY COUNTS ONLY IF NOTHING MOVED `at` WHILE IT FLEW. Both `poll` and
  // `input` answer with "everything since `at`", and `at` goes into the
  // request body -- so a keystroke sent while a poll is in flight asks the
  // same question twice, and both replies carry the same bytes. The harness
  // hides that: a full-screen program repaints with absolute positions, and
  // drawing a frame twice looks like drawing it once. The repl is a line
  // stream where every byte appends, so the duplicate echo was right there on
  // the screen: typing 2 printed 22.
  //
  // CONCURRENT, NOT SERIALIZED. An earlier fix put every request behind one
  // queue, which cured the doubling but queued each keystroke behind the
  // back-to-back polls of busy mode, and typing turned laggy. So requests fly
  // together and the first reply home wins: each remembers the (at,
  // generation) it asked about, and one that comes back to find them changed
  // is dropped whole. Dropping loses nothing -- the backlog is the record --
  // it only defers those bytes to the next poll, which re-fetches them from
  // the position the winner advanced to.
  function stale(askedAt, askedGen) {
    return at !== askedAt || generation !== askedGen;
  }

  const RECONNECT_DELAY = 2000;

  function scheduleNextPoll() {
    if (!polling) return;
    clearTimeout(pollTimer);
    // Streaming healthy: no timer at all. The next long-poll goes out on the
    // spot and parks server-side until there is something to say -- and a
    // DIRECT call rather than setTimeout(0) matters in a hidden tab, where
    // timers are clamped to a second but a fetch continuation still runs,
    // so output keeps flowing to a tab the user cannot currently see.
    if (streaming && pollFailures === 0) { pollTimer = null; runPoll(); return; }
    const delay = pollFailures >= 3 ? RECONNECT_DELAY
      : (performance.now() - lastOutput < BUSY_WINDOW ? BUSY_DELAY : IDLE_DELAY);
    pollTimer = setTimeout(runPoll, delay);
  }

  async function runPoll() {
    // One at a time. Overlapping polls send stale `at` values and duplicate
    // output onto the screen.
    if (pollInFlight || !polling) return;
    pollInFlight = true;
    try {
      await poll();
    } finally {
      pollInFlight = false;
      scheduleNextPoll();
    }
  }

  // Called the moment a keystroke is sent. The echo is the thing a person is
  // waiting for, so the poll that will carry it should not sit behind an idle
  // delay -- this is most of the difference between "instant" and "laggy".
  function pollSoon() {
    if (!polling) return;
    clearTimeout(pollTimer);
    pollTimer = setTimeout(runPoll, 0);
  }

  function startPolling() {
    if (polling) return;
    polling = true;
    runPoll();
  }

  function stopPolling() {
    if (!polling) return;
    polling = false;
    clearTimeout(pollTimer);
    pollTimer = null;
  }

  async function startSession() {
    const size = measure();
    term.resize(size.rows, size.cols);
    setState('starting...');
    try {
      const out = await post('start', size);
      generation = out.generation;
      at = 0;
      term.reset();
      setName(out.argv);
      setState('');
      startPolling();
      screen.focus();
    } catch (e) {
      setState('failed: ' + e.message);
    }
  }

  // Keystrokes go to the pty as bytes. The screen is focusable (tabindex in the
  // HTML) so this needs no input element -- a real one would fight the emulator
  // over what the cursor means.
  screen.addEventListener('keydown', (event) => {
    // Let copy through: a terminal you cannot copy out of is a terminal you
    // cannot use. Everything else belongs to the program.
    if ((event.metaKey || event.ctrlKey) && event.key === 'c'
        && window.getSelection().toString()) {
      return;
    }
    const bytes = keyToBytes(event);
    if (!bytes) return;
    event.preventDefault();
    event.stopPropagation();
    sendInput(bytes);
  });

  // Type, and draw whatever came back.
  //
  // THE ECHO RIDES HOME ON THE SAME REQUEST. Asking for it separately costs a
  // second round trip no matter how short the poll delay is, because the page
  // cannot start that second request until the first has returned -- and while
  // it waited, the scheduler was just as likely to have armed the idle timer.
  // This is the difference between a character appearing as you press the key
  // and appearing a quarter of a second later.
  // Keystrokes queue behind EACH OTHER and nothing else. Two fetches in
  // flight at once can reach the server swapped, and a pty that receives "eh"
  // types "eh" -- so inputs are ordered. But they do not wait for polls:
  // that wait, multiplied by busy mode's back-to-back polling, is what made
  // typing laggy. The queue is empty at human typing speed anyway; it only
  // fills when keys arrive faster than a localhost round trip.
  let inputTurn = Promise.resolve();
  function sendInput(text, quiet) {
    if (!text) return inputTurn;
    inputTurn = inputTurn.then(() => {
      const askedAt = at, askedGen = generation;
      const sentAt = performance.now();
      return post('input', quiet ? { text, at: askedAt, quiet: true }
                                 : { text, at: askedAt })
        .finally(() => {
          // The sensor the first stall report was missing: a hung input
          // fetch freezes the wheel pipeline (one batch in flight) with no
          // longtask and no poll gap -- invisible to both other sensors.
          const took = performance.now() - sentAt;
          if (took > 1500) diagNote('input-stall', took);
        })
        .then((out) => {
          if (!out || out.text === undefined) return;
          // A poll got home first with these same bytes; the echo is already
          // on the screen and this copy would be the doubled keystroke.
          if (stale(askedAt, askedGen)) { pollSoon(); return; }
          if (out.generation !== generation) {
            generation = out.generation;
            at = 0;
            term.reset();
          }
          // The same torn-stream guard as the poll path: an echo that
          // starts past our position lost bytes to the backlog cap.
          if (out.from > askedAt && askedAt > 0 && out.generation === askedGen) {
            term.reset();
            at = out.at;
            lastOutput = performance.now();
            post('redraw').catch(() => {});
          } else if (out.text) {
            term.write(out.text);
            at = out.at;
            lastOutput = performance.now();
          }
          // Whatever follows the echo -- a command's output, an agent's answer --
          // arrives on the polling loop, which is now in its fast mode.
          pollSoon();
        })
        .catch(() => {
          // The keystroke may have been lost; the poll loop is the arbiter of
          // whether the session is actually gone.
          setState('retrying...');
          pollSoon();
        });
    });
    return inputTurn;
  }

  // Paste, which a harness is used with constantly.
  screen.addEventListener('paste', (event) => {
    event.preventDefault();
    const text = event.clipboardData.getData('text');
    if (text) sendInput(text);
  });

  // THE WHEEL BELONGS TO THE PROGRAM WHEN THE PROGRAM ASKED FOR IT. Claude
  // turns on mouse tracking at startup and never scrolls the terminal -- a
  // 358KB capture of a session held not one newline -- so its history is not
  // in this pane's scrollback and never will be. It lives inside claude,
  // which repaints the transcript in place when a wheel report arrives,
  // exactly as it does in iTerm. Measured live: three SGR wheel-ups at the
  // pty and the transcript scrolled. With tracking off (the repl, a shell)
  // the wheel keeps scrolling the pane's own scrollback, and shift forces
  // that path the way real terminals do under a mouse-hungry program.
  // BATCHED, PACED BY COMPLETION, WITH A RATE FLOOR. A trackpad fires
  // dozens of wheel events a second and momentum keeps firing them after
  // the fingers stop. This corner has burned four designs, and the survivor
  // is the simplest that held up in use: at most one batch in flight, the
  // next leaving when the last one lands and never sooner than 30ms after
  // it -- a ceiling near 260 rows/s, above any rate a person can follow.
  // Deltas accumulate between batches (the carry keeps fractions from
  // rounding to nothing), clamped to a screenful; excess momentum is
  // dropped, never owed. A 2x gain tunes the per-tick feel toward iTerm.
  //
  // The two clever successors are recorded here so they are not rebuilt.
  // Pacing on the answering repaint (any changed, non-growing paint)
  // flooded the pty whenever the agent was WORKING -- its ticking status
  // line and streaming tokens are exactly such paints, and each one
  // released a batch. Pacing on the detected row SHIFT (see term.js, which
  // still reports it) was causally sound and still felt hung: when the
  // detector missed -- an unmatched frame, a program that scrolls more
  // than the probe range -- the fallback cadence crawled. A dumb bounded
  // rate degrades gently everywhere instead of sharply somewhere.
  // Reports go `quiet`: their answer arrives on the parked poll, so the
  // input reply's echo wait bought nothing. Coordinates are read in the
  // flush, off the hot path.
  const WHEEL_GAIN = 2;
  const WHEEL_GAP = 30;
  let wheelCarry = 0, wheelQueued = 0, wheelFlush = null, wheelInFlight = false;
  let wheelLastSend = 0;
  let wheelLast = { x: 0, y: 0 };
  function flushWheel() {
    if (wheelInFlight || wheelQueued === 0) return;
    const wait = wheelLastSend + WHEEL_GAP - performance.now();
    if (wait > 0) {
      if (wheelFlush === null) {
        wheelFlush = setTimeout(() => { wheelFlush = null; flushWheel(); }, wait);
      }
      return;
    }
    const n = Math.max(-8, Math.min(8, wheelQueued));
    wheelQueued -= n;
    const box = cellSize();
    const rect = screen.getBoundingClientRect();
    const col = Math.max(1, Math.min(term.cols, Math.floor((wheelLast.x - rect.left) / box.w) + 1));
    const row = Math.max(1, Math.min(term.rows, Math.floor((wheelLast.y - rect.top) / box.h) + 1));
    wheelInFlight = true;
    wheelLastSend = performance.now();
    sendInput(`\x1b[<${n < 0 ? 64 : 65};${col};${row}M`.repeat(Math.abs(n)), true)
      .finally(() => {
        wheelInFlight = false;
        flushWheel();
      });
  }
  screen.addEventListener('wheel', (event) => {
    if (!term.mouseReporting || event.shiftKey) return;
    event.preventDefault();
    // deltaMode 1 is already lines; 0 is pixels.
    wheelCarry += WHEEL_GAIN
      * (event.deltaMode === 1 ? event.deltaY : event.deltaY / cellSize().h);
    const n = Math.trunc(wheelCarry);
    wheelCarry -= n;
    wheelQueued = Math.max(-term.rows, Math.min(term.rows, wheelQueued + n));
    wheelLast = { x: event.clientX, y: event.clientY };
    if (wheelQueued !== 0) flushWheel();
  }, { passive: false });

  const termPanel = makePanel(root, {
    minWidth: 360, minHeight: 200,
    width: 'min(52rem, 94vw)', height: '24rem',
    onOpen: async () => {
      screen.focus();
      // A beat, so the panel's first-open default size has actually been laid
      // out -- measure() in the same tick as the opening click reads a
      // half-sized body and starts the session ~30 columns wide.
      //
      // A TIMER, NOT requestAnimationFrame. rAF does not fire while the tab is
      // hidden, so an onOpen that awaited a frame in a background tab -- the
      // panel reopening as the machine wakes, say -- suspended here forever:
      // no attach, no start, a state line saying nothing. The same
      // hidden-tab trap as the emulator's paint path, and the same fix.
      await new Promise(r => setTimeout(r, 50));
      // ATTACH TO A SESSION THAT IS ALREADY RUNNING, and only start one when
      // there is none. (The old test was `generation === 0` -- a fact about
      // THIS PAGE, not the server -- so a reload used to shoot the live agent
      // and replace it, and the first keystroke went to a dead shell.)
      try {
        const now = await post('poll', { at: 0, generation: 0 });
        // Unreachable is not "no session" -- starting here would shoot a live
        // agent the moment the supervisor came back. But ABSENT is: no socket
        // file means nothing has ever started, and starting is exactly what
        // opening the panel is for. Confusing the two the other way left a
        // fresh boot spinning at "reconnecting..." with nothing to reconnect
        // to.
        if (now.reachable === false && !now.absent) {
          setState('reconnecting...');
          startPolling();
          return;
        }
        if (now.running) {
          // REPLAY AT THE RECORDED GEOMETRY, NOT THE PANEL'S. The backlog is
          // bytes the program drew for a specific terminal size; absolute
          // cursor positions in it are meaningless in any other. Replaying a
          // Claude session into a fresh differently-sized grid was scattering
          // line fragments all over the reattached screen.
          generation = now.generation;
          term.reset();
          term.resize(now.rows || 24, now.cols || 80);
          // A TRIMMED HISTORY IS NOT REPLAYED. Once the backlog cap has eaten
          // the front, what remains starts mid-frame -- often mid-escape --
          // and painting it fills the scrollback with garbage the redraw
          // nudge cannot reach, because a TUI repaints its live rows and
          // nothing above them. Skipping the replay costs old scrollback and
          // buys a clean screen; the nudge below fills in the current frame.
          if (now.text && !now.trimmed) term.write(now.text);
          at = now.at;
          // NOW adapt to this panel: reflow the grid and tell the pty.
          const size = measure();
          if (term.resize(size.rows, size.cols)) {
            await post('resize', size).catch(() => {});
          }
          // And ask the program for one clean frame. The recording may have
          // been trimmed mid-frame by the backlog cap, and it may span old
          // geometries; a full-screen program repaints itself completely on
          // the resize nudge, painting over whatever the replay left. A
          // line-oriented program ignores it, which is also right.
          await post('redraw', {}).catch(() => {});
          // A SERVER FROM BEFORE TEAR REPORTING answers without `from`, and
          // the page then cannot tell a torn stream from an update -- the
          // exact silent degradation that once cost a whole debugging round
          // while every fix sat unrun on disk. Say so instead.
          setState(now.from === undefined || now.from < 0
            ? 'server outdated — restart ./visualize' : '');
          startPolling();
        } else {
          syncSize();
          startPolling();
          startSession();
        }
      } catch (e) {
        setState('disconnected');
      }
    },
    // Collapsed, the session keeps running -- it is a window, not a switch --
    // but polling a screen nobody can see is wasted traffic.
    onShut: () => stopPolling(),
    onResize: () => syncSize(),
  });

  // Tell the pty when the panel changes size, so the harness redraws to fit.
  // Debounced: a drag fires continuously, and a SIGWINCH per pixel would have
  // the harness redrawing its whole screen hundreds of times.
  let sizing = null;
  function syncSize() {
    cell = null;
    clearTimeout(sizing);
    sizing = setTimeout(() => {
      const size = measure();
      if (term.resize(size.rows, size.cols)) {
        post('resize', size).catch(() => {});
      }
    }, 150);
  }

  window.addEventListener('resize', () => { if (!termPanel.shut) syncSize(); });

  // COMING BACK -- from a suspend, a hidden tab, a dropped network -- restarts
  // the conversation immediately rather than waiting out whatever backoff the
  // gap left armed. Restart-not-just-poll: if the machine slept mid-request the
  // chain may have been wedged in ways the timeout is still unwinding, and
  // startPolling on a live loop is a no-op anyway.
  for (const signal of ['visibilitychange', 'focus', 'online']) {
    window.addEventListener(signal, () => {
      if (document.hidden || termPanel.shut || generation === 0) return;
      pollFailures = 0;
      startPolling();
      pollSoon();
    });
  }

  // A TAB HAS ITS TERMINAL FROM THE MOMENT IT EXISTS, whether or not anyone
  // has opened it. Starting on first open meant a new tab was an empty
  // promise until clicked -- and worse, a row of tabs you had made but not
  // looked at was a row of nothing, so walking them with alt started three
  // shells one after another while you were still looking.
  //
  // AT A DEFAULT GEOMETRY, because a shut panel has no size to measure: the
  // pty is told 24x80 to begin with, and `onOpen` reflows it to whatever the
  // panel turns out to be. A shell does not mind being resized; it is the
  // same thing that happens when a window is dragged.
  //
  // Nothing is polled yet. The backlog is the supervisor's, and it keeps
  // whatever the program writes until a panel opens and asks for it.
  // TYPED AT FROM OUTSIDE. The compose bar sends a whole command this way
  // when a terminal tab is the selected one -- the same path a keystroke
  // takes, so the echo and the polling need no special case.
  termPanel.type = (text) => { if (text) sendInput(text); };

  termPanel.boot = async () => {
    if (generation) return;                 // already has one
    try {
      const now = await post('poll', { at: 0, generation: 0 });
      // A session that is already running is one to leave alone -- this is
      // the reload case, and shooting it is exactly what the open path
      // learned not to do.
      // A session that is already running is one to leave alone, but its tab
      // still has to say what it is: a recovered pane arrives called
      // `terminal 3` and the session behind it has been running zsh for an
      // hour.
      if (now.running) {
        generation = now.generation;
        setProgram(now.program);
        return;
      }
      if (now.reachable === false && !now.absent) return;
      const out = await post('start', { rows: 24, cols: 80 });
      generation = out.generation;
      at = 0;
      setName(out.argv);
    } catch (e) { /* a tab that cannot start says so when it is opened */ }
  };

  // CLOSING THE TAB CLOSES THE SESSION. The route has always been there and
  // the page has never called it: shutting a panel only stopped polling,
  // because the pty was meant to outlive a reload. A tab being destroyed is
  // the other case -- nothing will ever ask about that session again, so the
  // supervisor is told to end it and go.
  termPanel.stop = async () => {
    stopPolling();
    try { await post('stop', {}); } catch (e) { /* it may already be gone */ }
    try { await post('shutdown', {}); } catch (e) { /* likewise */ }
  };

  return termPanel;
}

// ONE PANE, the agent harness. The driver is written against a prefix rather
// than an id because it once ran twice -- the second instance drove a pty
// onto this server's own repl, and went with the debugging rig. What is left
// is the pane the name describes.
const harnessPane = makeTerminalPane(document.getElementById('harness'), 'harness');


// -- more terminals ----------------------------------------------------------
//
// CTRL-T OPENS ANOTHER ONE. Panes are numbered, and the number is the whole
// address: it names the route the driver posts to and the socket the server
// keys a host by, so pane 2 finds pane 2's session again across a reload or a
// server restart -- the property the client/host split exists for.
//
// The panel is CLONED from the one in the page rather than written out again
// here. A second copy of that markup is a second place to change when the bar
// grows a button, and the two would drift.
export let paneCount = 1;
export const extraPanes = [];

// THE SELECTED TAB: the last one you chose, marked so the row says which
// terminal you are working in. Clicking a tab selects it, and so does making
// one -- a terminal you just asked for is the one you meant.
//
// A CLASS ON THE PANEL rather than a variable the stylesheet cannot see, and
// exactly one at a time: the mark answers "which one", and two of them
// answers nothing.
/* -- the tab bar -------------------------------------------------------------

   A RAIL WITH NO BODY. There is no element for it: it is a y coordinate and
   a height, and what it does is decide where a dropped tab lands. Drawing it
   would put a strip of furniture across the top of a drawing that is the
   point of the page -- so it is invisible until a tab is dragged near it,
   and then two orange lines fade in to say where it is.

   TABS ON IT ARE PACKED, left to right in order, each one against the last.
   A panel that grows -- a title changing from `terminal 3` to `zsh 3`, a new
   tab appearing -- pushes the ones after it along, and one that shrinks pulls
   them back. That is why the row is a list here rather than a set of
   remembered positions: positions go stale the moment a width changes, and
   an order does not.

   PULLED OUT BY DRAGGING AWAY. A tab dropped off the rail leaves the list
   and keeps whatever position the drag gave it; dropped back on, it rejoins
   at the slot it was over. */

// HOW FAR THE ROW IS SLID, in pixels, negative to see later tabs. Zero until
// there is something off-screen to reach.
let railScroll = 0;
// Where the row ends when unscrolled -- set by the packing, read to decide
// whether scrolling means anything.
let railEnd = 0;

// AGAINST THE TOP OF THE WINDOW. The row is furniture fixed to the edge of
// the page rather than something floating on the drawing, and an inset here
// left a band of graph above it that read as a gap it had fallen short of.
const RAIL_TOP = 0;
const RAIL_GRAB = 56;         // how near a drag has to come to count as "on"
// TABS OVERLAP BY THEIR SHARED BORDER. A tab starts on the very pixel the
// one before it drew its right edge in, so the two lines land on top of each
// other and read as the single line between the pair -- and which colour it
// comes out is settled by the stacking, the selected tab being above the
// rest. Advancing by the full width instead left the two edges side by side:
// a 2px rule between neighbours, twice the weight of every other line, and
// visibly two lines wherever one of them was the selected colour.
const TAB_GAP = -1;
// WHERE THE ROW STARTS: hard against the left edge, for the same reason. The
// corner marks keep their own inset -- they are single glyphs floating on
// the drawing, where this is a strip anchored to the top of it.
const RAIL_LEFT = 0;

// The tabs on the rail, in the order they sit. Panels not in here are the
// ones that have been pulled off.
export const rail = [];

export function onRail(panel) { return rail.includes(panel); }

// Lay the row out: every tab against the one before it, starting where the
// config's tab starts. Called whenever the list changes or a width does.
// HOW MUCH ROOM A TAB TAKES IN THE ROW. Shut, that is its bar and nothing
// else. OPEN, it is the whole panel: a window is far wider than the tab that
// opens it, and advancing by the bar alone let an opened pane lie across
// every tab after it -- so the one thing you could not do was open two
// neighbours and see both.
function railSpan(p) {
  // MEASURED IN FRACTIONS, not whole pixels. `offsetWidth` rounds, and a tab
  // is 43.63px wide -- so laying the row out on rounded widths left a third
  // of a pixel of background showing between one tab and the next, wherever
  // the rounding fell badly. getBoundingClientRect keeps the fraction and
  // the tabs meet exactly.
  const bar = p.root.querySelector('.bar').getBoundingClientRect().width;
  if (p.shut) return bar;
  // The body can be narrower than the bar on a short window; the row has to
  // clear whichever reaches further.
  return Math.max(bar, p.root.getBoundingClientRect().width);
}

// What the row measures, as a string, so a tick can tell whether anything
// moved without laying anything out. Spans rather than bar widths: opening a
// panel changes what it occupies without touching its bar.
function railShape() {
  return rail.map(railSpan).join(',');
}

export function packRail() {
  // THE SCROLL CANNOT OUTLIVE WHAT IT WAS SCROLLING. Shutting a panel,
  // pulling a tab out, or a window that grew all make the row shorter -- and
  // a scroll left over from when it was longer holds the whole row off the
  // left edge with nothing out to the right to justify it. That is the tab
  // stuck where no scrolling brings it back: the row was already at its
  // stop, so scrolling right did nothing and there was nothing to the left
  // to scroll toward. Clamped here, where the row is measured anyway.
  if (railEnd) {
    const most = railOverflows() ? Math.min(0, (innerWidth - RAIL_LEFT) - railEnd) : 0;
    railScroll = Math.max(most, Math.min(0, railScroll));
  }
  let x = RAIL_LEFT + railScroll;
  railWidths = railShape();
  // WHICH TABS HAVE A NEIGHBOUR to their left, and so share a border with
  // it. Set here because this is what knows the order, and the order
  // changes whenever a tab is dragged.
  rail.forEach((p, i) => {
    // A TAB IN HAND IS NOT IN THE ROW. It is under the pointer, going
    // somewhere, and the row has already closed up behind it -- so it wears
    // neither the corner's rounding nor the pixel of overlap a neighbour
    // costs. Squaring on the first move rather than on the drop is what
    // makes picking it up feel like picking it up.
    const held = p.root === railDragging;

    // THE TAB IN THE CORNER, which is the leftmost one and only while the
    // row is scrolled home: scrolled along, the first tab is off the left
    // edge and whatever is under the corner is passing through rather than
    // sitting in it. See the rounding in style.css.
    p.root.classList.toggle('tab-corner', i === 0 && railScroll === 0 && !held);
  });
  for (const p of rail) {
    // Skip the one being dragged: it is under the pointer, not in the row,
    // and moving it would fight the hand.
    if (p.root === railDragging) {
      x += railSpan(p) + TAB_GAP;
      continue;
    }
    p.place(x, RAIL_TOP, true);
    x += railSpan(p) + TAB_GAP;
  }
  railEnd = x - TAB_GAP - railScroll;   // where the row ends, unscrolled
  // THE GHOSTS DESCRIBE THE ROW, so they are rebuilt whenever it is laid
  // out -- opening, shutting, dragging, scrolling, a window resized. There
  // is no state to keep in step because there is nothing remembered: the
  // marks are derived from where the tabs are.
  showShift();
}

/* -- WHERE A TAB WENT -------------------------------------------------------

   OPENING A TAB PUSHES EVERYTHING AFTER IT the width of the window, and on a
   row you are walking with alt+l that is the whole row jumping sideways each
   time a pane opens -- you lose which tab you were on, because the one you
   were looking at is no longer where you were looking.

   So the tab that got pushed is drawn TWICE: once where it now is, which is
   the real tab, and once in outline back where it was standing, with an
   arrow between the two. The eye keeps the old position and is told where it
   went, rather than having to find it again.

   A COPY, NOT THE TAB. The ghost is a clone with its own class and no
   handlers -- the real tab is still the one you can click, drag or bin, and
   the outline is a picture of where it used to be. Anything else would mean
   two things on the page claiming to be the same tab.

   A STANDING RULE, NOT A NOTE ABOUT THE LAST CLICK. Every open tab that has
   a tab to its right shows one, for as long as that is true -- so opening a
   second pane leaves both marks up, and shutting one takes only its own
   away. It used to be built by the click that opened a tab and cleared by
   whatever happened next, which meant the mark vanished on a shut, a drag
   or a scroll while the tab it described was still pushed aside.

   NOTHING IS REMEMBERED. Where a neighbour would stand if the open tab were
   shut is derivable from the row as it is -- hard against that tab's bar --
   so the marks are rebuilt from the positions every time the row is laid
   out, and no captured value can fall out of step with them. */
let shiftGhost = null;

function clearShift() {
  if (!shiftGhost) return;
  shiftGhost.remove();
  shiftGhost = null;
}

function showShift() {
  clearShift();
  const wrap = document.createElement('div');
  wrap.className = 'tab-shift';

  // EVERY OPEN TAB THAT HAS A NEIGHBOUR, not just the one most recently
  // opened. This is a standing description of the row rather than a note
  // about the last click: open a second pane and BOTH windows are pushing
  // somebody along, so both say where they pushed them from.
  rail.forEach((p, i) => {
    const after = rail[i + 1];
    if (p.shut || !after) return;

    const bar = p.root.querySelector('.bar').getBoundingClientRect();
    // THE GHOST IS A PICTURE OF THE TAB THAT MOVED, so it is measured from
    // THAT tab -- its own bar, not the bar of the one that pushed it. Sized
    // from the pusher, a ghost of `zsh` shoved along by `visualize` came out
    // visualize-wide, and a narrow tab pushed by a wide one came out too
    // small for its own name to fit.
    const mine = after.root.querySelector('.bar').getBoundingClientRect();
    const now = after.root.getBoundingClientRect();
    // WHERE THE NEIGHBOUR WOULD BE IF THIS TAB WERE SHUT: hard against this
    // tab's bar. Derived rather than remembered -- the position a tab was
    // pushed from is a fact about the row as it stands, so it survives
    // anything that rebuilds the row and needs nothing captured beforehand.
    const wasAt = bar.right + TAB_GAP;
    const by = now.left - wasAt;
    // Nothing to say when nothing moved: a window narrower than the tab, or
    // a row against its stop. An arrow of no length is a mark on the page.
    if (by < 1) return;

    const ghost = document.createElement('div');
    ghost.className = 'tab-ghost';
    ghost.style.left = wasAt + 'px';
    ghost.style.top = RAIL_TOP + 'px';
    ghost.style.width = mine.width + 'px';
    ghost.style.height = mine.height + 'px';
    ghost.textContent = after.root.querySelector('.bar .name')?.textContent || '';

    // THE ARROW POINTS BACK, from where the tab is now to where it was: the
    // question the row raises is "where did that go", and the answer runs
    // from the thing you are looking for to the place you last saw it.
    const arrow = document.createElement('div');
    arrow.className = 'tab-ghost-arrow';
    arrow.style.left = (wasAt + mine.width) + 'px';
    arrow.style.top = (RAIL_TOP + mine.height / 2) + 'px';
    arrow.style.width = Math.max(0, by - mine.width) + 'px';

    wrap.appendChild(ghost);
    wrap.appendChild(arrow);
  });

  if (!wrap.children.length) return;
  document.body.appendChild(wrap);
  shiftGhost = wrap;
}

// SCROLLING THE ROW, and only when there is a reason to.
//
// THE LIMITS ARE THE ENDS, not a guess at how much is hidden: the row stops
// with its first tab at the left inset, and stops again with its last tab
// against the right edge. Between those it moves freely.
//
// NOTHING HAPPENS WHEN IT ALL FITS. A row shorter than the window has no
// off-screen part to bring into view, and sliding it then would just be a
// way to lose your tabs off the side.
function railOverflows() { return railEnd > innerWidth - RAIL_LEFT; }

function scrollRail(by) {
  if (!railOverflows()) {
    if (railScroll === 0) return false;
    railScroll = 0;                 // a window that grew: put the row back
    packRail();
    return true;
  }
  // How far left the row may slide: enough to bring its end to the right
  // edge, and no further.
  const most = Math.min(0, (innerWidth - RAIL_LEFT) - railEnd);
  const next = Math.max(most, Math.min(0, railScroll + by));
  if (next === railScroll) return false;
  railScroll = next;
  // The ghosts are redrawn by the packing from the row's new positions, so
  // there is nothing here to keep in step.
  packRail();
  return true;
}

/* KEEP THE DOCUMENT AT THE ORIGIN.

   `overflow: hidden` on the body stops SCROLLBARS; it does not stop the page
   being scrolled by something else. Focusing an input inside a window that
   hangs off the side is enough -- the browser scrolls the document to bring
   the focused thing into view -- and walking the tabs focuses a pane on every
   step. Forty pixels of document scroll then shifts EVERY panel forty pixels
   left of where the row put it, so the row's own arithmetic comes out right
   and the screen still shows a window overhanging its edge.

   Put back here, where the row is about to be measured, rather than chased
   from each of the places focus can move. */
function unscrollPage() {
  if (window.scrollX !== 0 || window.scrollY !== 0) window.scrollTo(0, 0);
}

/* BRING THE SELECTION INTO VIEW by scrolling the row, and nothing else.

   THE OVERHANG IS THE WHOLE RULE. Whatever the selection is -- a 43px tab, a
   window as wide as the screen -- it occupies a span in the row starting at
   its left edge. If that span runs off the right, scroll left by exactly how
   much runs off. If it starts off the left, scroll right by exactly that. If
   it fits, do nothing.

   That is one subtraction, and it is right for every case the row can be in
   without knowing which case it is. The version this replaces asked whether
   the span was wider than the viewport and left-aligned those separately,
   which is the same answer the subtraction gives on its own -- `scrollRail`
   clamps at the ends, so asking to scroll further than the row can go simply
   goes as far as it goes.

   NO MARGIN. The row's own stops are the window edges, so asking to sit a
   few pixels inside one is asking for something the scroll cannot give: it
   goes as far as it can and leaves the tab that far short, which is the case
   this exists to fix. */
export function revealTab(panel) {
  if (!panel) return;
  unscrollPage();
  // THE PANEL'S OWN LEFT EDGE, not its tab's. On an open pane the tab is the
  // small part of it, and a window hanging off the left with its tab just
  // inside the edge is a window you cannot read -- scrolling until the 43px
  // tab cleared the edge was the whole of the old behaviour, and it left the
  // thing you actually walked to still off the screen.
  const box = panel.root.getBoundingClientRect();
  const left = Math.min(box.left, panel.root.querySelector('.bar').getBoundingClientRect().left);
  const over = left + railSpan(panel) - innerWidth;
  if (left < RAIL_LEFT) scrollRail(RAIL_LEFT - left);
  else if (over > 0) scrollRail(-over);
}

// A WHEEL OVER THE ROW, either axis. A trackpad swipe sideways arrives as
// deltaX and a mouse wheel as deltaY, and both mean the same thing here --
// there is one direction the row can go.
window.addEventListener('wheel', (e) => {
  // Only over the row itself: the graph owns the wheel everywhere else, and
  // taking it here would break zooming for the top of the page.
  if (e.clientY > RAIL_TOP + railHeight()) return;
  if (!railOverflows()) return;
  const by = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? -e.deltaX : -e.deltaY;
  if (scrollRail(by)) e.preventDefault();
}, { passive: false });

// A window that changed size changes whether the row fits at all.
window.addEventListener('resize', () => { scrollRail(0); });

// WIDTHS CHANGE WITHOUT ANYONE DRAGGING ANYTHING -- a pane retitles itself
// when its session reports what it is running, and the tab grows or shrinks
// by however much that word differs.
//
// CHECKED ON A TICK rather than watched. A ResizeObserver on each bar is the
// obvious answer and was the first one; it does not fire for a bar whose own
// box never changes (the packing moves panels by `left`, which the observer
// has nothing to say about), and it is another thing that goes quiet in a
// hidden tab. Comparing the widths we last laid out against the widths that
// are there costs one offsetWidth per tab and cannot miss.
let railWidths = '';
function railChanged() {
  const now = railShape();
  if (now === railWidths) return false;
  railWidths = now;
  return true;
}
setInterval(() => {
  if (railDragging) return;
  unscrollPage();
  if (railChanged()) packRail();
  // HELD AGAINST THEIR EDGES. A window pushed along by a neighbour being
  // resized, or by the row repacking, has drifted off the edge it was put
  // on; this puts it back. Watched here for the same reason the room is:
  // there is no one event that means "something moved a panel".
  resnap();

}, 250);

export function addToRail(panel, at) {
  if (onRail(panel)) return;
  rail.splice(at === undefined ? rail.length : at, 0, panel);
  packRail();
}

function removeFromRail(panel) {
  const at = rail.indexOf(panel);
  if (at < 0) return;
  rail.splice(at, 1);
  packRail();
  // THE MARKS OF BEING IN A ROW COME OFF WITH IT, and AFTER the packing:
  // `packRail` sets them on the tabs it lays out, and clearing them before
  // it runs leaves whatever it decides. A tab pulled onto the graph kept
  // the rounded corner it had while it was in the corner, and the pixel of
  // overlap it had while it had a neighbour.
  panel.root.classList.remove('tab-corner');
}

/* -- the bin ---------------------------------------------------------------

   WHERE A PANE GOES TO DIE. It appears in the bottom-left corner only while
   a tab is being dragged -- there is nothing to throw away the rest of the
   time, and a bin sitting on the drawing would be furniture. Held over, the
   lid comes off; let go, it eats what you were holding.

   The old-computer gesture, which is worth the pixels: dropping a thing into
   a bin says what will happen before it happens, where a button says it
   afterwards. */

const bin = document.createElement('div');
bin.id = 'bin';
bin.innerHTML =
  '<svg viewBox="0 0 48 52" aria-hidden="true">' +
  // The lid, hinged so it lifts off rather than fading.
  '<g class="lid"><rect x="6" y="8" width="36" height="6" rx="2"/>' +
  '<rect x="19" y="3" width="10" height="5" rx="2"/></g>' +
  // The can, with three ribs.
  '<path class="can" d="M9 17 h30 l-3 31 a3 3 0 0 1 -3 3 h-18 a3 3 0 0 1 -3 -3 z"/>' +
  '<g class="ribs"><line x1="18" y1="24" x2="17" y2="44"/>' +
  '<line x1="24" y1="24" x2="24" y2="44"/>' +
  '<line x1="30" y1="24" x2="31" y2="44"/></g>' +
  '</svg>';
document.body.appendChild(bin);

// Is the dragged panel's tab over the bin? THE BAR, not the panel: the bar
// is what the hand is holding, and a panel opened to half the screen would
// otherwise overlap the bin while being dragged nowhere near it.
function overBin(panel) {
  if (!bin.classList.contains('up')) return false;
  const b = panel.root.querySelector('.bar').getBoundingClientRect();
  const t = bin.getBoundingClientRect();
  return b.left < t.right && b.right > t.left && b.top < t.bottom && b.bottom > t.top;
}

// EATEN. The pane is destroyed the way the cross used to do it -- off the
// rail, out of the row, its session shut down -- with the lid clapping shut
// over it.
function binEat(panel) {
  // THE LID CLAPS SHUT ON WHAT IT ATE, which needs the bin to still be
  // there -- the drop takes it down, so this puts it back for as long as
  // the swallow lasts.
  bin.classList.add('up', 'fed');
  setTimeout(() => bin.classList.remove('up', 'fed'), 420);
  removeFromRail(panel);
  const at = extraPanes.indexOf(panel);
  if (at >= 0) extraPanes.splice(at, 1);
  // SELECTION CANNOT POINT AT SOMETHING IN THE BIN: alt would have nothing
  // to open and the row would show nothing marked.
  if (panel.root.classList.contains('picked')) selectPane(configPanel.root);
  packRail();
  if (panel.stop) panel.stop();
  panel.root.remove();
}

// Which panel is under the hand right now, or null. Held so the packing can
// leave it alone and the rails know to show themselves.
let railDragging = null;

// THE MARK IN THE CORNER, which belongs to the PAGE and not to any tab.
// It was a child of whichever tab was leftmost, which meant it came and went
// with that tab -- drag the last one off the rail and the corner emptied.
// The corner of the window does not stop existing because nothing is sitting
// in it, so the disc is part of the page and is always there.
const cornerMark = document.createElement('div');
cornerMark.className = 'notch';
document.body.appendChild(cornerMark);

/* -- THE FLOOR ------------------------------------------------------------

   A RAIL AT THE BOTTOM OF THE PAGE, offered while a window is being resized
   near it, that takes the window to the full height when the grip is let go.

   THE SAME BARGAIN THE TAB RAIL MAKES, and it looks the same on purpose: a
   dashed orange line that appears while you are aiming and leaves once you
   have landed. One guide vocabulary rather than two -- if it is a dashed
   orange line, dropping there snaps.

   OFFERED, NOT IMPOSED. The window is not resized until the drop, so the
   guide is a promise rather than a rule: crossing the line and coming back
   leaves the window exactly where the hand put it. Snapping live would fight
   the drag and make "nearly full height" impossible to ask for.

   THE BOTTOM ONLY. A right edge was tried and taken out again: a window held
   against the right is a window whose WIDTH the row cannot change, and the
   row is the thing that has to move a wide window into view. The two rules
   pulled opposite ways and the row lost. Height costs the row nothing, so
   the floor stays. Kept as a table of one because an edge is still data --
   which side of the box to measure, and which dimension to fill. */
const EDGE_GRAB = 48;       // how near an edge has to come to count

export const EDGES = {
  floor: {
    near: (box) => box.bottom >= innerHeight - EDGE_GRAB,
    // FROM WHEREVER THE TOP SITS, not the whole viewport: the grip moves the
    // bottom edge, so the top is where the hand left it and the window fills
    // what is below it.
    fill: (box) => ({ height: innerHeight - box.top }),
  },
};

// One mark per edge, dressed by the stylesheet.
const edgeMarks = {};
for (const name of Object.keys(EDGES)) {
  const mark = document.createElement('div');
  mark.id = name + '-mark';
  mark.className = 'edge-mark';
  mark.innerHTML = '<i></i>';
  document.body.appendChild(mark);
  edgeMarks[name] = mark;
}

/* HOLD EVERY SNAPPED WINDOW AGAINST ITS EDGE.

   A snap is not over when the grip is let go. The window was put against an
   edge, and it should still be against that edge after the browser is made
   smaller, after a neighbour is resized and shoves it along, after anything
   moves the box out from under it -- otherwise "snapped" lasts exactly as
   long as nothing happens.

   RE-APPLIED FROM THE SAME `fill` THE DROP USED, so there is one definition
   of what each edge means and no second copy to drift. A window that has
   drifted off its edge is simply stretched back to it.

   WHEN THE ROOM RUNS OUT, THE WINDOW SLIDES rather than overhanging. A
   viewport narrowed until `innerWidth - left` is under the minimum width
   cannot be answered by stretching -- the window would have to shrink below
   what it is allowed to be. So it keeps its minimum and MOVES: the edge it
   was snapped to is the promise, and the far corner is what gives.

   A window too small to use is still worse than one too big to fit, so the
   minimum is never crossed -- past the point where even a slid window cannot
   fit, it overhangs at the top rather than coming off the floor. */
export function resnap() {
  let moved = false;
  for (const root of document.querySelectorAll('.panel[data-snapped]')) {
    const names = root.dataset.snapped.split(' ').filter(Boolean);
    if (!names.length) continue;
    // A shut panel has no size to hold; it takes its edge back when it opens.
    if (root.classList.contains('shut')) continue;
    // A TAB ON THE RAIL MAY HOLD THE FLOOR. Its LEFT is the packing's
    // business and its height is nobody's, so holding one against the bottom
    // costs the row nothing -- which is exactly why the right edge is gone:
    // holding a width fought the row for the one thing the row controls.
    const panel = panelsByRoot.get(root);
    const box = root.getBoundingClientRect();
    const want = Object.assign({}, ...names.map((name) => EDGES[name] && EDGES[name].fill(box)));
    // Per panel, so one window being stretched does not tell every other
    // window that it moved.
    let stretched = false;
    if (want.height !== undefined) {
      const h = Math.max(120, want.height);
      if (Math.abs(box.height - h) > 0.5) { root.style.height = h + 'px'; stretched = true; }
      // Slid up when the room below the top is less than the window may be.
      if (h > innerHeight - box.top) {
        const top = Math.max(0, innerHeight - h);
        if (Math.abs(box.top - top) > 0.5) { root.style.top = top + 'px'; stretched = true; }
      }
    }
    if (stretched) {
      moved = true;
      if (panel && panel.resized) panel.resized();
    }
  }
  return moved;
}

// Which edges this panel is close enough to land on -- none, one, or both.
//
// MEASURED FROM THE EDGE THE GRIP MOVES, which is the one that would end up
// on the rail. Anything at or past it counts, including a window already
// dragged beyond: overshooting is how most people aim at an edge, and
// refusing the snap for it would make the target harder to hit the harder
// you tried.
function nearEdges(root) {
  const box = root.getBoundingClientRect();
  return Object.keys(EDGES).filter((name) => EDGES[name].near(box));
}

function showEdges(names) {
  for (const name of Object.keys(EDGES)) {
    edgeMarks[name].classList.toggle('near', names.includes(name));
  }
}

// THE RAILS, drawn only while a tab is near them. Two lines rather than a
// box: the row has a top and a bottom and no ends, since it runs as far as
// there are tabs.
const railMarks = document.createElement('div');
railMarks.id = 'rail-marks';
railMarks.innerHTML = '<i></i><i></i>';
document.body.appendChild(railMarks);

function railHeight() {
  const anyBar = document.querySelector('.panel .bar');
  return anyBar ? anyBar.offsetHeight : 28;
}

function showRails(near) {
  railMarks.style.top = RAIL_TOP + 'px';
  railMarks.style.height = railHeight() + 'px';
  railMarks.classList.toggle('near', !!near);
}

// Is this panel's tab close enough to the rail to land on it?
function overRail(panel) {
  const bar = panel.root.querySelector('.bar').getBoundingClientRect();
  return Math.abs(bar.top - RAIL_TOP) <= RAIL_GRAB;
}

// WHERE IN THE ROW a dragged tab would land: before the first tab whose
// middle the pointer is past, which is the same rule the config rows use for
// dragging a line.
function slotFor(panel) {
  const bar = panel.root.querySelector('.bar').getBoundingClientRect();
  const mid = bar.left + bar.width / 2;
  const others = rail.filter(p => p !== panel);
  let at = others.length;
  for (let i = 0; i < others.length; i++) {
    const b = others[i].root.querySelector('.bar').getBoundingClientRect();
    if (mid < b.left + b.width / 2) { at = i; break; }
  }
  return at;
}

function railDrag(panel) {
  railDragging = panel.root;
  // OFF THE MOMENT IT IS PICKED UP. `packRail` clears these for the held tab
  // too, but it only runs when the drag is near the rail and changes slot --
  // a tab pulled straight down would keep its rounded corner all the way to
  // the drop. Cleared here, where every move passes.
  panel.root.classList.remove('tab-corner');
  // THE BIN COMES UP FOR ANYTHING THAT CAN GO IN IT. visualize cannot: it is
  // the page rather than a thing on it, and offering to throw the page away
  // is not an offer worth making. A pane knows it can be destroyed by having
  // a session to stop.
  bin.classList.toggle('up', !!panel.stop);
  bin.classList.toggle('open', overBin(panel));
  const near = overRail(panel);
  showRails(near);
  if (!near) return;
  // REORDER AS YOU GO, so the row shows where the tab will land rather than
  // making you drop it to find out. The dragged tab is skipped by the
  // packing, so this moves the others around it.
  const at = slotFor(panel);
  const was = rail.indexOf(panel);
  if (was >= 0 && was !== at) {
    rail.splice(was, 1);
    rail.splice(at, 0, panel);
    packRail();
  } else if (was < 0) {
    rail.splice(at, 0, panel);
    packRail();
  }
}

function railDrop(panel) {
  railDragging = null;
  railMarks.classList.remove('near');

  // DROPPED ON THE BIN is the way a pane is destroyed -- see overBin. Asked
  // BEFORE the bin is put away, since being over it is the thing being
  // asked about.
  const eaten = overBin(panel);
  bin.classList.remove('up', 'open');
  if (eaten) { binEat(panel); return; }

  if (overRail(panel)) {
    if (!onRail(panel)) addToRail(panel, slotFor(panel));
    packRail();
  } else {
    // PULLED OUT. It keeps where the drag left it -- that is what pulling a
    // tab out is for.
    removeFromRail(panel);
    // BUT IT HAS TO BE REACHABLE. On the rail a tab may sit far off the left
    // edge, because the row is scrolled and scrolling back is how it
    // returns; off the rail there is nothing to scroll, so a tab dropped out
    // there is lost -- no bar to grab and no way to bring it in. The drag
    // itself is placed freely, so this is the moment to put it back in
    // reach, and only in the direction it is actually stranded.
    const box = panel.root.getBoundingClientRect();
    const edge = 28;
    if (box.right < edge) panel.place(edge - box.width, box.top);
    else if (box.left > innerWidth - edge) panel.place(innerWidth - edge, box.top);
  }
}

// EVERY PANEL IS A TAB, the config among them. It is one of the things in
// the row, it is one of the things alt can open, and leaving it out made it
// a special case in both places for no reason a person looking at the row
// would guess.
export function selectPane(root) {
  for (const p of document.querySelectorAll('.panel.picked')) {
    p.classList.remove('picked');
  }
  if (root) {
    root.classList.add('picked');
    // ON TOP, THE SAME WAY EVERYTHING ELSE GETS THERE. The tabs overlap by a
    // pixel so their shared border collapses into one line, and whichever
    // panel is higher paints it -- the selected one has to be. Through
    // `raise` rather than a number in the stylesheet: `raise` hands out
    // ever-larger values as panels are opened and dragged, so any fixed
    // number is one a neighbour eventually passes.
    raise(root);
    // THE SELECTION IS ALWAYS IN VIEW. Whatever moved it -- a keypress, a
    // click, a tab dropped into the row -- a mark you cannot see is a mark
    // that may as well not be there, and the row is the only thing that has
    // to move to fix it. One call here rather than one beside every place
    // the selection can change, which is how the walk came to reveal and
    // the click did not.
    revealTab(panelsByRoot.get(root));
  }
  // THE BAR FOLLOWS THE SELECTION, mid-sentence if need be. Its mode was
  // settled when it opened, so walking from the config to a terminal with
  // half a line typed left you writing shell into a box still wrapped in
  // parens and still offering config verbs -- and the other way round left a
  // config line in a box that would have sent it to a shell.
  //
  // Every path that changes the selection comes through here: a click, an
  // alt-walk, a tab closing.
  if (deps.refitCompose) deps.refitCompose();
}

// The panel that is selected right now, or the config when somehow none is.
// The panel object that is selected right now, or the config's when somehow
// none is.
export function pickedPanel() {
  const root = document.querySelector('.panel.picked');
  return (root && panelsByRoot.get(root)) || configPanel;
}

// Clicking anywhere in a panel -- its tab, its screen, a config row -- is
// choosing it. On the panel rather than on the bar, so clicking into the
// thing to work in it counts as picking the thing you are working in.
document.addEventListener('pointerdown', (e) => {
  const inPanel = e.target.closest && e.target.closest('.panel');
  if (inPanel) selectPane(inPanel);
}, true);

// THE SHAPE OF A TERMINAL PANE, taken from the page once and kept. It used
// to be cloned from the live harness element every time, which was fine
// while that one could never be closed -- now that it can, a page with no
// terminals left would have nothing to copy.
const paneTemplate = (() => {
  const copy = document.getElementById('harness').cloneNode(true);
  // WITHOUT WHATEVER THE LIVE ONE HAS GROWN: this is taken after the first
  // pane was wired and has been painting, and a template is the markup
  // rather than the state.
  copy.querySelector('.screen').textContent = '';
  copy.querySelector('.state').textContent = '';
  copy.classList.remove('picked');
  return copy;
})();

// A PANE FOR AN ID THAT ALREADY HAS A SESSION. Everything openTerminal does
// except choosing the number and booting: the session is already running, so
// starting one would shoot it.
function reopenTerminal(id) {
  const pane = buildTerminal(id);
  addToRail(pane);
  // Not to start one -- there is one -- but to attach to it and read off
  // what it is running, which is what the tab says.
  pane.boot();
  return pane;
}

// THE PANEL AND ITS DRIVER, for an id. What happens to it afterwards is the
// caller's: a new pane starts a session, a recovered one already has one.
function buildTerminal(id) {
  const root = paneTemplate.cloneNode(true);
  root.id = 'pane-' + id;
  root.classList.add('shut');
  root.querySelector('.screen').textContent = '';
  root.querySelector('.state').textContent = '';
  root.querySelector('.name').textContent = 'terminal ' + id;
  // Cleared, so the panel starts at its own default size rather than
  // inheriting whatever the template was captured with.
  root.style.cssText = '';
  document.body.appendChild(root);

  const pane = makeTerminalPane(root, id);
  extraPanes.push(pane);
  return pane;
}

export function openTerminal() {
  const id = String(++paneCount);
  const pane = buildTerminal(id);
  selectPane(pane.root);
  // SHUT, like every other panel starts. A new terminal is a tab you can
  // open, not a window that takes the screen the moment you ask for one.
  //
  // ON THE RAIL, at the end of the row -- the packing puts it against the
  // last tab and keeps it there however the ones before it change width.
  addToRail(pane);
  // Its terminal starts now, not when someone gets round to looking at it.
  pane.boot();
  return pane;
}

// CTRL-T EVERYWHERE BUT INSIDE A TERMINAL, where it is the shell's
// (transpose-chars) and the program should get the keys it expects.
//
// CMD-T ALWAYS, INCLUDING INSIDE ONE. Without a second way in, opening a
// pane focused its screen and every ctrl-t after the first went to the
// shell -- one terminal, and no way to ask for another without clicking
// away first. Cmd is the modifier to spend on it because the emulator
// already refuses it outright (see keyToBytes), so nothing is taken from
// the program that it ever had.
document.getElementById('term-new')
  .addEventListener('click', () => { openTerminal(); });

document.addEventListener('keydown', (e) => {
  if (e.key !== 't' && e.key !== 'T') return;
  if (e.altKey) return;
  const el = document.activeElement;
  const inTerm = !!(el && el.closest && el.closest('.term'));
  if (e.metaKey || (e.ctrlKey && !inTerm)) {
    e.preventDefault();
    openTerminal();
  }
}, true);

/* START THE ROW. Called by app.js once the config panel exists, because the
   first tab IS the config panel and this module does not build it -- what
   goes inside it is the editor's business.

   Not at module load, which is where it used to run: the panel is null until
   the editor makes it, and the packing tick would then measure a tab that is
   not there yet. */
export function startRail() {
  // BESIDE THE CONFIG'S TAB, not on top of it. Both panels are absolutely
  // positioned, and a panel that was never placed sits at 0,0 -- which is
  // exactly where the config bar already is. Measured rather than guessed at a
  // constant: the config tab is as wide as the file it names, so a number
  // written here would be wrong for every project but this one.
  //
  // After a frame, and after the config's own placement, for the same reason
  // that one waits: a collapsed bar has no width to measure until layout runs.
  // THE ROW, in the order it reads. Everything else about where these sit is
  // the rail's business from here.
  addToRail(configPanel);
  addToRail(harnessPane);
  harnessPane.boot();

  // TABS FOR THE SESSIONS THAT SURVIVED. A pane's id is the whole address --
  // the route the page posts to and the socket the server keys a host by -- so
  // putting the tab back is enough to be talking to the same terminal again.
  // The server has already checked that each one answers; see the recovery in
  // core.janet.
  //
  // Shut, like any other tab: a page reloading is not a request to open four
  // windows. The numbering carries on past the highest one restored, so a new
  // pane cannot collide with a recovered one.
  for (const id of (window.OPEN_TERMINALS || [])) {
    const n = Number(id);
    if (Number.isFinite(n) && n > paneCount) paneCount = n;
    reopenTerminal(String(id));
  }

  // SOMETHING IS ALWAYS SELECTED, because an unmarked row raises "which one is
  // it then?" -- the question the mark exists to answer. The CONFIG to start
  // with: it is the leftmost tab, it is what the page is for, and alt over a
  // fresh page should open the thing you came to edit.
  //
  // OUTSIDE THE FRAME ABOVE. Placement genuinely needs a laid-out bar to
  // measure, but this needs nothing -- and rAF does not fire in a hidden tab,
  // so a page opened in the background came up with the wrong tab selected and
  // stayed that way until something else moved it.
    selectPane(configPanel.root);
}
