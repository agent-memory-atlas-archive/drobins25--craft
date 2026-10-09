#!/usr/bin/env node
'use strict';
// Launcher for the bundled chrome-devtools MCP server.
//
// This file sits between Claude Code and every browser call craft makes, so the
// rule for everything here is: never fail closed. Any error while reading the
// profile lock reads as "free", which is exactly what happens without a launcher.
// The only evidence that counts as "taken" is a lock naming a live process.
//
// Verbs: status | notice [--quiet] | --dry-run [--assume shared|isolated]
// No verb: serve mode, a stdio proxy in front of the pinned server (see serve()).

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const PINNED_VERSION = '1.10.1';
const FALLBACK_NOTICE =
  'Another session has the browser open, so this one gets a fresh window - you may need to sign in there.';

const MAX_ANCESTOR_HOPS = 40;

function serverArgv({ isolated, platform = process.platform }) {
  const args = [
    '-y',
    `chrome-devtools-mcp@${PINNED_VERSION}`,
    '--no-usage-statistics',
    '--no-performance-crux',
  ];
  if (isolated) args.push('--isolated');
  // Node refuses to spawn npx.cmd without a shell; the static args need no quoting.
  return { command: 'npx', args, shell: platform === 'win32' };
}

function defaultProfileDir() {
  return (
    process.env.CRAFT_DEVTOOLS_PROFILE_DIR ||
    path.join(os.homedir(), '.cache', 'chrome-devtools-mcp', 'chrome-profile')
  );
}

const defaultProbe = {
  readlink: (p) => fs.readlinkSync(p),
  isAlive(pid) {
    try {
      process.kill(pid, 0);
      return true;
    } catch (err) {
      // EPERM: the process exists but belongs to another user.
      return Boolean(err) && err.code === 'EPERM';
    }
  },
  openForWrite(p) {
    const fd = fs.openSync(p, 'r+');
    fs.closeSync(fd);
  },
};

// held:true only on positive evidence of a live holder. Everything else,
// including every thrown error, is free.
function lockState(opts = {}) {
  try {
    const platform = opts.platform || process.platform;
    const profileDir = opts.profileDir || defaultProfileDir();
    const probe = { ...defaultProbe, ...(opts.probe || {}) };

    if (platform === 'win32') {
      try {
        probe.openForWrite(path.join(profileDir, 'lockfile'));
        return { held: false, reason: 'lockfile opens for write' };
      } catch (err) {
        if (err && err.code === 'EBUSY') return { held: true, reason: 'lockfile is held open' };
        return { held: false, reason: 'lockfile unreadable or absent' };
      }
    }

    const target = String(probe.readlink(path.join(profileDir, 'SingletonLock')));
    const cut = target.lastIndexOf('-');
    if (cut <= 0) return { held: false, reason: 'lock target is not host-pid' };
    const host = target.slice(0, cut);
    const pidText = target.slice(cut + 1);
    if (!/^\d+$/.test(pidText)) return { held: false, reason: 'lock pid is not a number' };
    const pid = Number(pidText);
    const here = opts.hostname || os.hostname();
    if (host !== here) return { held: false, reason: 'lock names another host' };
    if (!probe.isAlive(pid)) return { held: false, reason: 'lock names a dead process' };
    return { held: true, reason: 'lock names a live process on this host' };
  } catch (err) {
    const why = err && err.code ? err.code : 'error';
    return { held: false, reason: `lock check failed (${why})` };
  }
}

// ---- marker -------------------------------------------------------------

function stateDir() {
  return process.env.CRAFT_DEVTOOLS_STATE_DIR || path.join(os.homedir(), '.cache', 'craft', 'devtools');
}

// A key becomes a file name in the state folder, so one from the environment is
// used only when it is a plain name; anything with a path in it is ignored.
function safeKey(key) {
  return typeof key === 'string' && /^[\w.-]+$/.test(key) ? key : null;
}

function markerKey() {
  return safeKey(process.env.CRAFT_DEVTOOLS_KEY) || String(process.ppid);
}

function writeMarker(mode, key = markerKey()) {
  try {
    const dir = stateDir();
    fs.mkdirSync(dir, { recursive: true });
    const body = JSON.stringify({
      mode,
      launcher_pid: process.pid,
      version: PINNED_VERSION,
      at: new Date().toISOString(),
    });
    const tmp = path.join(dir, `.${key}.${process.pid}.tmp`);
    fs.writeFileSync(tmp, body);
    fs.renameSync(tmp, path.join(dir, `${key}.json`));
  } catch {
    // A marker is a courtesy; losing it must never cost the browser.
  }
}

