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

import { makeTerminal } from './term.js';
import { pane, fit, isTouched } from './graph.js';
import { changed, renders, renderNow } from './state.js';

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
  // THE BOX'S WIDTH, from the start and in both states. A shut tab is this
  // same box without its height, so opening one appears to expand it downward
  // rather than to unfold something wider than the thing that was clicked.
  // Set here rather than on first open, which is when it used to arrive --
  // and which is why a shut tab was only as wide as its title.
  root.style.width = options.width || 'min(46rem, 92vw)';
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
      // First open gets a default height; after that it keeps whatever the
      // grip was last dragged to. The WIDTH is already set -- a shut tab is
      // the same box at a smaller height, so it has had the width all along.
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
  // THE SCREEN IS THE SCROLLER for a terminal, not the body around it -- see
  // the note in style.css. Ghostty's renderer measures the element it was
  // given to decide which scrollback rows to build, so that element has to be
  // the one carrying the overflow; following it here rather than the body
  // keeps the two agreeing about where "the bottom" is.
  let following = true;
  screen.addEventListener('scroll', () => {
    following = screen.scrollTop + screen.clientHeight
      >= screen.scrollHeight - 4;
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
      if (grew && following) screen.scrollTop = screen.scrollHeight;
    },
    // EVERYTHING THE KEYBOARD PRODUCED, already in the bytes the program
    // expects -- arrows in whichever form the current cursor-key mode calls
    // for, a paste wrapped in its brackets, a composed character, a mouse
    // report. `sendInput` is hoisted, and this only runs on a keystroke.
    onData: (bytes) => { sendInput(bytes); },
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
      term.focus();
    } catch (e) {
      setState('failed: ' + e.message);
    }
  }

  // Keystrokes go to the pty as bytes. The screen is focusable (tabindex in the
  // HTML) so this needs no input element -- a real one would fight the emulator
  // over what the cursor means.
  // A CLICK ON THE SCREEN HANDS THE KEYBOARD BACK. The element is focusable
  // (tabindex in the HTML, so tabbing to a pane works), and focusing it is
  // exactly what takes the keyboard AWAY from the textarea wterm listens on
  // -- click the terminal to type in it and typing would stop. wterm does
  // not claim mousedown for this, so the pane does.
  //
  // On mousedown rather than click, so the focus lands before the browser
  // moves it, and not when a selection is being dragged out: selecting text
  // to copy should not be typing.
  screen.addEventListener('mousedown', () => {
    setTimeout(() => {
      if (!window.getSelection().toString()) term.focus();
    }, 0);
  });

  // NO KEY HANDLER HERE. wterm listens on its own hidden textarea and reports
  // what the keyboard produced through `onData` (wired at makeTerminal
  // below), which is how the package is meant to be used -- and the only way
  // to get the modes right, since which bytes an arrow means depends on
  // whether the program has turned on application cursor keys.
  //
  // WHAT IT COSTS is that the screen must not steal the focus wterm needs.
  // `screen.focus()` used to be how a pane took the keyboard; it now hands
  // focus to the terminal, which puts it on the textarea.

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

  // NO PASTE HANDLER HERE EITHER, for the same reason there is no key
  // handler: wterm listens on its own textarea, and a paste event BUBBLES.
  // One left here fired alongside wterm's and the text arrived twice.
  //
  // Its is the better one regardless. Ours sent the raw clipboard; wterm
  // wraps it in `ESC [ 200~` / `ESC [ 201~` when the program has asked for
  // bracketed paste, and strips ESC out of the payload first so a clipboard
  // cannot close the bracket early and have the rest read as commands.

  // THE WHEEL IS WTERM'S TOO, for the reason the keyboard is: it listens on
  // the same element this pane does, so a wheel event fired both handlers
  // and a mouse-tracking program scrolled twice. Same shape of bug as the
  // paste above, found the same way.
  //
  // WHAT WENT WITH IT was a pacing loop -- batched reports, a 30ms gap, a
  // rate ceiling, momentum dropped rather than owed -- and it is worth
  // saying why that was there, because it was not decoration. Unpaced
  // reports over the OLD transport flooded the pty: a round trip cost 65ms,
  // a trackpad fires dozens of events a second, and the queue that built up
  // froze the pane for seconds at a time. Two cleverer designs were tried
  // and are recorded in the history: pacing on the answering repaint (which
  // an agent's ticking status line released constantly) and pacing on the
  // detected row shift (sound, but it crawled whenever the detector missed).
  //
  // That transport is gone. A keystroke round trip is ~2.5ms now, not 65ms,
  // and wterm reports one SGR sequence per wheel event with no queue of its
  // own. If a hard trackpad scroll ever stalls a pane again, this note is
  // where to start -- but the condition the pacing existed for is not the
  // condition that holds now.

  const termPanel = makePanel(root, {
    minWidth: 360, minHeight: 200,
    width: 'min(52rem, 94vw)', height: '24rem',
    onOpen: async () => {
      term.focus();
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




/* THE ROW SITS IN FROM THE CORNER, and its tabs stand apart.

   IN, RATHER THAN AGAINST THE EDGE. A tab pressed into the very corner has to
   answer for whatever the browser does with its own corner there, and a page
   cannot ask: Firefox rounds a floating window and squares a maximized one,
   with nothing in the page changing between them. Standing clear of the
   corner leaves the question to the browser, which is the only one that knows
   the answer.

   APART, RATHER THAN SHARING A LINE. Tabs that touch have to negotiate the
   pixel between them -- whose border it is, which colour wins when one is
   selected -- and every version of that arithmetic has been a bug. A gap has
   no shared pixel to argue over. */
const RAIL_TOP = 8;
const RAIL_GRAB = 56;         // how near a drag has to come to count as "on"
const TAB_GAP = 6;
const RAIL_LEFT = 10;

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
  // THE PANEL, in both states, because the panel IS the box now. This used to
  // measure the BAR when shut and the panel when open -- which were different
  // things back when the bar drew its own edges, and are the same box at two
  // heights today. The bar sits inside the panel's border, so a shut tab
  // measured two pixels narrow and the gap after it grew by two the moment
  // the tab beside it was opened. Which tab is open cannot change how wide
  // its neighbour is.
  //
  // MEASURED IN FRACTIONS, not whole pixels. `offsetWidth` rounds, and a tab
  // is not a whole number of pixels wide -- laying the row out on rounded
  // widths left a sliver of background showing between one tab and the next,
  // wherever the rounding fell badly.
  return p.root.getBoundingClientRect().width;
}

// What the row measures, as a string, so a tick can tell whether anything
// moved without laying anything out. Spans rather than bar widths: opening a
// panel changes what it occupies without touching its bar.
function railShape() {
  return rail.map(railSpan).join(',');
}

/* -- THE ROW'S STATE, AND THE ONE PLACE IT IS DRAWN ------------------------

   THREE PHASES, AND THEY DO NOT MIX. `measure` reads every width the layout
   needs; `place` works out where each tab goes, touching nothing; `render`
   writes. A style written between two reads makes the browser lay the page
   out again to answer the second, and doing that once per tab is what made
   this function slow and its arithmetic hard to follow -- it measured a tab,
   moved it, and measured the next against a page it had just changed.

   THE STATE IS THE TRUTH. Where the row is slid, how wide each tab is, where
   the row ends: all of it here, so there is one place to look when the row is
   wrong and one place to change when it should be different. */
const railState = {
  scroll: 0,      // how far the row is slid, negative to see later tabs
  end: 0,         // where the row ends unscrolled
  spans: new Map(),
  // The panel under a hand right now, skipped by the packing because the row
  // has already closed up behind it.
  dragging: null,
  // What the row measured last, as a string, so a tick can tell whether
  // anything moved without laying anything out.
  widths: '',
  // A HAND IS SCROLLING THE ROW right now, so the lay-out must not drag it
  // back to the selection. See `packRailNow`.
  scrolling: false,
};

// Read every width, and nothing else. The only phase allowed to touch the
// page for an answer.
function measureRail() {
  railState.spans = new Map(rail.map((p) => [p, railSpan(p)]));
  railState.widths = railShape();
}

// Where each tab sits. A walk over the list -- no element is read and none is
// written, so this can be asked as often as anything wants it.
function placeRail() {
  const at = new Map();
  let x = RAIL_LEFT + railState.scroll;
  for (const p of rail) {
    at.set(p, x);
    x += (railState.spans.get(p) || 0) + TAB_GAP;
  }
  railState.end = x - TAB_GAP - railState.scroll;
  return at;
}

/* LAY THE ROW OUT: measure, clamp, place, write.

   THE SCROLL CANNOT OUTLIVE WHAT IT WAS SCROLLING. Shutting a panel, pulling
   a tab out, or a window that grew all make the row shorter -- and a scroll
   left over from when it was longer holds the whole row off the left edge
   with nothing out to the right to justify it. That is the tab stuck where no
   scrolling brings it back: the row was already at its stop, so scrolling
   right did nothing and there was nothing to the left to scroll toward. */
/* ASK FOR THE ROW TO BE LAID OUT, on the next frame.

   ELEVEN CALLERS, AND A WALK HITS THREE OF THEM per keypress -- it shuts one
   tab, opens another and moves the selection, and each of those used to
   measure and rewrite the whole row on the spot. Coalesced to one lay-out per
   frame, which is the most a screen can show anyway.

   `packRailNow` is for the few places that cannot wait: something about to
   measure the row itself, and the tests, which have no frames. */
export function packRail() { changed(); }

renders(packRailNow);

export function packRailNow() {
  // BEFORE MEASURING, because a document scrolled sideways shifts every panel
  // out from under the row's arithmetic -- see `unscrollPage`.
  unscrollPage();
  measureRail();
  // Placing once to learn where the row ends, so the clamp has a length to
  // clamp against; the second placing is what gets drawn.
  placeRail();
  if (railState.end) {
    const most = railOverflows() ? Math.min(0, (innerWidth - RAIL_LEFT) - railState.end) : 0;
    railState.scroll = Math.max(most, Math.min(0, railState.scroll));
  }
  // THE SELECTION IS ALWAYS IN VIEW, and this is the only place that has to
  // know it. A mark you cannot see is a mark that may as well not be there,
  // and the row is the one thing that has to move to fix it.
  //
  // HERE RATHER THAN AT EVERY CALLER. It used to hang off `selectPane`, which
  // catches a keypress and a click on a DIFFERENT tab -- but not opening the
  // tab you already had selected, which is the one that changes the row's
  // width most. Anything that lays the row out can put the selection off the
  // side; anything that lays the row out now brings it back.
  // THE OVERHANG IS THE WHOLE RULE. Whatever the selection is -- a 43px tab
  // or a window as wide as the screen -- it takes a span from its left edge:
  // if that runs off the right, slide left by exactly how much runs off; if
  // it starts off the left, slide right by that. Set here rather than through
  // `scrollRail`, which asks for another lay-out -- we are in one, and the
  // placing below will draw the answer.
  // NOT WHILE A HAND IS ON IT. A wheel over the row asks for a lay-out, and a
  // lay-out that pulls the selection back into view undoes the scroll on the
  // very next frame -- so the row sprang back under the finger and looked
  // stuck. Walking with alt+h/l was unaffected, because that MOVES the
  // selection and the reveal was agreeing with it.
  const chosen = railState.scrolling ? null : pickedPanel();
  if (chosen && rail.includes(chosen) && railOverflows()) {
    const at = placeRail().get(chosen);
    const over = at + (railState.spans.get(chosen) || 0) - innerWidth;
    const most = Math.min(0, (innerWidth - RAIL_LEFT) - railState.end);
    let want = railState.scroll;
    if (at < RAIL_LEFT) want = railState.scroll + (RAIL_LEFT - at);
    else if (over > 0) want = railState.scroll - over;
    railState.scroll = Math.max(most, Math.min(0, want));
  }
  renderRail();
}

/* WRITE THE ROW, and read nothing. Everything this needs was measured above.

   THE HELD TAB IS SKIPPED. It is under a pointer, going somewhere, and the
   row has already closed up behind it -- so it wears neither the corner's
   rounding nor the position the packing would give it. Squaring on the first
   move rather than on the drop is what makes picking it up feel like picking
   it up. */
function renderRail() {
  const at = placeRail();
  rail.forEach((p, i) => {
    const held = p.root === railState.dragging;
    if (!held) p.place(at.get(p), RAIL_TOP, true);
  });
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
function railOverflows() { return railState.end > innerWidth - RAIL_LEFT; }

function scrollRail(by) {
  // MEASURE BEFORE DECIDING. `railOverflows` reads `railState.end`, which is
  // only written when the row is laid out -- so a wheel arriving after
  // anything changed a width was answered from a stale number. The row said
  // it fitted, refused to move, and the trackpad did nothing at all while
  // alt+h/l still worked, because that walks the selection and lays the row
  // out on its way.
  measureRail();
  placeRail();
  if (!railOverflows()) {
    if (railState.scroll === 0) return false;
    railState.scroll = 0;                 // a window that grew: put the row back
    packRail();
    return true;
  }
  // How far left the row may slide: enough to bring its end to the right
  // edge, and no further.
  const most = Math.min(0, (innerWidth - RAIL_LEFT) - railState.end);
  const next = Math.max(most, Math.min(0, railState.scroll + by));
  if (next === railState.scroll) return false;
  railState.scroll = next;
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

/* BRING THE SELECTION INTO VIEW.

   THE PACKING DOES THE WORK -- see `packRailNow`, which slides the row for
   whatever is selected every time it lays out. So all this has to do is put
   the page back at its origin and ask for a lay-out: the walk opens a tab,
   which changes the row's widths, and the packing that follows will find the
   selection off the side and bring it back.

   THE UNSCROLL IS NOT DECORATION. Focusing a pane that hangs off the edge
   makes the browser scroll the DOCUMENT to reach it, which shifts every panel
   left of where the row put it -- so the row's arithmetic comes out right and
   the screen still shows a window overhanging. Walking the tabs focuses a
   pane on every step. */
export function revealTab(panel) {
  if (!panel) return;
  unscrollPage();
  packRail();
}

// How long after the last wheel event the row is considered still. Cleared
// and reset by every event in a gesture, so a trackpad's stream counts as one
// scroll rather than as dozens.
let scrollRelease = 0;

// A WHEEL OVER THE ROW, either axis. A trackpad swipe sideways arrives as
// deltaX and a mouse wheel as deltaY, and both mean the same thing here --
// there is one direction the row can go.
window.addEventListener('wheel', (e) => {
  // Only over the row itself: the graph owns the wheel everywhere else, and
  // taking it here would break zooming for the top of the page.
  if (e.clientY > RAIL_TOP + railHeight()) return;
  // NO SECOND OPINION ABOUT WHETHER THE ROW FITS. This used to ask
  // `railOverflows` first, which reads a number written the last time the row
  // was laid out -- so a wheel arriving after any width changed was turned
  // away on stale arithmetic before `scrollRail` could measure. Asking once,
  // where the measuring happens, is the whole fix.
  const by = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? -e.deltaX : -e.deltaY;
  // THE ROW STAYS WHERE THE HAND PUTS IT. Held over the whole gesture rather
  // than one event: a trackpad sends a stream of them, and a flag cleared
  // between two would let the frame in the gap pull the row back.
  railState.scrolling = true;
  clearTimeout(scrollRelease);
  scrollRelease = setTimeout(() => { railState.scrolling = false; }, 400);
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

function railChanged() {
  const now = railShape();
  if (now === railState.widths) return false;
  railState.widths = now;
  return true;
}
setInterval(() => {
  if (railState.dragging) return;
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
    // MEASURED ONCE, and every decision made from that one reading. The
    // version this replaces read the box, wrote a height, then asked the same
    // box for its top -- a value the write had just invalidated, so the
    // browser had to lay the page out again to answer, and the answer was for
    // a window that had already moved.
    const box = root.getBoundingClientRect();
    const want = Object.assign({}, ...names.map((name) => EDGES[name] && EDGES[name].fill(box)));
    if (want.height === undefined) continue;

    const h = Math.max(120, want.height);
    // WHERE IT ENDS UP, worked out before anything is written: the height it
    // should have, and the top that height needs if there is not room below
    // where it sits now.
    const top = h > innerHeight - box.top ? Math.max(0, innerHeight - h) : box.top;
    const wantsHeight = Math.abs(box.height - h) > 0.5;
    const wantsTop = Math.abs(box.top - top) > 0.5;
    if (!wantsHeight && !wantsTop) continue;

    if (wantsHeight) root.style.height = h + 'px';
    if (wantsTop) root.style.top = top + 'px';
    moved = true;
    // Per panel, so one window being stretched does not tell every other
    // window that it moved.
    if (panel && panel.resized) panel.resized();
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
  railState.dragging = panel.root;
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
  railState.dragging = null;
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
    // Bringing it into view is the packing's job -- see `packRailNow`. The
    // selection is one of the things that can put a tab out of sight, but so
    // is opening one, and so is a neighbour growing; the row handles all of
    // them in the one place rather than each caller remembering.
    packRail();
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
// already refuses it outright (wterm's input handler returns on a bare cmd
// without sending anything), so nothing is taken from the program that it
// ever had.
//
// `activeElement` still answers this correctly now that the keyboard lives
// on wterm's textarea: that textarea is a child of the screen, so it is
// inside `.term` like any other part of a pane.
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
