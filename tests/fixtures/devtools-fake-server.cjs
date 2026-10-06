#!/usr/bin/env node
'use strict';
// Stand-in for the chrome-devtools MCP server, driven by the launcher tests.
// Newline-delimited JSON-RPC on stdio. Answers initialize, tools/list and
// tools/call (result text "isolated=<true|false>" from its own argv), ignores
// notifications, and exits 0 when stdin ends - like the real server.
//
// Env knobs:
//   FAKE_LOG=<file>            append one line of argv per start
//   FAKE_FAIL_ISOLATED=1       exit 1 at once when started with --isolated
//   FAKE_LIST_DELAY_MS=<n>     delay tools/list replies, shared (non-isolated) instance only
//   FAKE_SERVER_REQUEST=1      server-initiated roots/list (id 900, the same id on both instances):
//                              shared asks on tools/list and logs the client's answer to
//                              FAKE_REPLY_LOG; isolated asks on tools/call and echoes the answer in its result
//   tools/call name "big"      replies with a 2 MiB text payload on one line

const fs = require('fs');

const isolated = process.argv.includes('--isolated');
if (process.env.FAKE_LOG) fs.appendFileSync(process.env.FAKE_LOG, process.argv.slice(2).join(' ') + '\n');
if (isolated && process.env.FAKE_FAIL_ISOLATED === '1') process.exit(1);

const BIG_BYTES = 2 * 1024 * 1024;
const listDelay = !isolated ? Number(process.env.FAKE_LIST_DELAY_MS || 0) : 0;

function reply(msg) {
  if (msg.id === undefined || typeof msg.method !== 'string') return null;
  if (msg.method === 'initialize') {
    return {
      jsonrpc: '2.0',
      id: msg.id,
      result: { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'fake', version: '0' } },
    };
  }
  if (msg.method === 'tools/list') return { jsonrpc: '2.0', id: msg.id, result: { tools: [] } };
  if (msg.method === 'tools/call') {
    const big = msg.params && msg.params.name === 'big';
    const text = big ? 'x'.repeat(BIG_BYTES) : `isolated=${isolated}`;
    return { jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text }] } };
  }
  return null;
}

const askRoots = process.env.FAKE_SERVER_REQUEST === '1';
const ROOTS_ID = 900;
let heldCall = null;

function askClient() {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: ROOTS_ID, method: 'roots/list' }) + '\n');
}

// Returns true when the line was the client's answer to our roots/list request.
function handleRootsAnswer(msg) {
  if (!askRoots || Array.isArray(msg) || msg.method !== undefined || msg.id !== ROOTS_ID) return false;
  if (isolated && heldCall) {
    const text = `isolated=true;reply=${JSON.stringify(msg.result)}`;
    process.stdout.write(
      JSON.stringify({ jsonrpc: '2.0', id: heldCall.id, result: { content: [{ type: 'text', text }] } }) + '\n'
    );
    heldCall = null;
  } else if (!isolated && process.env.FAKE_REPLY_LOG) {
    fs.appendFileSync(process.env.FAKE_REPLY_LOG, `shared:${JSON.stringify(msg.result)}\n`);
  }
  return true;
}

function handle(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (handleRootsAnswer(msg)) return;
  if (askRoots && !Array.isArray(msg)) {
    if (!isolated && msg.method === 'tools/list') askClient();
    if (isolated && msg.method === 'tools/call') {
      heldCall = msg;
      askClient();
      return;
    }
  }
  const out = Array.isArray(msg) ? msg.map(reply).filter(Boolean) : reply(msg);
  if (!out || (Array.isArray(out) && out.length === 0)) return;
  const emit = () => process.stdout.write(JSON.stringify(out) + '\n');
  const isList = !Array.isArray(msg) && msg.method === 'tools/list';
  if (isList && listDelay > 0) setTimeout(emit, listDelay);
  else emit();
}

let pending = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  pending += chunk;
  let at;
  while ((at = pending.indexOf('\n')) >= 0) {
    const line = pending.slice(0, at);
    pending = pending.slice(at + 1);
    if (line.trim()) handle(line);
  }
});
process.stdin.on('end', () => process.exit(0));