function readMarker(key) {
  try {
    const m = JSON.parse(fs.readFileSync(path.join(stateDir(), `${key}.json`), 'utf8'));
    if (!m || typeof m.launcher_pid !== 'number') return null;
    if (!['pending', 'shared', 'isolated'].includes(m.mode)) return null;
    if (!defaultProbe.isAlive(m.launcher_pid)) return null;
    return m;
  } catch {
    return null;
  }
}

function parentPid(pid) {
  try {
    const r = spawnSync('ps', ['-o', 'ppid=', '-p', String(pid)], { encoding: 'utf8', timeout: 2000 });
    const n = Number(String(r.stdout || '').trim());
    return Number.isInteger(n) && n > 1 ? n : null;
  } catch {
    return null;
  }
}

function findMarker() {
  const keys = [process.env.CRAFT_DEVTOOLS_KEY, process.env.CLAUDE_PID].map(safeKey).filter(Boolean);
  for (const key of keys) {
    const m = readMarker(key);
    if (m) return m;
  }
  if (process.platform === 'win32') return null;
  let pid = process.ppid;
  for (let hop = 0; pid && hop < MAX_ANCESTOR_HOPS; hop++) {
    const m = readMarker(String(pid));
    if (m) return m;
    pid = parentPid(pid);
  }
  return null;
}

// ---- verbs --------------------------------------------------------------

function cmdStatus() {
  const m = findMarker();
  process.stdout.write((m ? m.mode.toUpperCase() : 'NONE') + '\n');
}

function cmdNotice(quiet) {
  const m = findMarker();
  if (!m || m.mode !== 'isolated') return;
  const flag = path.join(os.tmpdir(), `craft-devtools-noticed-${m.launcher_pid}`);
  try {
    // An exclusive create: only the call that makes the flag prints, and a
    // path someone else planted is never written through.
    fs.writeFileSync(flag, '', { flag: 'wx' });
  } catch (err) {
    if (err && err.code === 'EEXIST') return;
    // Cannot record it: the line repeats rather than going missing.
  }
  if (!quiet) process.stdout.write(FALLBACK_NOTICE + '\n');
}

function cmdDryRun(argv) {
  const at = argv.indexOf('--assume');
  const assumed = at >= 0 ? argv[at + 1] : undefined;
  const isolated = assumed ? assumed === 'isolated' : lockState().held;
  const { command, args, shell } = serverArgv({ isolated });
  process.stdout.write(JSON.stringify({ mode: isolated ? 'isolated' : 'shared', command, args, shell }) + '\n');
}

// ---- serve mode ---------------------------------------------------------
//
// An MCP stdio proxy. The server starts with the session but opens Chrome only at
// the first tools/call, so that call is where the profile collision can happen and
// where the shared/isolated decision is made. Free: the shared child keeps serving.
// Held by a live browser: an isolated twin is started, the pre-call client lines are
// replayed to it, and traffic moves there. Every failure on that path lands the call
// on the shared child, which has not opened Chrome yet.
//
// stdout carries only bytes from the active child (one stray byte corrupts the
// JSON-RPC stream); diagnostics go to stderr.

const NL = Buffer.from('\n');
const REPLAY_TIMEOUT_MS = 15000;
const DRAIN_TIMEOUT_MS = 15000;
const RETIRE_GRACE_MS = 2000;
// Server lines above this are results (screenshots, snapshots), never the small
// handshake/request lines the relay needs to inspect, so they are not parsed.
const PARSE_LIMIT = 256 * 1024;

function log(message) {
  try {
    process.stderr.write(`craft-devtools: ${message}\n`);
  } catch {
    // Nowhere left to report to.
  }
}

// Env seam for tests: swap the `npx -y chrome-devtools-mcp@<ver>` prefix for a script,
// keeping the trailing flags (and --isolated) identical.
function childCommand(isolated) {
  const base = serverArgv({ isolated });
  const fake = process.env.CRAFT_DEVTOOLS_SERVER;
  if (!fake) return base;
  return { command: process.execPath, args: [fake, ...base.args.slice(2)], shell: false };
}

