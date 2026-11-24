---
name: execute-code-review
description: Use when the user asks for a thermo-nuclear code-quality review of the current branch or a git range in any repo with herd installed — the herd review stage run on demand in the user's own checkout. Judges the range against the repo's review standards and records findings; with --fix it also applies the safe behavior-preserving fixes, verifies, and commits them.
argument-hint: "[<base-branch> | <git-range>] [--fix]"
disable-model-invocation: true
---

# Execute code review

> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo's `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.

The herd review stage (`herd-engine` → `templates/review-brief.tmpl.md`), run on demand
outside a herd run. You run a thermo-nuclear code-quality review of a range and record the
findings; with `--fix` you then apply the fixes yourself, as a herd reviewer does. Same bar,
same findings format, same apply/defer rules as a herd reviewer; only the plumbing differs —
you work in the user's checkout, not a dedicated worktree.

Do not invoke `/code-review`, `/simplify`, brainstorming, writing-plans, executing-plans or
any other implementation skill. This skill plus the review standard is the whole job.

## 0. Resolve the inputs

Arguments: `$ARGUMENTS` — an optional base branch or git range, and an optional `--fix`.

| Mode | What happens |
|---|---|
| default (no `--fix`) | Review only: steps 0, 1 and 3. Nothing is edited, verified or committed. |
| `--fix` | Full herd review stage: steps 0–3, applying, verifying and committing the `apply` findings. |

Work from the repository root (`git rev-parse --show-toplevel`). Read
`.claude/herd.config.json` if it exists; every field below is optional.

| Input | Source, first match wins |
|---|---|
| Base | a branch argument → config `defaultBase` → ask the user |
| Range | a range argument (contains `..`) → `<base>...HEAD`; normalized below |
| Standard | config `reviewStandards` (relative to the repo root) → the `herd-engine` skill's `review-standards.default.md` (next to its `SKILL.md`) |
| Verify command | config `testCommand`, with every `{{BASE}}` replaced by the resolved base → the checks the repo's own docs define (`CLAUDE.md`, `package.json` scripts) |
| Findings file | `<runsDir>/code-reviews/<branch>-<short HEAD>.findings.md` (config `runsDir`, default `.claude/herd-runs`; `/` in the branch name becomes `-`) |

The findings file lives under `runsDir` because that directory is gitignored: writing it
must never dirty the tree. Run `mkdir -p <runsDir>/code-reviews` first; if `runsDir` is not
ignored (`git check-ignore -q <runsDir>/code-reviews` fails), print the findings in your
reply instead of writing them to disk.

Pin the range to SHAs once, here, and use the pinned form everywhere below. A three-dot
`A...B` means "since the merge-base" to `git diff` but "the symmetric difference" to
`git log`, which would pull the base's newer commits into the review. Normalize:

- `<base>` alone or `A...B` → `$(git merge-base A B)..$(git rev-parse B)` (`A` = base,
  `B` = `HEAD`);
- `A..B` → `$(git rev-parse A)..$(git rev-parse B)`.

Before going further:

- The range must be non-empty (`git log --oneline <range>`). An empty range: say so and stop.
- With `--fix`, the working tree must be clean
  (`git status --porcelain` empty). Dirty: stop and ask the user to commit or stash first.
  The review commit must contain review fixes only — never sweep in their work in progress.
- Read the standard **in full** before you look at the diff. Where it says "your brief",
  this skill is that brief: it owns the mechanics, the standard owns the bar.

## 1. Evaluate

1. Read the range: `git diff <range>` and `git log --oneline <range>`. Open every changed
   file whole — the diff alone hides file size, surrounding structure and the abstractions
   already available.
2. Judge the range against the standard, in its priority order. Be ambitious: look for the
   code-judo move that deletes complexity, not just the local tidy-up. High-conviction
   findings only — no cosmetic nits while a structural problem is open. A repo-invariant
   violation inside the range is a blocking finding.
