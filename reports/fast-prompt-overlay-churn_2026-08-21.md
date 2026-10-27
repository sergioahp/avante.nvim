# Fast-prompt overlay churn — diagnosis (2026-08-21)

## Symptom

Normal-mode `<leader>ae` (no visual selection), prompt submitted. A diff overlay
rendered correctly, then was replaced by a different diff, then another — no
stable window to inspect or accept anything.

## Path actually taken

Normal-mode `<leader>ae` is NOT the selection edit. It maps to
`<Plug>(AvanteFastPrompt)` (lua/avante/init.lua:274) → `api.fast_prompt()`
(lua/avante/api.lua:211) → `Fast.submit({ ephemeral = true })`
(lua/avante/fast.lua:135). That path has no approval gate and no rejection
guard at all.

## Mechanism

1. The model drafts via `edit_file`. The tool fires Morph asynchronously and
   returns a tiny ack — not `CANCEL_TOKEN` (fast.lua:113). The tool loop then
   re-streams (llm.lua:1889), so the model keeps its turn.
2. Nothing enforces one `edit_file` per turn. The module comment admits it:
   "A model can fire several `edit_file` calls in one turn (it is told to do
   one, but does not always)" (fast.lua:12-14).
3. Each completed Morph merge calls `PendingEdits.set`, which `dismiss_all()`s
   the current overlay and repaints (lua/avante/pending_edits.lua:384-386).
   The `apply_seq` guard (fast.lua:88-92, commit 7726905) only drops
   out-of-order stale completions; sequential completions all paint.
4. Each call re-reads the buffer fresh (fast.lua:83). Buffer bytes never
   changed (the overlay is virtual-only), so successive drafts diff against
   the same base but can differ in content — matching "a different diff got
   rendered".

Net effect: overlay 1 appears → model calls `edit_file` again → overlay 2
replaces it → maybe overlay 3. The last paint survives; everything earlier
flashed by unreviewable.

## The two cases from the incident report

- "Rejected for a valid reason" — not applicable: the fast path never rejects.
  Unlike the visual-selection flow (selection.lua `scoped_region_change` guard
  + retry feedback), every Morph merge paints unconditionally.
- "Rejected just because" — nothing was rejected. What looked like
  reject-and-retry was the drafting model making extra unprompted
  `edit_file` calls, each nuking the previous overlay.

## Contributing factors

- The ack text "Your edit was submitted and is now shown to the user as a
  pending change to review" invites the model to continue its turn.
- "Put ALL of your edits in this one call" (tool description) is advisory;
  no server- or client-side enforcement.

## Root cause (confirmed against OpenRouter logs, Aug 20 06:43 PM)

The trigger was not the drafting model alone: the agentic completion nag leaked
into the float prompt.

1. llm.lua gated the nag with `opts.mode ~= "fast"`, but the float prompt
   streams with `mode = "fast_ephemeral"` (fast.lua:269), which passes that
   check. With the default `Config.mode == "agentic"`, every text-only
   completion injected
   `<system-reminder>...use attempt_completion if the job is done.</system-reminder>`
   (llm.lua) and re-streamed.
2. The fast tool set has no `attempt_completion`, so the completion check could
   never pass. Told to "use tool calls", the model used the only tool it had:
   `edit_file` with `instructions = "No further changes needed"` — the Morph
   requests in the logs. Each merge repainted the overlay (a "different diff").
3. The 3-reminder cap was defeated because `user_reminder_count` reset to 0 on
   every `tool_use` stop, and the model alternated text-complete → edit_file →
   text-complete. The loop ran ~9 cycles in ~40 s until interrupted manually.

The log signature: prompts growing monotonically (1.5k → 3.0k tok), ~9
`tool_calls` rounds interleaved with 9 Morph merges whose output pinned at ~302
tokens, plus the model's visible reasoning about a nonexistent
`attempt_completion` tool.

## Fix (llm.lua)

1. Nag only when `attempt_completion` is actually in the tool set
   (`prompt_opts.tools`), replacing the string-mode exclusion. Fast chat and
   the float prompt have no such tool, so they are never nagged; the sidebar
   agentic tool set still is.
2. Re-arm `user_reminder_count` only when the tool round included
   `attempt_completion` or `write_todos`, so ordinary tool rounds can no
   longer dodge the 3-reminder cap.

Tool-error retries are unaffected: error tool results still flow back through
the normal loop; only the post-completion nag changed.

## Original mechanism notes (pre-log diagnosis)

1. One-shot turn: after the first `edit_file` ack, make further calls in the
   same turn no-ops answering "an edit is already pending review".
2. Coalesce: while a pending overlay exists, don't dismiss+repaint mid-turn;
   queue the new merge or paint once at turn end (`on_stop`).
3. Minimum viable: keep last-wins but suppress intermediate paints until the
   stream's stop callback, so exactly one overlay per user submit.

(1) and (2) were not needed for this incident — the nag fix removes the
driver of the repeated `edit_file` calls. They remain options if a drafting
model still spams calls on its own.
