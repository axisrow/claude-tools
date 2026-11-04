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

import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import { INTERRUPT_MARKER, isCut, readTailLines } from './auto-continue-common.mjs';

// raw-JSON gate: only assistant lines can matter, skip parsing everything else
const ASSISTANT_GATE = '"type":"assistant"';
// sidechain lines pass the assistant gate but are never main-chain — drop
// before parse on the raw line (compact-JSON assumption, same as the gate)
const SIDECRAFT_GATE = '"isSidechain":true';
// ponytail: calibration knobs, not config — 3 blocked rounds per 10 min;
// raise TTL only if real incidents outlive it
const MAX_ROUNDS = 3;
const BUDGET_TTL_MS = 10 * 60_000;
const MAX_WALK_LINES = 500;
const SESSION_RE = /^[\w-]+$/;

/** Newest-first scan: trailing synthetic-cut series length plus whether the
 * tail carries a user-interrupt marker (explicit stop intent wins). */
function scanTail(linesNewestFirst) {
  let cuts = 0;
  let seen = 0;
  let interrupted = false;
  for (const line of linesNewestFirst) {
    // interrupt marker suppresses only while newer than any cut seen AND only
    // on a user prompt line: an Esc that PRE-dates the cut, a tool-use deny,
    // or a tool_result/assistant text merely quoting the marker (sessions
    // editing fixtures with this literal) must not silence a real cut
    if (
      cuts === 0 &&
      line.includes(INTERRUPT_MARKER) &&
      line.includes('"type":"user"') &&
      !line.includes('"tool_result"')
    ) {
      interrupted = true;
    }
    if (++seen >= MAX_WALK_LINES) break;
    if (!line.includes(ASSISTANT_GATE)) continue;
    if (line.includes(SIDECRAFT_GATE)) continue;
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
  // no usable session id -> cannot own a budget -> do not block
  if (!session) return;
  // tmux sessions are owned by claude-auto-retry (its monitor watches the pane
  // and delivers continue itself) — one owner per session, no double-continue
  if (process.env.TMUX) return;
  // cheap kill switch first: a disabled session pays one stat, not the scan
  if (existsSync(offMarkerPath(session))) return;

  const { cuts, interrupted } = scanTail(readTailLines(tp));
  if (cuts === 0 || interrupted) return; // normal stop or explicit user stop
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