3. Never revert or weaken a security fix or protection that is in the range (validation,
   auth/RBAC guards, sanitization, secret handling). A quality change that
   touches one must keep the protection it adds.
4. Write the findings file, one section per finding, most severe first:
   ```
   ## F<n> — <one-line claim>
   priority: <1-7 from the standard's priority order>
   files: <path:line, …>
   problem: <what makes the code worse, concretely>
   remedy: <the change you will make, or why it must be deferred>
   decision: apply | defer — <reason>
   ```
   If the range is genuinely clean, write `no findings` and a paragraph saying what you
   checked. That is a legitimate outcome; do not invent work.

### What to apply, what to defer

`apply` a finding only when all of these hold:

- the fix is behavior-preserving — same inputs, same outputs, same side effects;
- its blast radius is the files in the range, plus whatever a clean extraction forces
  (a new module, an updated import, a moved test);
- you can verify it with the verify command.

`defer` (record it, do not do it) when the fix would: change behavior or a public contract
outside the range; re-litigate an architecture decision the change's plan or spec mandates;
require a DB migration or schema change; add or bump a dependency; or grow into a refactor
you cannot verify. Deferred findings still belong in the findings file — that file is the
record.

Without `--fix`, every finding is still recorded with its decision — `apply` then means
"what `--fix` would apply" — but nothing is applied: skip to step 3.

## 2. Fix (only with `--fix`)

Skip this step entirely without `--fix`, or when no finding is `apply`.

1. Baseline. Before touching any file, run the verify command on the clean tree. Split it on
   `&&` and run each part on its own, so one pre-existing failure does not hide the rest.
   Record, per part, `pass` or `fail` plus the failing tests, type errors or lint errors by
   name and location. This is the baseline: failures already on the branch, not yours.
2. Apply every `apply` finding. Work finding by finding; do not blend them into one sweeping
   rewrite.
3. Verify. Run the same parts again and compare against the baseline. A regression is any
   failure absent from the baseline: a part that passed and now fails, or a new failing
   test, type error or lint error inside a part that already failed. Fix every regression;
   never chase baseline failures — they are outside the review's scope.
4. If regressions remain that you cannot fix, undo the finding that caused each one — only
   its own edits; when its files hold another applied finding's edits too, revert just its
   hunks by hand instead of `git checkout -- <path>` — change its decision to
   `defer — breaks <check>` in the findings file, and verify again. Repeat until no
   regression remains.
5. If `git status --porcelain` is non-empty, stage exactly the files your fixes touched
   (`git add <path> …`, never `git add -A`) and commit:
   `fix(review): code review fixes for <branch>`
   with one body line per finding applied (`F<n>: <one-line claim>`). Commit even when the
   baseline had failures, as long as your fixes added none.
6. Never push, merge, rebase, amend or rewrite existing commits, run db reset/migrate, or
   touch other branches.

## 3. Report

End with a short summary for the user:

```
range: <range>
head: <git rev-parse HEAD>
findings: <found> found, <applied> applied, <deferred> deferred
findings file: <path, or "inline above">
verification:
- <command part> -> baseline <pass|fail>, after fixes <pass|fail>
```

Then, one line per finding, most severe first:

1. Without `--fix` only: the `apply` findings (`F<n> — <claim>`) — what `--fix` would change.
2. The deferred findings (`F<n> — <claim> — <reason deferred>`) — what the user still has to
   decide on.
3. With `--fix` only: baseline failures, flagged as pre-existing on the branch and untouched
   by the review.

Without `--fix`, the findings line reads `<found> found, 0 applied (review only), <deferred>
deferred`, the verification lines are omitted, and the summary ends with the command that
applies the `apply` findings: `/execute-code-review <same range> --fix`. With `--fix` but no
`apply` finding, omit the verification lines too. A clean range is `0 found`, not a
failure.
