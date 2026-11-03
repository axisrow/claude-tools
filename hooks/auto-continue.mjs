#!/usr/bin/env node
// Stop-hook auto-continue: when a stream cut ends the run with the
// "API Error: ... The response above may be incomplete." family as the newest
// main-chain assistant line, block the stop — Claude Code feeds the block
// reason ("Continue task") back as an instruction and keeps working.
//
// Pain (claude-devtools corpus, 2026-11-03): the family is 333 of 571 API
// errors over ~30 days (58%) and stalls the session until a manual continue.
// Fixes claude-tools#24 (upstream: anthropics/claude-code#105804, #103058).
//
// Trigger vs budget are separate concerns:
// - Trigger (transcript, read-only): newest main-chain assistant line is a
//   synthetic cut (message.model === '<synthetic>', the canonical carrier per
//   claude-devtools src/cli/toolStats.ts) whose text contains the suffix.
//   Real answers quoting the suffix never match (model check). Any other
//   main-chain assistant line (real partial, different synthetic error) ends
//   the series.
// - Budget (owned state, the cap): transcript line-counting cannot count
//   ROUNDS — a mid-response cut leaves a real partial assistant line above the
//   cut, resetting any line-series counter every round (corpus: 12 of 17
//   same-run cut pairs have real assistant lines between them). So the cap
//   counts blocks in a per-session state file: MAX_ROUNDS blocks per
//   BUDGET_TTL_MS, then the session stands until the budget goes stale (a
//   genuinely new run comes later; flaky-provider loops fire back-to-back).
//   A block whose round cannot be persisted is not delivered (fail-safe).
//
// Bails out (silent allow) on: normal stop, any other main-chain assistant
// line newest, user-interrupt marker in the tail, per-session off-marker
// (~/.claude/claude-autocontinue-off/<session-id>, manual kill switch),
// stale budget, wrong hook_event_name, and any error — a broken hook must
// never wedge stops. Known fail-open limits: CC flushes the transcript
// asynchronously (the newest cut may be missing at Stop — same as the
// turn-budget hook), and cuts hidden under >1 MiB of tail bookkeeping are
// not seen (single bounded tail read).
//
// Reference impl: claude-devtools/scripts/turn-budget-hook.mjs (fail-open
// main, transcript reading, marker-file kill switch). Registry: "auto-continue".

import {
  appendFileSync,
  closeSync,
  existsSync,
  fstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const INCOMPLETE_SUFFIX = 'The response above may be incomplete.';
// how Claude Code writes a user Esc-interrupt (seen in corpus transcripts)
const INTERRUPT_MARKER = '[Request interrupted';
// raw-JSON gate: only assistant lines can matter, skip parsing everything else
const ASSISTANT_GATE = '"type":"assistant"';
// ponytail: calibration knobs, not config — 3 blocked rounds per 10 min;
// raise TTL only if real incidents outlive it
const MAX_ROUNDS = 3;
const BUDGET_TTL_MS = 10 * 60_000;
// single bounded tail read; ceiling: a cut buried under more tail bookkeeping
// than this is missed (fail-open) — real cut tails are a few lines
const TAIL_BYTES = 1 << 20;
const MAX_WALK_LINES = 500;
const SESSION_RE = /^[\w-]+$/;

/** Last <=TAIL_BYTES bytes of the file, lines newest-first. The oldest
 * (possibly torn mid-UTF-8) fragment is dropped; short reads are looped. */
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
    return parts.filter(Boolean).reverse();
  } finally {
    closeSync(fd);
  }
}

function contentText(m) {
  const c = m.message?.content;
  if (typeof c === 'string') return c;
  if (!Array.isArray(c)) return '';
  // join without separator: a suffix straddling two blocks must still match
  return c.map((b) => (typeof b?.text === 'string' ? b.text : '')).join('');
}

function isCut(m) {
  return (
    m.type === 'assistant' &&
    m.isSidechain !== true &&
    m.message?.model === '<synthetic>' &&
    contentText(m).includes(INCOMPLETE_SUFFIX)
  );
}

/** Newest-first scan: trailing synthetic-cut series length plus whether the
 * tail carries a user-interrupt marker (explicit stop intent wins). */
function scanTail(linesNewestFirst) {
  let cuts = 0;
  let seen = 0;
  let interrupted = false;
  for (const line of linesNewestFirst) {
    // interrupt marker suppresses only while newer than any cut seen: an Esc
    // that PRE-dates the cut (tool-use deny, quoted marker text in a session
    // reading fixtures) must not silence a later real cut
    if (cuts === 0 && line.includes(INTERRUPT_MARKER)) interrupted = true;
    if (++seen >= MAX_WALK_LINES) break;
    if (!line.includes(ASSISTANT_GATE)) continue;
    let m;
    try {
      m = JSON.parse(line);
    } catch {
      continue;
    }
    if (m.type !== 'assistant' || m.isSidechain === true) continue;
    if (!isCut(m)) break;
    cuts++;
  }
  return { cuts, interrupted };
}

function stateDir() {
  return join(homedir(), '.claude', 'claude-autocontinue-state');
}

function offMarkerPath(session) {
  return join(homedir(), '.claude', 'claude-autocontinue-off', session);
}

/** Blocks already delivered for this session within the budget window. */
function readRounds(session) {
  try {
    const s = JSON.parse(readFileSync(join(stateDir(), `${session}.json`), 'utf8'));
    return Date.now() - s.ts < BUDGET_TTL_MS ? s.count : 0;
  } catch {
    return 0;
  }
}

/** Persist the round; false when the count cannot be owned (then no block). */
function writeRounds(session, count) {
  try {
    mkdirSync(stateDir(), { recursive: true });
    writeFileSync(join(stateDir(), `${session}.json`), JSON.stringify({ count, ts: Date.now() }));
    return true;
  } catch {
    return false;
  }
}

function log(kind, session, cuts, rounds) {
  try {
    appendFileSync(
      join(homedir(), '.claude', 'claude-autocontinue.log'),
      `${new Date().toISOString()} kind=${kind} session=${session} cuts=${cuts} rounds=${rounds}\n`,
    );
  } catch {
    // logging must never break the hook
  }
}

function main() {
  const hook = JSON.parse(readFileSync(0, 'utf8'));
  if (hook.hook_event_name !== 'Stop') return;
  const tp = hook.transcript_path;
  if (typeof tp !== 'string') return;
  const session =
    typeof hook.session_id === 'string' && SESSION_RE.test(hook.session_id) ? hook.session_id : null;

  const { cuts, interrupted } = scanTail(readTailLines(tp));
  if (cuts === 0 || interrupted) return; // normal stop or explicit user stop
  if (session && existsSync(offMarkerPath(session))) return; // per-session kill switch

  // no usable session id -> cannot own a budget -> do not block
  if (!session) return;
  const rounds = readRounds(session);
  const kind = rounds >= MAX_ROUNDS ? 'cap' : 'block';
  if (kind === 'block') {
    if (!writeRounds(session, rounds + 1)) {
      log('nostate', session, cuts, rounds);
      return;
    }
    process.stdout.write(JSON.stringify({ decision: 'block', reason: 'Continue task' }));
  }
  log(kind, session, cuts, rounds);
}

try {
  main();
} catch {
  // fail-open: no output, exit 0 — the stop proceeds
}
