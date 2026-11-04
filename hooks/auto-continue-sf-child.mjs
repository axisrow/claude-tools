#!/usr/bin/env node
// Detached child of auto-continue-sf.sh: CC kills StopFailure hooks in ~10-50ms,
// so the slow work lives here (new process session via perl-setsid, see launcher).
//
// Pipeline: sleep -> verify the session is STILL stalled on the "API Error: ...
// The response above may be incomplete." family (canonical carrier:
// main-chain assistant, model '<synthetic>', cf. claude-devtools toolStats.ts)
// and that nobody prompted it meanwhile -> deliver "Continue task" into the
// session's own CC inbox socket:
//   $CLAUDE_CODE_MESSAGING_SOCKET (+ $CLAUDE_CODE_MESSAGING_TOKEN), both
//   exported by Claude Code to hooks before any hook runs.
// Frame (from the uds-messaging startup log inside the CC binary):
//   {"type":"auth","token":"<token>"}
//   {"type":"user","message":{"role":"user","content":"Continue task"}}
// An own-child verified post lands as a user message; when the session is idle
// (a stream cut leaves it idle), CC starts a new turn with it — the native
// cross-session-messaging wake path, no external tools involved.
//
// Budget: the same 3-rounds/10-min state file as the Stop branch (shared
// counter — when upstream fixes #87972 both channels draw on one budget). No
// usable session id -> no budget -> no steer (fail-safe, like the Stop branch).
// Non-family failures (429/ECONNRESET) are skipped; messaging off -> sf-nosock.
// Dry-run: AUTOCONTINUE_DRY_RUN=1 -> log only, no socket.
// claude-tools#24, anthropics/claude-code#87972.
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { homedir } from 'node:os';

import { isCut, readTailLines } from './auto-continue-common.mjs';

// ponytail: calibration knobs, not config — tests shorten the delay via env
const STALL_CONFIRM_MS = Number(process.env.AUTOCONTINUE_CONFIRM_MS) || 12_000;
const MAX_ROUNDS = 3;
const BUDGET_TTL_MS = 10 * 60_000;
const TAIL_BYTES = 1 << 18;
const SOCKET_ACK_MS = 5000; // the inbox never acks; this only bounds the child's life
const SESSION_RE = /^[\w-]+$/;
const LOG = `${homedir()}/.claude/claude-autocontinue.log`;

const hook = (() => {
  try {
    return JSON.parse(process.argv[2] ?? '{}');
  } catch {
    return {};
  }
})();
if (hook.hook_event_name !== 'StopFailure') process.exit(0);
// tmux sessions are owned by claude-auto-retry (it watches the pane and sends
// continue itself) — our socket post would double-continue those
if (process.env.TMUX) process.exit(0);
const transcriptPath = hook.transcript_path;
const sessionId = typeof hook.session_id === 'string' && SESSION_RE.test(hook.session_id) ? hook.session_id : null;
// no usable session id -> no budget ownership -> no steer (fail-safe)
if (!transcriptPath || !sessionId) process.exit(0);

function log(kind, extra) {
  try {
    appendFileSync(LOG, `${new Date().toISOString()} kind=${kind} session=${sessionId.slice(0, 8)} ${extra}\n`);
  } catch {}
}

function parse(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

const isMainChainAssistant = (m) => m.type === 'assistant' && m.isSidechain !== true;
// any real user-side input newer than the cut means the session got input
// already (fresh prompt, teammate message, pasted image) — do not double-steer;
// tool_result arrays are bookkeeping, not input
const isFreshInput = (m) => {
  if (m.type !== 'user' || m.isSidechain === true) return false;
  const c = m.message?.content;
  if (typeof c === 'string') return true;
  return Array.isArray(c) && c.some((b) => b?.type !== 'tool_result');
};

function stateDir() {
  return `${homedir()}/.claude/claude-autocontinue-state`;
}

function readRounds() {
  try {
    const s = JSON.parse(readFileSync(`${stateDir()}/${sessionId}.json`, 'utf8'));
    return Date.now() - s.ts < BUDGET_TTL_MS ? s.count : 0;
  } catch {
    return 0;
  }
}

function writeRounds(count) {
  try {
    mkdirSync(stateDir(), { recursive: true });
    writeFileSync(`${stateDir()}/${sessionId}.json`, JSON.stringify({ count, ts: Date.now() }));
    return true;
  } catch {
    return false;
  }
}

/** Post text into the session's own inbox socket; true when written. */
function socketPost(text) {
  const sockPath = process.env.CLAUDE_CODE_MESSAGING_SOCKET;
  if (!sockPath) return Promise.resolve(false);
  return new Promise((resolve) => {
    let done = false;
    const finish = (ok) => {
      if (done) return;
      done = true;
      s.destroy();
      resolve(ok);
    };
    const s = connect(sockPath, () => {
      try {
        const lines = [
          JSON.stringify({ type: 'auth', token: process.env.CLAUDE_CODE_MESSAGING_TOKEN }),
          JSON.stringify({ type: 'user', message: { role: 'user', content: text } }),
        ];
        s.write(lines.join('\n') + '\n');
      } catch {
        finish(false);
      }
      s.end();
    });
    s.on('error', () => finish(false));
    s.on('close', () => finish(true));
    setTimeout(() => finish(false), SOCKET_ACK_MS);
  });
}

setTimeout(async () => {
  try {
    if (!existsSync(transcriptPath)) return;
    // per-session kill switch (same marker the Stop branch honors)
    if (existsSync(`${homedir()}/.claude/claude-autocontinue-off/${sessionId}`)) return log('sf-off');
    // only assistant and user lines are ever inspected — skip parse for the rest
    const lines = readTailLines(transcriptPath, TAIL_BYTES).map((l) =>
      l.includes('"type":"assistant"') || l.includes('"type":"user"') ? parse(l) : null,
    );
    const newestAssistantIdx = lines.findIndex((m) => m && isMainChainAssistant(m));
    if (newestAssistantIdx === -1) return log('sf-noassistant');
    const cut = lines[newestAssistantIdx];
    if (!isCut(cut)) return log('sf-notfamily', `model=${cut?.message?.model}`);
    if (lines.slice(0, newestAssistantIdx).some((m) => m && isFreshInput(m))) {
      return log('sf-hasinput');
    }

    const rounds = readRounds();
    if (rounds >= MAX_ROUNDS) return log('sf-cap', `rounds=${rounds} cutUuid=${cut.uuid}`);
    // budget is spent on the decision: a failed delivery burns a round too —
    // conservative, and dry-run never touches the socket
    if (!writeRounds(rounds + 1)) return log('nostate');
    if (process.env.AUTOCONTINUE_DRY_RUN === '1') {
      return log('sf-dry', `cutUuid=${cut.uuid}`);
    }
    if (!process.env.CLAUDE_CODE_MESSAGING_SOCKET) return log('sf-nosock');
    const sent = await socketPost('Continue task');
    log(sent ? 'socket-send' : 'socket-fail', `cutUuid=${cut.uuid}`);
  } catch (e) {
    log('sf-error', `err=${String(e?.message ?? e).slice(0, 80)}`);
  } finally {
    process.exit(0);
  }
}, STALL_CONFIRM_MS);
