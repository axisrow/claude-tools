#!/usr/bin/env node
// Detached child of auto-continue-sf.sh: CC kills StopFailure hooks in ~10-50ms,
// so the slow work lives here (new process session via perl-setsid, see launcher).
//
// Pipeline: sleep -> verify the session is STILL stalled on the "API Error: ...
// The response above may be incomplete." family (canonical carrier:
// main-chain assistant, model '<synthetic>', cf. claude-devtools toolStats.ts)
// and that nobody prompted it meanwhile -> steer the AO worker:
//   ao send --session <basename(cwd)> --message "Continue task" --steer
//           --client-message-id autocont-<cutUuid>
//
// Budget: the same 3-rounds/10-min state file as the Stop branch (shared
// counter — when upstream fixes #87972 both channels draw on one budget). No
// usable session id -> no budget -> no steer (fail-safe, like the Stop branch).
// AO targeting: cwd must be an AO worktree and the session record must report
// activity 'idle' — a stalled session is idle, so an active worker is somebody
// else's (basename is not an exact join; ao exposes no transcript path).
// Non-AO dirs and non-family failures (429/ECONNRESET) are skipped.
// Dry-run: AUTOCONTINUE_DRY_RUN=1 -> log only, no ao call.
// claude-tools#24, anthropics/claude-code#87972.
import { appendFileSync, closeSync, existsSync, fstatSync, mkdirSync, openSync, readFileSync, readSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { homedir } from 'node:os';

const SUFFIX = 'The response above may be incomplete.';
// ponytail: calibration knobs, not config — tests shorten the delay via env
const STALL_CONFIRM_MS = Number(process.env.AUTOCONTINUE_CONFIRM_MS) || 12_000;
const MAX_ROUNDS = 3;
const BUDGET_TTL_MS = 10 * 60_000;
const TAIL_BYTES = 1 << 18;
const AO_TIMEOUT_MS = 10_000; // a wedged ao daemon must not leak the child
// ponytail: AO-worktree prefix is fixed for this machine; env override is for tests
const AO_DIR_MARKER = process.env.AUTOCONTINUE_AO_DIR ?? '/.ao/data/worktrees/';
const LOG = `${homedir()}/.claude/claude-autocontinue.log`;

const hook = (() => {
  try {
    return JSON.parse(process.argv[2] ?? '{}');
  } catch {
    return {};
  }
})();
if (hook.hook_event_name !== 'StopFailure') process.exit(0);
const transcriptPath = hook.transcript_path;
const sessionId = typeof hook.session_id === 'string' ? hook.session_id : null;
const cwd = typeof hook.cwd === 'string' ? hook.cwd : null;
if (!transcriptPath || !cwd || !sessionId) process.exit(0);

function log(kind, extra) {
  try {
    appendFileSync(LOG, `${new Date().toISOString()} kind=${kind} session=${sessionId.slice(0, 8)} ${extra}\n`);
  } catch {}
}

function readTailLines(path) {
  const fd = openSync(path, 'r');
  try {
    const size = fstatSync(fd).size;
    const want = Math.min(size, TAIL_BYTES);
    const buf = Buffer.alloc(want);
    let read = 0;
    while (read < want) {
      const n = readSync(fd, buf, read, want - read, size - want + read);
      if (n <= 0) break;
      read += n;
    }
    const parts = buf.toString('utf8', 0, read).split('\n');
    parts.shift();
    return parts.filter(Boolean).reverse(); // newest-first
  } finally {
    closeSync(fd);
  }
}

function contentText(m) {
  const c = m.message?.content;
  if (typeof c === 'string') return c;
  if (!Array.isArray(c)) return '';
  return c.map((b) => (typeof b?.text === 'string' ? b.text : '')).join('');
}

function parse(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

const isMainChainAssistant = (m) => m.type === 'assistant' && m.isSidechain !== true;
const isCut = (m) => isMainChainAssistant(m) && m.message?.model === '<synthetic>' && contentText(m).includes(SUFFIX);
// any real user-side input newer than the cut means the session got input
// already (fresh prompt, AO steering relay, teammate message) — do not
// double-steer; array-content write-backs count too (the Stop-hook block
// write-back shape is unprobed, cf. turn-budget-hook's live probe)
const isFreshInput = (m) => {
  if (m.type !== 'user' || m.isSidechain === true) return false;
  const c = m.message?.content;
  if (typeof c === 'string') return true;
  return Array.isArray(c) && c.some((b) => typeof b?.text === 'string' && b.text.length > 0);
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

setTimeout(() => {
  try {
    if (!existsSync(transcriptPath)) return;
    const lines = readTailLines(transcriptPath).map(parse);
    const newestAssistantIdx = lines.findIndex((m) => m && isMainChainAssistant(m));
    if (newestAssistantIdx === -1) return log('sf-noassistant');
    const cut = lines[newestAssistantIdx];
    if (!isCut(cut)) return log('sf-notfamily', `model=${cut?.message?.model}`);
    if (lines.slice(0, newestAssistantIdx).some((m) => m && isFreshInput(m))) {
      return log('sf-hasinput');
    }

    const rounds = readRounds();
    if (rounds >= MAX_ROUNDS) return log('sf-cap', `rounds=${rounds} cutUuid=${cut.uuid}`);

    if (!cwd.includes(AO_DIR_MARKER)) return log('sf-nonao', `cwd=${basename(cwd)}`);
    const aoSession = basename(cwd);
    // budget is spent on the decision (before ao calls): a busy worker burns a
    // round too — conservative, and dry-run never touches the ao CLI
    if (!writeRounds(rounds + 1)) return log('nostate', `ao=${aoSession}`);
    if (process.env.AUTOCONTINUE_DRY_RUN === '1') {
      return log('sf-dry', `ao=${aoSession} cutUuid=${cut.uuid}`);
    }
    const get = spawnSync('ao', ['session', 'get', '--json', aoSession], {
      encoding: 'utf8',
      timeout: AO_TIMEOUT_MS,
    });
    if (get.status !== 0 || !get.stdout) return log('sf-noao', `ao=${aoSession}`);
    let record;
    try {
      record = JSON.parse(get.stdout).session;
    } catch {
      return log('sf-noao', `ao=${aoSession}`);
    }
    if (record?.isTerminated) return log('sf-noao', `ao=${aoSession} terminated`);
    if (record?.activity?.state !== 'idle') {
      return log('sf-busy', `ao=${aoSession} state=${record?.activity?.state}`);
    }

    if (process.env.AUTOCONTINUE_DRY_RUN === '1') {
      return log('sf-dry', `ao=${aoSession} cutUuid=${cut.uuid}`);
    }
    execFileSync('ao', [
      'send',
      '--session', aoSession,
      '--message', 'Continue task',
      '--steer',
      '--client-message-id', `autocont-${cut.uuid ?? Date.now()}`,
    ], { stdio: 'ignore', timeout: AO_TIMEOUT_MS });
    log('ao-send', `ao=${aoSession} cutUuid=${cut.uuid}`);
  } catch (e) {
    log('sf-error', `err=${String(e?.message ?? e).slice(0, 80)}`);
  } finally {
    process.exit(0);
  }
}, STALL_CONFIRM_MS);
