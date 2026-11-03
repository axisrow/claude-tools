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
// The client-message-id (stable handle) makes repeated detections of the same
// cut dedupe on AO's side. Non-AO dirs (no `ao session get` record) and
// non-family failures (429/ECONNRESET) are skipped. claude-tools#24,
// anthropics/claude-code#87972. AUTOCONTINUE_DRY_RUN=1 -> log only, no ao call.
import { appendFileSync, closeSync, fstatSync, openSync, readSync } from 'node:fs';
import { basename } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { homedir } from 'node:os';

const SUFFIX = 'The response above may be incomplete.';
// ponytail: calibration knob, not config — tests shorten it via env
const STALL_CONFIRM_MS = Number(process.env.AUTOCONTINUE_CONFIRM_MS) || 12_000;
const TAIL_BYTES = 1 << 18;
const LOG = `${homedir()}/.claude/claude-autocontinue.log`;

const [, , transcriptPath, sessionId, cwd] = process.argv;
if (!transcriptPath || !cwd) process.exit(0);

function log(kind, extra) {
  try {
    appendFileSync(LOG, `${new Date().toISOString()} kind=${kind} session=${String(sessionId ?? '?').slice(0, 8)} ${extra}\n`);
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
// any real user-side line newer than the cut means the session got input already
// (fresh prompt, AO steering relay, teammate message) — do not double-steer
const isFreshInput = (m) =>
  m.type === 'user' && m.isSidechain !== true && typeof m.message?.content === 'string';

setTimeout(() => {
  try {
    const lines = readTailLines(transcriptPath).map(parse);
    const newestAssistantIdx = lines.findIndex((m) => m && isMainChainAssistant(m));
    if (newestAssistantIdx === -1) return log('sf-noassistant');
    const cut = lines[newestAssistantIdx];
    if (!isCut(cut)) return log('sf-notfamily', `model=${cut?.message?.model}`);
    if (lines.slice(0, newestAssistantIdx).some((m) => m && isFreshInput(m))) {
      return log('sf-hasinput');
    }

    const aoSession = basename(cwd);
    if (process.env.AUTOCONTINUE_DRY_RUN === '1') {
      return log('sf-dry', `ao=${aoSession} cutUuid=${cut.uuid}`);
    }
    const get = spawnSync('ao', ['session', 'get', aoSession], { encoding: 'utf8' });
    if (get.status !== 0 || /terminated:\s*true/.test(get.stdout)) {
      return log('sf-noao', `ao=${aoSession}`);
    }
    execFileSync('ao', [
      'send',
      '--session', aoSession,
      '--message', 'Continue task',
      '--steer',
      '--client-message-id', `autocont-${cut.uuid ?? Date.now()}`,
    ], { stdio: 'ignore', timeout: 15_000 });
    log('ao-send', `ao=${aoSession} cutUuid=${cut.uuid}`);
  } catch (e) {
    log('sf-error', `err=${String(e?.message ?? e).slice(0, 80)}`);
  } finally {
    process.exit(0);
  }
}, STALL_CONFIRM_MS);