// Splits a byte stream into newline-terminated lines. Scans raw bytes for 0x0A and
// never builds strings, so multi-byte characters split across chunks cannot corrupt
// a line and a multi-megabyte line costs one concat, not one per chunk.
class LineSplitter {
  constructor() {
    this.parts = [];
  }
  // Returns the complete lines in `chunk`, each including its trailing newline.
  split(chunk) {
    const lines = [];
    let from = 0;
    let at;
    while ((at = chunk.indexOf(0x0a, from)) >= 0) {
      this.parts.push(chunk.subarray(from, at + 1));
      lines.push(this.parts.length === 1 ? this.parts[0] : Buffer.concat(this.parts));
      this.parts = [];
      from = at + 1;
    }
    if (from < chunk.length) this.parts.push(chunk.subarray(from));
    return lines;
  }
  take() {
    const rest = Buffer.concat(this.parts);
    this.parts = [];
    return rest;
  }
}

function parseLine(line) {
  try {
    return JSON.parse(line.subarray(0, line.length - 1).toString('utf8'));
  } catch {
    return undefined;
  }
}

const idKey = (id) => JSON.stringify(id);
const isRequest = (m) => Boolean(m) && typeof m === 'object' && typeof m.method === 'string' && m.id !== undefined && m.id !== null;
const isResponse = (m) => Boolean(m) && typeof m === 'object' && m.method === undefined && m.id !== undefined && m.id !== null;

function pruneDeadMarkers() {
  try {
    const dir = stateDir();
    for (const name of fs.readdirSync(dir)) {
      if (!name.endsWith('.json')) continue;
      try {
        const file = path.join(dir, name);
        const m = JSON.parse(fs.readFileSync(file, 'utf8'));
        if (m && typeof m.launcher_pid === 'number' && !defaultProbe.isAlive(m.launcher_pid)) fs.unlinkSync(file);
      } catch {
        // Unreadable or already gone: leave it for the next start.
      }
    }
  } catch {
    // Pruning is housekeeping.
  }
}

// A notice flag is keyed by the launcher's pid and outlives it. At start-up no
// notice has been said for this launcher, so a flag carrying its own pid was left
// by an earlier launcher the OS gave the same pid; that one and every flag of a
// dead launcher go, so a reused pid never silences the next notice.
function pruneNoticeFlags(ownPid = process.pid) {
  try {
    const dir = os.tmpdir();
    for (const name of fs.readdirSync(dir)) {
      const hit = /^craft-devtools-noticed-(\d+)$/.exec(name);
      if (!hit) continue;
      const pid = Number(hit[1]);
      if (pid !== ownPid && defaultProbe.isAlive(pid)) continue;
      try {
        fs.unlinkSync(path.join(dir, name));
      } catch {
        // Already gone.
      }
    }
  } catch {
    // Pruning is housekeeping.
  }
}

