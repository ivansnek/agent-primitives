---
name: frontend-performance
description: Use when a change claims or affects performance in apps/web, apps/mobile or the shared features package — React re-renders, large forms and wizards, Zustand selectors, TanStack Query refetching and retries, search inputs that drive queries, memoization, React Compiler, bundle size, or any "this is faster" claim. Holds the measurement rules and the React rules shared by web and mobile.
---

# Frontend performance (React, shared by web and mobile)

> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo's `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.

Rules from a performance audit of a React Native app on low-end Android phones, plus standard React
practice. Platform rules live in `mobile-patterns` (low-end Android, camera, photos, lists) and
`web-frontend-patterns` (Next.js). If the repo has its own performance audit or runbook, it wins.

Evidence tags: **[measured]** a before and after exist; **[symptom]** the problem was measured, no fix
tried; **[code-read]** found by reading, cost unknown; **[general]** standard practice. The numbers below come
from the source audit's mobile app on one phone, not from this repo — re-measure before relying on one here.
Nothing in the audit was measured on web.

## Performance claims need numbers

- **Before and after, or it is not a performance change.** State the metric, both values, and how many runs.
- **Release build on a real device** for mobile timings and memory. Dev builds and emulators do not count.
  Memory budgets are absolute numbers, never "works on the reference phone" (it often has more RAM than
  the users' phones).
- **Know the noise.** The audit used a 15 % floor per metric; janky-frame % is unusable below about 1 %.
  A change inside the noise is "within noise", not a result.
- **Three or more iterations** for any number that decides something. One sample has no spread.
- **Same conditions on both sides:** build type, instrumentation, device state, seeded data volume.
- **Instrumentation is not free.** Keep perf logging behind a flag that is off in production
  (e.g. `EXPO_PUBLIC_PERF_LOG`), and compare builds with the same instrumentation.
- **Say "not measured" and why.** Never estimate a number or present a code read as a measurement.
- **Protect the result with a budget** where the repo has one (e.g. `apps/mobile/perf-budgets.json` checked
  by a `pnpm perf check` / `pnpm perf check-bundle` script). A fix lowers the matching limit in the same
  pull request. A limit is never raised to make a check pass; raising one needs the compare output and a
  reason.
- **Know the delivery path.** On Expo, JS-only changes ship by OTA. Native modules, build flags and
  (usually) `app.config.ts` changes need a store build.

## A component subscribes only to what it renders — [measured]

A large registration wizard (about 1,600 lines) subscribed to a name field itself and re-rendered about
twice per typed character. Moving the subscription into a small input component took that to zero.

- The component that renders a value owns the subscription to it. A parent that only needs "is it set?"
  uses a boolean selector.
- A value a parent needs only at an event (save, snapshot, step change) is read with `getState()` when the
  event runs, not subscribed to.
- Do not build a new object or array per keystroke in a handler that feeds store state.
- Check mount time after adding selectors: the prototype's open time rose 30 %, unexplained.

## State

- **Zustand selectors return a primitive or an existing reference** [code-read]. No whole-store reads in
  components, no selector that builds a new object or array without `useShallow`. `getState()` outside React
  is fine.
- **Server state lives in TanStack Query only** [code-read]. Do not copy query data into Zustand or
  `useState`. If a copy is needed (offline fallback, a reader outside React), say why in a comment there.
- **State that changes often lives in the smallest subtree that shows it** [symptom]. Feeds re-rendered in
  full on unrelated state changes.
- **Derive, do not sync** [general]. A value computable from props or state is computed in render, not set
  from an effect.
- **Context carries slow-changing values** [general]. Split a fast-changing context, memoize its value, or
  move the fast part to a Zustand selector.

## Memoization and the React Compiler

- **If the React Compiler is off in the repo, do not enable it as a drive-by.** Measured on mobile
  [measured, mixed]: row and sheet render counts fell 20 to 60 %, frame metrics did not improve. A decision
  needs 3 or more iterations.
- **The compiler does not fix a component that subscribes to the changing value itself.** The wizard still
  re-rendered twice per character with it on.
- **Manual `memo` / `useMemo` / `useCallback` only where a measurement points** [general]. No blanket
  memoization, and no removing existing memoization "because the compiler will do it".
- With the compiler off, a new object, array or inline function passed to a memoized child defeats the memo.

## Queries and requests

- **Debounce any input that feeds a query key** [code-read]. Use the repo's debounce hook if it has one
  (e.g. `useDebouncedValue` / `useDebouncedQueryFilters` in the shared features package). Filtering an
  in-memory list needs `useMemo`, not a debounce.
- **One request per focus or mount for a key** [symptom]. Two mobile tabs sent the identical GET twice within
  3 ms. Check for two consumers of one key or a refetch next to the mount fetch.
- **Independent queries stay independent** [symptom, pass]. No query waits on another unless it needs its
  data.
- **Forward the query `signal`** [code-read]. A `queryFn` takes `{ signal }` and passes it to the transport.
  A transport that drops it lets superseded requests run to completion.
- **Do not retry 4xx** [code-read]. A bare `retry: 1` with no predicate retries client errors too; give
  `retry` a predicate that stops on 4xx.
- **Lists are paginated and keep the previous page on screen** (`placeholderData`) [general].
- **Rows carry what the row shows** [symptom]. Measure before adding a slim projection: the detail view may
  reuse the fields.
- **Do not tune `gcTime` or worry about persisted-cache hydration at modest sizes** [measured, no effect].
  A 30-minute `gcTime` and a 1,000x cache size difference both read within noise.

## Other React practice [general]

- Keys come from the record id, never the array index, for a list that can reorder, filter or paginate.
- Every subscription, timer, listener and in-flight request started in an effect stops in its cleanup.
- Typing stays synchronous; the list or chart that follows uses `useDeferredValue` or `startTransition`.
- Heavy, rarely used components load lazily (`React.lazy`, `next/dynamic`).

## Red-flag checklist (reject at review)

- "This is faster" with no number, a number from a dev build or emulator, or one run on each side.
- A raised limit in the perf budget file without the compare output.
- Perf logging not behind the perf flag.
- A form or wizard root that calls a per-field subscription hook for every field; a text input whose change
  handler sets state owned by a component of several hundred lines.
- `useEffect(() => setX(query.data), [query.data])`, or a store slice whose only writer is a query.
- A `useQuery` key that contains an input's live value.
- `key={index}` on a dynamic list; an effect that subscribes without returning a cleanup.
- The React Compiler switched on, or blanket `memo` added, without a measured before and after.
