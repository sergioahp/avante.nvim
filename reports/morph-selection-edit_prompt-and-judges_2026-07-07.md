# Morph selection-edit: guard fix, prompt sharpening, and a judge-validation experiment

Date: 2026-07-07
Repo: avante.nvim (sergioahp fork, branch main)
Scope: the visual-selection fast-apply path (editing_morph -> draft model -> Morph -> client-side guard)

This session started from a real failure (selection edits getting rejected) and grew into
three shipped fixes plus two experiments: an A/B of the draft prompt, and a validation of
LLM judges (Haiku via subagent, a structured-output model on OpenRouter) against ground
truth and a cheap regex heuristic.

--------------------------------------------------------------------------------

## 1. Root causes found and fixed (all pushed to main)

### 1a. Trailing whitespace on the last line rejected clean merges  (commit 759eb3a)
The confinement guard `morph.scoped_region_change` compared every line OUTSIDE the selection
byte-for-byte, tolerating only trailing blank LINES at EOF. But Morph, during its whole-file
reflow, also strips trailing whitespace from a content line it otherwise leaves alone. When
the buffer's last line carried a stray trailing space, Morph removed it, the guard saw a
byte difference outside the selection, and discarded the whole edit -- the "Morph changed
line N, after the selected region" reject the user hit. The Morph web dashboard hid this
because its diff viewer normalizes trailing whitespace visually.

Fix: compare the unchanged context with trailing whitespace ignored (`same_outside`). We
splice back only Morph's region and keep the buffer's own copy of every other line, so a
trailing-whitespace-only diff there is discarded anyway. Indentation / real content changes
still reject. + 3 regression tests. Verified in isolation: only an actual last-line change
(content, or added/removed non-trailing bytes) rejects; faithful expansion, trailing-blank
normalization, and reformatting INSIDE the selection all pass.

### 1b. gpt-5.4-mini 400: reasoning_effort vs reasoning.effort conflict  (commit 1d3be85)
"Error drafting the edit" on the selection path with gpt-5.4-mini. The `gpt_5_4_mini`
provider inherits `extra_request_body.reasoning_effort = "medium"` from the `openai` base
(via `__inherited_from`) but also declares `reasoning = { effort = "minimal" }`. The provider
merge is a deep extend, so BOTH survived into the request body. On the OpenRouter chat path
`set_allowed_params` never reconciled them, so the request shipped both and OpenRouter
returned 400: "reasoning_effort and reasoning.effort are both provided with conflicting
values". (Only surfaces on the reasoning-model + OpenRouter-chat path, which the sidebar
"chat" mode sidesteps -- hence "first time on non-chat mini".)

Fix: when both forms are present, drop the scalar `reasoning_effort` and keep the explicit
nested `reasoning` (the more specific, user-declared intent). Scalar-only configs
(openai-direct) untouched; non-reasoning models still clear both. + 3 regression tests.

### 1c. Draft prompt sharpening  (commit ca229b2)
The `editing_morph.avanterules` rules that matter (use landmarks; not a patch) were buried
below two dense paragraphs, and the `code_edit` arg framed markers passively. Rewrote so the
code_edit description leads with: "not a patch (no +/-)" coupled to "still leave a landmark
for skipped code" (coupled to avoid the nano dump-backfire), and an imperative "almost
always BEGIN and END with a landmark". Added a mid-file block-expansion example. See
experiment 2 for measured effect.

--------------------------------------------------------------------------------

## 2. Experiment A -- prompt A/B (old vs new editing_morph)

Method: faithful to the real path. For each (prompt, model, case, trial): draft via the
edit_file tool call, Morph applies to the WHOLE file, `scoped_region_change` confines. Test
files are invented and neutral (a py cache, a lua FSM, a ts event bus, a py decoy-flags file
with a commented-out lookalike block and a long tail). Draft-only metrics (landmark / +- /
dump usage) come from the draft text; they do not need Morph, so they survived the Morph
rate-limiting. Models and reasoning effort match the user's real config (gpt-oss-120b at
medium via cerebras/groq; mini at minimal via azure/openai). 32 drafts per cell.

Landmark usage (draft begins AND ends with a `... existing code ...` landmark):

| model         | old prompt | new prompt |
|---------------|-----------:|-----------:|
| gpt-oss-120b  |        31% |        91% |
| gpt-5.4-mini  |         0% |        34% |

- +/- diff syntax: 0% under both prompts, both models.
- whole-file dump: 0% under both prompts, both models.

Reading: the new prompt roughly triples gpt-oss's both-sided landmark rate (31 -> 91) and
takes mini from never (0) to a third (34). No regression, no new diff/dump behavior.

