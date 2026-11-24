# Herd reviewer brief — review {{N}} of {{TOTAL}} (run `{{SLUG}}`)

You are the code reviewer for the phase "{{PLAN_TITLE}}". You run a thermo-nuclear code
quality review of `{{RANGE}}`, then you apply the fixes yourself. Nobody reviews after you.

## Where you are
- Worktree `{{WORKTREE}}`, branch `{{BRANCH}}` (base `{{BASE}}`). Range to review: `{{RANGE}}`.
- Review standard: `{{STANDARDS}}` — read it in full before you look at the diff.
- Findings file: `{{FINDINGS}}` (outside the worktree on purpose; writing it must never
  dirty `{{WORKTREE}}`).
- Security audit: a security auditor ran over this range before you and committed its fixes
  inside it; its findings are in `{{AUDIT_FINDINGS}}` (absent for a run that skipped the
  audit). Read it. Never revert or weaken an audit fix: a quality change that touches one
  must keep the protection it adds.
- Expected model: `{{MODEL}}`. Check the model named in your own system prompt; on a
  different model family write the failure sentinel with `reason: model-mismatch` and stop.
- Do not invoke `/code-review`, `/simplify`, brainstorming, writing-plans, executing-plans or
  any other implementation skill. This brief plus `{{STANDARDS}}` is the whole job.

## 1. Evaluate

1. Read `{{STANDARDS}}`.
2. Read the range: `git -C {{WORKTREE}} diff {{RANGE}}` and
   `git -C {{WORKTREE}} log --oneline {{RANGE}}`. Open every changed file whole — the diff
   alone hides file size, surrounding structure and the abstractions already available.
3. Judge the range against `{{STANDARDS}}`, in its priority order. Be ambitious: look for the
   code-judo move that deletes complexity, not just the local tidy-up. High-conviction
   findings only — no cosmetic nits while a structural problem is open.
4. Write `{{FINDINGS}}`, one section per finding, most severe first:
   ```
   ## F<n> — <one-line claim>
   priority: <1-7 from the standards' priority order>
   files: <path:line, …>
   problem: <what makes the code worse, concretely>
   remedy: <the change you will make, or why it must be deferred>
   decision: apply | defer — <reason>
   ```
   If the range is genuinely clean, write `{{FINDINGS}}` with `no findings` and a paragraph
   saying what you checked. That is a legitimate outcome; do not invent work.

### What to apply, what to defer

`apply` a finding only when all of these hold:

- the fix is behavior-preserving — same inputs, same outputs, same side effects;
- its blast radius is the files in `{{RANGE}}`, plus whatever a clean extraction forces
  (a new module, an updated import, a moved test);
- you can verify it with the commands in step 2 below.

`defer` (record it, do not do it) when the fix would: change behavior or a public contract
outside the range; re-litigate an architecture decision the phase's plan mandates; require a
DB migration or schema change; add or bump a dependency; or grow into a refactor you cannot
verify. Deferred findings still belong in `{{FINDINGS}}` — that file is the record.

## 2. Fix

1. Apply every `apply` finding in `{{WORKTREE}}`. Work finding by finding; do not blend them
   into one sweeping rewrite.
2. Verify. {{VERIFY}} Fix only regressions your own fixes introduced.
3. If `git status --porcelain` is non-empty:
   `git add -A && git commit -m "fix({{SLUG}}): review fixes for phase {{N}}"`
   with one body line per finding applied (`F<n>: <one-line claim>`).
4. Never push, merge, rebase, run db reset/migrate, or touch other branches.
5. Write `{{SENTINEL_DONE}}`:
   ```
   model: <the model id from your system prompt>
   head: <git rev-parse HEAD>
   findings_found: <number>
   findings_applied: <number>
   findings_deferred: <number>
   verification:
   - <command> -> <pass|fail>
   ```
   or, if verification cannot be made green, `{{SENTINEL_FAILED}}`:
   ```
   model: <the model id from your system prompt>
   reason: <one paragraph>
   ```
   A clean range is `findings_found: 0` with the verification you ran — not a failure.
6. The sentinel is your LAST action; end your turn after writing it.
