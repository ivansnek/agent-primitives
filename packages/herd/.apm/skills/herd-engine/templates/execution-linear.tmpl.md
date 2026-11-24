**Plan execution: `linear`** — pinned for this herd run. It overrides whatever the plan's
own header recommends.

Execute the plan with `superpowers:executing-plans` — **Inline Execution**, task by task, in
this one session. You implement every task yourself.

- Do NOT use `superpowers:subagent-driven-development`.
- Do NOT dispatch a subagent for any task (no `Task`/`Agent` tool call of any kind).
- Read the spec the plan cites whenever a task references it.