Important caveat on ACCEPT: on these cleanly-anchored cases Morph accepts the edit whether
or not the draft has landmarks (43/45 accept in experiment C, the two rejects were
hand-crafted). A unique anchor like `STRATEGIES = {` is enough for Morph to place a bare
block. Landmarks earn their keep on the HARD cases -- ambiguous/duplicate anchors, long
tails Morph reflows, the trailing-space class -- which is exactly the user's original
failure. So the prompt change is best read as cheap insurance (more anchoring on the cases
that actually reject), not as a headline accept-rate lift on easy edits.

--------------------------------------------------------------------------------

## 3. Experiment B -- backfire probe (new vs aggressive negative examples)

Question (from the notes): a hard "no diff" rule once backfired on nano (it dumped the whole
region with whitespace drift). Is mini/nano robust enough now to push negative examples
harder? The aggressive variant appends explicit WRONG examples (a +/- diff, a whole-block
echo) plus a RIGHT landmark example. Split nano vs mini vs gpt-oss. NOTE: small sample
(N=1 x 4 cases = 4 drafts per cell) -- directional only.

| model         | new: both-land / +- / dump | aggr: both-land / +- / dump |
|---------------|---------------------------:|----------------------------:|
| gpt-5.4-nano  |            0% / 0% / 0%     |             0% / 0% / 0%     |
| gpt-5.4-mini  |           25% / 0% / 0%     |            50% / 0% / 0%     |
| gpt-oss-120b  |          100% / 0% / 0%     |           100% / 0% / 0%     |

Reading: no backfire observed -- zero dumps and zero +/- under the aggressive prompt for any
model, including nano. The aggressive examples nudged mini's landmark rate up (25 -> 50) and
did nothing to nano (it just never emits landmarks on these cases). So on this evidence we
CAN push negative examples harder without triggering the dump/diff backfire the notes warned
about. Caveat: these cases are "easy" (unique anchors, short) where models don't dump anyway;
the original nano backfire was on messier inputs. Before trusting "backfire is gone", rerun
at higher N on the decoy + long-tail cases, and ideally an input that historically made nano
dump.

--------------------------------------------------------------------------------

## 4. Experiment C -- judge validation (the main new thing)

Goal: compare three "readers" of a draft against ground truth.
- ground truth: Morph (via OpenRouter, morph-v3-large) applies the draft, guard confines ->
  ACCEPT / reject. Routing Morph through OpenRouter dodged the direct-API free-tier 429.
- heuristic: my regex flags (landmark present, +/- prefixes, >=20 lines dump).
- gemini: google/gemini-2.5-flash on OpenRouter with a json_schema response_format
  (structured outputs), rating comfort 1-5 + the three boolean flags.
- haiku: Claude Haiku via 3 parallel subagents (runs on the Claude subscription, ~free),
  same rubric, returning JSON.

Corpus: 40 real drafts (stratified from experiments A/B) + 5 hand-crafted adversarial drafts
with known-bad ground truth (a +/- diff, a whole-file dump with an interior blank-line
collapse, and an edit that also bumps a variable OUTSIDE the selection). "Comfort" = how
confident the reader is the draft merges cleanly touching ONLY the selected region.

### Ground truth
43/45 accept. The 2 rejects are both adversarial and for the right reason:
- whole-dump-drift: reject, "line 34 after" (the collapsed interior blank line).
- stray-outside: reject, "line 4 before" (the bumped MAX_ENTRIES).
Notably, the +/- diff draft was ACCEPTED by Morph -- Morph tolerates diff syntax; +/- is a
guard/aesthetics concern, not fatal to the apply itself.

### Mechanical flag detection vs the objective regex heuristic (match / 45)

| flag        | gemini | haiku |
|-------------|-------:|------:|
| landmarks   |  45/45 |  45/45 |
| diff +/-    |  45/45 |  45/45 |
| whole_dump  |  29/45 |  45/45 |

