// Shared zero-dep module for the auto-continue hook family (Stop branch
// hooks/auto-continue.mjs + StopFailure child hooks/auto-continue-sf-child.mjs).
// One owner per concept: the cut-family predicate and the transcript tail
// reader must not drift between the two branches (plain node ESM relative
// import — the turn-budget-hook.mjs ↔ turn-accounting.mjs pattern).

import { closeSync, fstatSync, openSync, readSync } from 'node:fs';

// the family suffix: covers stopped arriving / Connection lost / computer went
// to sleep; pinned by a real corpus-shaped line in tests/test_auto_continue.sh
export const INCOMPLETE_SUFFIX = 'The response above may be incomplete.';
// how Claude Code writes a user Esc-interrupt (seen in corpus transcripts)
export const INTERRUPT_MARKER = '[Request interrupted';

export function contentText(m) {
  const c = m.message?.content;
  if (typeof c === 'string') return c;
  if (!Array.isArray(c)) return '';
  // join without separator: a suffix straddling two blocks must still match
  return c.map((b) => (typeof b?.text === 'string' ? b.text : '')).join('');
}

/** Synthetic API-error line of the incomplete family (main chain only). */
export function isCut(m) {
  return (
    m.type === 'assistant' &&
    m.isSidechain !== true &&
    m.message?.model === '<synthetic>' &&
    contentText(m).includes(INCOMPLETE_SUFFIX)
  );
}

/** Last <=tailBytes bytes of the file, lines newest-first. The oldest
 * (possibly torn mid-UTF-8) fragment is dropped — but only when the window
 * actually truncated the file; a whole-file read has no torn fragment.
 * Short reads are looped. */
export function readTailLines(path, tailBytes = 1 << 20) {
  const fd = openSync(path, 'r');
  try {
    const size = fstatSync(fd).size;
    const want = Math.min(size, tailBytes);
    const buf = Buffer.alloc(want);
    let read = 0;
    while (read < want) {
      const n = readSync(fd, buf, read, want - read, size - want + read);
      if (n <= 0) break;
      read += n;
    }
    const parts = buf.toString('utf8', 0, read).split('\n');
    if (want < size) parts.shift();
    return parts.filter(Boolean).reverse();
  } finally {
    closeSync(fd);
  }
}
