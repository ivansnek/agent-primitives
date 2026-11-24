**Plan execution: `subagent`** — pinned for this herd run. It overrides whatever the plan's
own header recommends.

Execute the plan with `superpowers:subagent-driven-development`. You are the controller: a
fresh implementer subagent per task, a task review after each, the fix loop and the final
whole-branch review exactly as the skill prescribes.

- Do NOT use `superpowers:executing-plans`, and do NOT implement or fix a task yourself in
  this session — a fix goes back through a subagent.
- Subagents work in `{{WORKTREE}}` on branch `{{BRANCH}}`, the checkout you are in. Never
  give one its own worktree or branch (no `isolation: worktree`), and never run two
  implementers at once.
- Your herd brief's rules bind every subagent, and you answer for them. Say so in each
  dispatch: stay inside `{{WORKTREE}}`; no branch switch, merge, rebase, PR or `git push`;
  no database reset or migration; no question to a human — a blocker comes back to you in
  the subagent's report, and you rule on it.
- The sentinel files are yours alone. No subagent writes one, and the `model:` line names
  your own session's model, not a subagent's.
- The phase gate is yours too. After the last task, run the gate commands yourself and
  write the sentinel from what you saw, never from a subagent's report. A red gate goes
  back through a fix dispatch.
- The skill's ledger (`progress.md` in its plan workspace) is the record of finished tasks.
  After a `/compact` or a restart, read it before dispatching anything; never re-dispatch a
  completed task.
- Read the spec the plan cites. Hand each subagent the task brief the skill generates, not
  the whole plan.
