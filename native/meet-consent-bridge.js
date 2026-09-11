#!/usr/bin/env node
// Drop-in Linux replacement for Granola's compiled meet-consent-host binary.
// It relays between Chrome and the app socket, both directions:
//   stdin/stdout : 4-byte little-endian length + JSON (Chrome native messaging)
//   unix socket  : newline-delimited JSON (the app's framing)
'use strict';
const os = require('os');
const crypto = require('crypto');
const net = require('net');

// The app binds /tmp/granola-meet-consent-<sha256($HOME)[0:12]>.sock and also
// listens on a legacy /tmp/granola-meet-consent.sock. GRANOLA_BRIDGE_SOCKET
// overrides the candidates (used by the installer's smoke test).
const hash = crypto.createHash('sha256').update(os.homedir()).digest('hex').slice(0, 12);
const candidates = (process.env.GRANOLA_BRIDGE_SOCKET || '')
  .split(':').filter(Boolean)
  .concat([`/tmp/granola-meet-consent-${hash}.sock`, '/tmp/granola-meet-consent.sock']);

let sock = null;
let connecting = false;
let stdinBuf = Buffer.alloc(0);
let socketBuf = Buffer.alloc(0);
let pending = [];

function toChrome(json) {
  const body = Buffer.from(json, 'utf8');
  const out = Buffer.alloc(4 + body.length);
  out.writeUInt32LE(body.length, 0); // native byte order (little-endian on supported targets)
  body.copy(out, 4);
  process.stdout.write(out);
}

function stake(local) {
  const s = net.createConnection(local);
  s.on('connect', () => {
    connecting = false;
    if (sock && sock !== s) { s.destroy(); return; }
    sock = s;
    if (pending.length) {
      const batch = pending; pending = [];
      sock.write(Buffer.concat(batch));
    }
  });
  s.on('data', (d) => {
    socketBuf = Buffer.concat([socketBuf, d]);
    let n;
    while ((n = socketBuf.indexOf(0x0a)) >= 0) {
      toChrome(socketBuf.subarray(0, n).toString('utf8'));
      socketBuf = socketBuf.subarray(n + 1);
    }
  });
  s.on('error', () => { connecting = false; if (sock === s) sock = null; s.destroy(); });
  s.on('close', () => { connecting = false; if (sock === s) sock = null; });
  return s;
}

let slot = 0;
function connect() {
  if (!sock && !connecting) {
    connecting = true;
    stake(candidates[slot++ % candidates.length]);
  }
}
connect();
setInterval(connect, 1500);

process.stdin.on('data', (d) => {
  stdinBuf = Buffer.concat([stdinBuf, d]);
  while (stdinBuf.length >= 4) {
    // Length prefix is 32-bit in the platform's native byte order; all
    // supported targets (x86-64/arm64) are little-endian, hence readUInt32LE.
    const len = stdinBuf.readUInt32LE(0);
    // Chrome caps messages sent to a host at 64 MiB; 1 MiB is the limit in
    // the host->Chrome direction only. A larger length means the stream is
    // corrupt with no recoverable framing, so fail rather than misparse.
    if (len > 64 * 1024 * 1024) {
      process.stderr.write('meet-consent-host: invalid frame length ' + len + '\n');
      process.exit(1);
    }
    if (stdinBuf.length < 4 + len) break;
    const body = stdinBuf.subarray(4, 4 + len);
    stdinBuf = stdinBuf.subarray(4 + len);
    const line = Buffer.concat([body, Buffer.from([0x0a])]);
    if (sock) sock.write(line); else pending.push(line);
  }
});
process.stdin.on('end', () => process.exit(0));