function serve() {
  const stdin = process.stdin;
  const stdout = process.stdout;
  const clientSplit = new LineSplitter();

  let state = 'pre'; // pre -> switching -> decided
  let inspect = true; // true while two children can exist, so lines must be classified
  let raw = false; // true once the pump failed open
  let finished = false;
  let decided = false;
  let draining = false;
  let active = null;
  let sharedChild = null;
  let twinChild = null;
  let queue = [];
  const history = []; // client lines before the decision, replayed to the twin
  const replayIds = new Set();
  const pendingShared = new Set(); // request ids sent to the shared child, not yet answered
  const serverRequests = []; // { child, key }: server-initiated requests awaiting a client response
  let replayTimer = null;
  let drainTimer = null;

  function startChild(isolated, name) {
    const { command, args, shell } = childCommand(isolated);
    const proc = spawn(command, args, {
      stdio: ['pipe', 'pipe', 'inherit'],
      shell,
      env: { ...process.env, CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: '1' },
    });
    const child = { name, proc, split: new LineSplitter(), retired: false, dead: false, code: null };
    proc.stdin.on('error', (err) => log(`${name} stdin: ${err && err.code}`));
    proc.stdout.on('error', (err) => log(`${name} stdout: ${err && err.code}`));
    proc.on('error', (err) => {
      log(`${name} failed to start: ${err && err.message}`);
      onChildGone(child, 1);
    });
    proc.on('close', (code) => onChildGone(child, code === null ? 1 : code));
    proc.stdout.on('data', (chunk) => onServerData(child, chunk));
    return child;
  }

  function writable(child) {
    return !child.dead && !child.retired && child.proc.stdin.writable;
  }

  function sendToChild(child, buf) {
    if (!writable(child)) return;
    if (!child.proc.stdin.write(buf)) {
      stdin.pause();
      child.proc.stdin.once('drain', () => stdin.resume());
    }
  }

  function sendToClient(child, buf) {
    if (!stdout.write(buf)) {
      child.proc.stdout.pause();
      stdout.once('drain', () => child.proc.stdout.resume());
    }
  }

  // End a child's stdin (the server exits on it), then SIGTERM if it lingers.
  function retire(child) {
    if (child.retired) return;
    child.retired = true;
    try {
      child.proc.stdin.end();
    } catch {
      // Already closed.
    }
    const timer = setTimeout(() => {
      if (!child.dead) {
        try {
          child.proc.kill('SIGTERM');
        } catch {
          // Already gone.
        }
      }
    }, RETIRE_GRACE_MS);
    timer.unref();
  }

  function finish(code) {
    if (finished) return;
    finished = true;
    for (const child of [sharedChild, twinChild]) {
      if (child && !child.dead) retire(child);
    }
    stdout.write('', () => process.exit(code));
    setTimeout(() => process.exit(code), 500).unref();
  }

  function onChildGone(child, code) {
    child.dead = true;
    child.code = code;
    if (child === sharedChild) {
      pendingShared.clear();
      checkDrain();
    }
    if (child.retired && child !== active) return;
    if (child === twinChild && state === 'switching') return fallBackToShared(`twin exited (${code})`);
    if (child === active && state !== 'switching') finish(code);
  }

  // ---- fail open: any exception in the pump drops to raw pipes ----
  function failOpen(err, toChild, toClient, from) {
    if (raw) return;
    raw = true;
    log(`relay fault, passing bytes through: ${err && err.message}`);
    try {
      if (state === 'switching') {
        clearTimeout(replayTimer);
        if (twinChild) retire(twinChild);
        active = sharedChild;
        state = 'decided';
      }
      if (draining && sharedChild !== active) retire(sharedChild);
      const target = active;
      for (const buf of toClient) stdout.write(buf);
      for (const buf of toChild) if (writable(target)) target.proc.stdin.write(buf);
      stdin.removeAllListeners('data');
      for (const child of [sharedChild, twinChild]) if (child) child.proc.stdout.removeAllListeners('data');
      stdin.pipe(target.proc.stdin);
      target.proc.stdout.pipe(stdout, { end: false });
      if (from && from !== target) from.proc.stdout.resume();
    } catch (e) {
      log(`could not open raw pipe: ${e && e.message}`);
    }
  }

  // ---- decision ----
  function setMode(mode) {
    writeMarker(mode);
  }

  function decide(line) {
    decided = true; // lockState runs once per launcher process
    let held = false;
    try {
      held = lockState().held;
    } catch {
      held = false;
    }
    if (!held) {
      state = 'decided';
      inspect = false;
      pendingShared.clear();
      history.length = 0;
      setMode('shared');
      sendToChild(sharedChild, line);
      return;
    }
    state = 'switching';
    queue = [line];
    try {
      twinChild = startChild(true, 'isolated child');
    } catch (err) {
      return fallBackToShared(`could not start the isolated child: ${err && err.message}`);
    }
    for (const entry of history) sendToChild(twinChild, entry);
    replayTimer = setTimeout(() => fallBackToShared('isolated child did not answer the replay in time'), REPLAY_TIMEOUT_MS);
    checkReplay();
  }

  function checkReplay() {
    if (state === 'switching' && twinChild && replayIds.size === 0) commitToTwin();
  }

  function commitToTwin() {
    clearTimeout(replayTimer);
    state = 'decided';
    active = twinChild;
    setMode('isolated');
    for (const line of queue) sendToChild(twinChild, line);
    queue = [];
    history.length = 0;
    draining = true;
    drainTimer = setTimeout(() => endDrain(), DRAIN_TIMEOUT_MS);
    drainTimer.unref();
    checkDrain();
  }

  // The shared child stays up until every request sent to it has been answered.
  function checkDrain() {
    if (draining && pendingShared.size === 0) endDrain();
  }

  function endDrain() {
    if (!draining) return;
    draining = false;
    clearTimeout(drainTimer);
    inspect = false;
    serverRequests.length = 0;
    retire(sharedChild);
  }

  function fallBackToShared(reason) {
    if (state !== 'switching') return;
    clearTimeout(replayTimer);
    log(`${reason}; staying on the shared browser`);
    if (twinChild) retire(twinChild);
    state = 'decided';
    inspect = false;
    active = sharedChild;
    pendingShared.clear();
    history.length = 0;
    replayIds.clear();
    setMode('shared');
    if (sharedChild.dead) return finish(sharedChild.code === null ? 1 : sharedChild.code);
    for (const line of queue) sendToChild(sharedChild, line);
    queue = [];
  }

  // ---- client -> server ----
  function classifyClient(line) {
    const msg = parseLine(line);
    const items = Array.isArray(msg) ? msg : [msg];
    return {
      isCall: items.some((m) => Boolean(m) && typeof m === 'object' && m.method === 'tools/call'),
      requestKeys: items.filter(isRequest).map((m) => idKey(m.id)),
      responseKey: !Array.isArray(msg) && isResponse(msg) ? idKey(msg.id) : null,
    };
  }

  function takeIssuer(key) {
    const at = serverRequests.findIndex((r) => r.key === key);
    if (at < 0) return null;
    return serverRequests.splice(at, 1)[0].child;
  }

  function handleClientLine(line) {
    if (!inspect) return sendToChild(active, line);
    const info = classifyClient(line);
    if (info.responseKey !== null) {
      // A reply to a server-initiated request goes to the child that asked: ids can collide across children.
      const issuer = takeIssuer(info.responseKey);
      if (issuer) return sendToChild(issuer, line);
    }
    if (state === 'switching') {
      queue.push(line);
      return;
    }
    if (state === 'decided') return sendToChild(active, line);
    if (info.isCall && !decided) {
      if (process.env.CRAFT_DEVTOOLS_FAULT === 'pump') throw new Error('injected pump fault');
      return decide(line);
    }
    if (info.responseKey === null) {
      history.push(line);
      for (const key of info.requestKeys) {
        replayIds.add(key);
        pendingShared.add(key);
      }
    }
    sendToChild(sharedChild, line);
  }

  function onClientData(chunk) {
    if (raw) return;
    const lines = clientSplit.split(chunk);
    let at = 0;
    try {
      for (; at < lines.length; at++) handleClientLine(lines[at]);
    } catch (err) {
      failOpen(err, [...lines.slice(at), clientSplit.take()], [], null);
    }
  }

  // ---- server -> client ----
  function handleServerLine(child, line) {
    if (inspect && line.length <= PARSE_LIMIT) {
      const msg = parseLine(line);
      if (isRequest(msg)) {
        serverRequests.push({ child, key: idKey(msg.id) });
      } else if (isResponse(msg)) {
        const key = idKey(msg.id);
        if (child === sharedChild) {
          pendingShared.delete(key);
          sendToClient(child, line);
          checkDrain();
          return;
        }
        if (child === twinChild && state === 'switching' && replayIds.delete(key)) {
          checkReplay();
          return;
        }
      }
    }
    sendToClient(child, line);
  }

  function onServerData(child, chunk) {
    if (raw || child.retired && child !== sharedChild) return;
    const lines = child.split.split(chunk);
    let at = 0;
    try {
      for (; at < lines.length; at++) {
        // The replay answers are swallowed by id; a retired twin's output is dropped.
        if (child.retired) return;
        handleServerLine(child, lines[at]);
      }
    } catch (err) {
      failOpen(err, [], [...lines.slice(at), child.split.take()], child);
    }
  }

  // ---- wiring ----
  stdout.on('error', () => finish(0));
  stdin.on('error', (err) => log(`stdin: ${err && err.code}`));
  stdin.on('data', onClientData);
  stdin.on('end', () => {
    for (const child of [sharedChild, twinChild]) if (child && !child.dead) retire(child);
  });
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => {
      for (const child of [sharedChild, twinChild]) {
        if (child && !child.dead) {
          try {
            child.proc.kill(sig);
          } catch {
            // Already gone.
          }
        }
      }
      finish(0);
    });
  }
  process.on('exit', () => {
    for (const child of [sharedChild, twinChild]) {
      if (child && !child.dead) {
        try {
          child.proc.kill('SIGTERM');
        } catch {
          // Already gone.
        }
      }
    }
  });

  pruneDeadMarkers();
  pruneNoticeFlags();
  sharedChild = startChild(false, 'shared child');
  active = sharedChild;
  writeMarker('pending');
}

function main(argv) {
  try {
    if (argv.includes('--dry-run')) return cmdDryRun(argv);
    if (argv[0] === 'status') return cmdStatus();
    if (argv[0] === 'notice') return cmdNotice(argv.includes('--quiet'));
    return serve();
  } catch (err) {
    process.stderr.write(`craft-devtools: ${err && err.message}\n`);
  }
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = { PINNED_VERSION, FALLBACK_NOTICE, serverArgv, lockState, pruneNoticeFlags };