Both LLMs match the regex perfectly on landmark and diff detection -- i.e. for those objective
properties the cheap regex is enough, an LLM judge adds nothing. On whole_dump, Haiku is
perfect; Gemini over-flags (16 false positives -- it calls minimal bare-block edits "whole
dump"). Gemini's structured booleans are noisier than Haiku's here.

### Comfort (mean, 1-5)

| slice                         | gemini | haiku |
|-------------------------------|-------:|------:|
| landmarked drafts             |   4.86 |  4.86 |
| bare (no-landmark) real drafts|   4.19 |  3.57 |
| Morph-ACCEPT drafts           |   4.51 |  4.19 |
| Morph-REJECT drafts           |   1.50 |  1.50 |

Both judges cleanly separate the extremes: clean-landmark ~= 5, actually-rejected ~= 1.5.
Both slightly over-penalize bare-but-valid drafts (which Morph accepts) -- Haiku more so
(3.57 vs 4.19), i.e. Haiku is stricter about missing landmarks. In the middle they are noisy
and disagree with each other by >=2 on 7/45 drafts (e.g. a bare nano draft: gemini 1 vs haiku
4, and the reverse elsewhere). So "comfort" is trustworthy as a coarse good/bad signal, not
as a fine-grained score, and the two judges are not interchangeable in the middle band.

### Adversarial set (ground truth known)

| id | label            | accept | gemini_c | haiku_c | correctly flagged |
|----|------------------|:------:|:--------:|:-------:|-------------------|
| 40 | clean-landmarks  |  True  |    5     |    5    | both              |
| 41 | bare-block       |  True  |    5     |    4    | (no flag needed)  |
| 42 | diff-pm          |  True  |    1     |    1    | both flagged +-   |
| 43 | whole-dump-drift |  False |    1     |    1    | both flagged dump |
| 44 | stray-outside    |  False |    2     |    2    | both low comfort  |

On the clear failures both judges agree with each other, with the heuristic, and with Morph.
Haiku's free-text note on id 44 pinpointed the cause: "Modifies MAX_ENTRIES outside selected
region" -- it localized the stray edit, which the boolean flags and the regex do not.

### Judge takeaways
1. For objective mechanical checks (has-landmark, is-diff), the regex heuristic already
   matches both LLMs 45/45 -- do not spend an LLM call on those.
2. Gemini structured-output is a competent judge but its whole_dump boolean is unreliable
   (over-flags). If used, trust its comfort score more than its dump flag.
3. Haiku (via subagent, ~free on the subscription) matched or beat Gemini everywhere here,
   including perfect dump detection and useful localizing notes, and returned clean JSON on
   the first try. For this task Haiku-subagent is the better judge and the cheaper one.
4. All judges' "comfort" separates clean from broken reliably but is noisy on the valid-but-
   bare middle. Do not treat a 3-vs-4 as meaningful; treat <=2 as "likely rejects".
5. Morph is the only true oracle for accept, and it is very tolerant (bare blocks, +/- diffs
   all applied). Judges/heuristics predict the guard only at the extremes.

--------------------------------------------------------------------------------

## 5. Overall conclusions

- The user's actual reject was the trailing-space guard gap (1a), now fixed; the missing
  landmarks made it worse but were not the trigger. mini was additionally blocked by the
  reasoning-conflict 400 (1b), now fixed.
- The sharpened prompt measurably increases landmark usage (gpt-oss 31->91, mini 0->34) with
  no diff/dump regression. On easy edits this does not change accept (Morph is tolerant); it
  is insurance for the hard/ambiguous edits that actually reject.
- Pushing negative examples harder did not backfire on mini or nano in this sample (0 dumps,
  0 diffs), but the sample is small and easy; confirm on messier inputs before relying on it.
- For grading these drafts: the regex heuristic is sufficient for the mechanical flags; add a
  Haiku-subagent pass when you want a comfort score or a localized "what's wrong" note. The
  OpenRouter structured-output judge works but is noisier and not free.

## 6. Limitations
- Cases are neutral synthetics; only one (py-decoy-flags) mimics the real ambiguous shape,
  and none reproduce the exact 146-line trailing-space file.
- Backfire cells are N=1 x 4 = 4 drafts each -- directional only.
- Morph free-tier rate limits (429 on the direct API) capped the live accept sampling; draft
  metrics and the judge corpus (Morph via OpenRouter) are unaffected.
- Judges saw the instruction + selected region + draft, not the full file, so "stray outside"
  detection relied on reasoning about the region boundary, not on seeing the whole file.

## 7. Reproduction
All harness + data are under `tmp/` (gitignored):
- `tmp/prompt_ab_landmarks.py`   -- experiment A (old vs new), draft metrics + Morph accept.
- `tmp/prompt_ab_backfire.py`    -- experiment B (new vs aggressive), + dump metric.
- `tmp/ab_draft_metrics.py`      -- draft-only aggregation over all saved drafts.
- `tmp/judge_drafts.py`          -- experiment C: Morph(OpenRouter) accept + Gemini structured
                                    judge + writes corpus.json / haiku_input.json.
- `tmp/judge_analyze.py`         -- cross-judge analysis from corpus.json + haiku_verdicts.json.
- `tmp/judge-drafts_2026-07-07_11-51-51/` -- corpus.json, haiku_verdicts.json, analysis_rows.json.
Keys sourced from ~/.secrets (OPENROUTER_API_KEY, MORPH_API_KEY). Haiku ran as 3 subagents.
