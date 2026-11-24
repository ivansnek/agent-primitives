---
name: web-offline-pwa
description: Use when touching the apps/web service worker, offline read cache, offline-write outbox, logout/purge path, or adding any offline-capable write — Serwist build rules, cache boundaries, outbox idempotency/identity rules.
---

# Web PWA & Offline (apps/web)

> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo's `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.

For a web app that is an installable PWA with offline reads (persisted React Query cache) and opt-in offline writes (outbox). These rules are NON-NEGOTIABLE once the app is a PWA. Read the repo's own PWA/outbox docs too, if it has them.

**PWA & offline-first:**
- Service worker via **Serwist** (`@serwist/next`): source `src/app/sw.ts` → built to `public/sw.js`; manifest in `src/app/manifest.ts`. The SW is **disabled in `next dev`** — exercise it only with a production build.
- **Build requirement:** the web app's build script is `next build --webpack`. Serwist injects the SW through a webpack plugin; under Next's default Turbopack the SW is **not emitted**. Do NOT drop `--webpack`. `public/sw.js`/`swe-worker-*.js` are generated artifacts (gitignored, ESLint-excluded).
- **Offline reads** = persisted React Query cache in IndexedDB (e.g. `src/shared/lib/pwa/idb-persister.ts`, key `<app>.web.rq-cache`, 24h `maxAge`/`gcTime`, only successful queries). The cache `buster` is keyed to `${APP_VERSION}:${userId}` so every deploy AND every user change discards stale data (multi-user-device safety).
- **The NestJS API is a different origin and is intentionally NOT cached** by the SW. Never add `/api`, `/auth/v1`, `/rest/v1`, `/storage/v1` to runtime caching — offline data is owned by React Query persistence, never by caching authenticated responses.
- **Connectivity → UI** flows through one shared sync state in the store package (e.g. a `SyncSlice` in `@<scope>/store`: `idle | syncing | error | offline` + `pendingCount`): an online-status hook sets it; a connection banner renders the offline banner + back-online toast.
- **Logout/cross-user isolation:** one logout hook (e.g. `useLogout()`) is the single button-logout path — it resets forms, `queryClient.clear()`s, runs the offline purge (e.g. `purgeOfflineData()`: clears SW caches + IndexedDB query cache + outbox), then signs out. Any new offline store MUST be purged there.
- **Install UX:** `beforeinstallprompt` → install banner (Chrome/Edge); iOS Safari → manual "Add to Home Screen" instructions sheet. Wire it once at the top layout level.

**Offline-write outbox (NON-NEGOTIABLE for offline-capable writes):**
- Writes are **fail-fast offline by default**: the API client's write verbs call an online assertion (e.g. `assertOnline()`) and throw a typed offline error (e.g. `OfflineError`, code `OFFLINE_WRITE_BLOCKED`). Mutations use `networkMode: "always"` so React Query runs the mutationFn offline and the guard/outbox can act — **do not revert this**.
- Features that need offline writes **opt in** via the web outbox (e.g. `src/shared/lib/pwa/outbox/`): IndexedDB store (key `<app>.web.outbox`), a drain/sync engine, replay. Mirror the first consumer the repo already has.
- Outbox rules: (1) **idempotency** — mint a client `eventId` (UUID) per write, send it in the body; the endpoint MUST dedupe on it server-side (verify before joining the outbox). (2) **identity isolation** — stamp `userId`; drain skips/dead-letters entries for a different user. (3) **retry cap** — 5 retries then dead-letter; 4xx = terminal/dead-letter, 5xx/network = retry. (4) **optimistic update** the RQ cache on enqueue, then **invalidate to reconcile** after a successful drain. (5) drain triggers: mount, `online`, `visibilitychange→visible` (re-entrancy guarded).
- A first outbox is usually **web-local + single-tab** (one ordered array key); multi-tab needs a lock or leader election before it is safe.

**Red-flag checklist (reject at review):**
- Caching the NestJS API / auth / storage origin in `src/app/sw.ts` runtime caching.
- An offline store (cache, outbox, IndexedDB key) not cleared by the logout purge.
- A new IndexedDB key outside the app's `<app>.web.*` namespace.
- An outbox replay that omits the `userId` isolation / `eventId` idempotency.
- Dropping `--webpack` from the web build script, or reverting mutations off `networkMode: "always"`.
