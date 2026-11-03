#!/usr/bin/env node
// Stop-hook auto-continue: when a stream cut ends the run with the
// "API Error: ... The response above may be incomplete." family as the newest
// main-chain assistant line, block the stop — Claude Code feeds the block
// reason ("Continue task") back as an instruction and keeps working.
//
// State lives in the transcript itself: the trailing series of cut lines is
// the retry counter (same pattern as the turn-budget stop-crane's deny
// markers), so no counter files. Cap: MAX_CONSECUTIVE_CUTS cuts in a row,
// then let the session stand — a hard-down provider must not loop forever.
//
// Carrier: synthetic assistant lines (message.model === '<synthetic>'), the
// canonical API-error carrier (cf. claude-devtools src/cli/toolStats.ts).
// Real assistant lines quoting the suffix in prose never match (model check).
// Fail-open: any error exits 0 silently — a broken hook must not wedge stops.
//
// Reference impl: claude-devtools/scripts/turn-budget-hook.mjs (linesBackward,
// fail-open main, transcript-as-state). Registry entry: id "auto-continue".

import { appendFileSync, closeSync, existsSync, fstatSync, openSync, readFileSync, readSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const INCOMPLETE_SUFFIX = 'The response above may be incomplete.';
// ponytail: calibration knob, not config — 3 retries, then the session stands;
// raise only if cuts routinely outlive 3 rounds
const MAX_CONSECUTIVE_CUTS = 3;
// walk bound: a stop-time tail scan never needs more than this; without it a
// transcript with no breakable line would read the whole file
const MAX_WALK_LINES = 500;
const LOG_PATH = join(homedir(), '.claude', 'claude-autocontinue.log');
const CHUNK = 1 << 20; // backwards-read window

/** Backwards line generator: yields lines newest-first. */
function* linesBackward(fd, size) {
  const buf = Buffer.alloc(CHUNK);
  let remaining = size;
  let carry = '';
  while (remaining > 0) {
    const len = Math.min(CHUNK, remaining);
    remaining -= len;
    readSync(fd, buf, 0, len, remaining);
    const text = buf.toString('utf8', 0, len) + carry;
    const parts = text.split('\n');
    carry = parts.shift() ?? '';
    for (let i = parts.length - 1; i >= 0; i--) {
      if (parts[i]) yield parts[i];
    }
  }
  if (carry) yield carry;
}

function contentText(m) {
  const c = m.message?.content;
  if (!Array.isArray(c)) return '';
  return c.map((b) => (typeof b?.text === 'string' ? b.text : '')).join('\n');
}

function isMainChain(m) {
  return m.type === 'assistant' && m.isSidechain !== true;
}

/** Synthetic API-error line of the incomplete family. */
function isIncompleteCut(m) {
  if (!isMainChain(m)) return false;
  if (m.message?.model !== '<synthetic>' && m.isApiErrorMessage !== true) return false;
  return contentText(m).includes(INCOMPLETE_SUFFIX);
}

/**
 * Length of the trailing series of incomplete cuts, scanning newest-first.
 * Any other main-chain assistant line (real response or a different synthetic
 * error) ends the series; bookkeeping lines (system/turn_duration,
 * cost-state, ...) are skipped. 0 = normal stop.
 */
export function trailingCuts(linesNewestFirst) {
  let cuts = 0;
  let seen = 0;
  for (const line of linesNewestFirst) {
    let m;
    try {
      m = JSON.parse(line);
    } catch {
      continue;
    }
    if (isMainChain(m)) {
      if (!isIncompleteCut(m)) break;
      cuts++;
    }
    if (++seen >= MAX_WALK_LINES) break;
  }
  return cuts;
}

function main() {
  const hook = JSON.parse(readFileSync(0, 'utf8'));
  const tp = hook.transcript_path;
  if (typeof tp !== 'string' || !existsSync(tp)) return;
  const fd = openSync(tp, 'r');
  let cuts;
  try {
    cuts = trailingCuts(linesBackward(fd, fstatSync(fd).size));
  } finally {
    closeSync(fd);
  }
  if (cuts === 0) return; // normal stop — silent allow
  const kind = cuts >= MAX_CONSECUTIVE_CUTS ? 'cap' : 'block';
  if (kind === 'block') {
    process.stdout.write(JSON.stringify({ decision: 'block', reason: 'Continue task' }));
  }
  try {
    const session = String(hook.session_id ?? '?').replace(/[^\w-]/g, '');
    appendFileSync(LOG_PATH, `${new Date().toISOString()} kind=${kind} session=${session} cuts=${cuts}\n`);
  } catch {
    // logging must never break the hook
  }
}

try {
  main();
} catch {
  // fail-open: no output, exit 0 — the stop proceeds
}
