---
name: backend-patterns
description: Use when working in apps/api or supabase/ — NestJS modular-monolith structure (controller → service → repository), RBAC guards, JWT claims hook, module import rules, migration rules, and backend integration invariants (provider ports for mail and other vendors, AI extraction prefill, fail-open safety nets, data-retention duties, direct media paths).
---

# Backend Patterns (apps/api + supabase)

> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo's `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.

Architecture and integration invariants for the NestJS backend. For the endpoint-authoring recipe (`@ZodRoute` + pipes) use the `add-api-endpoint` skill.

### `apps/api` — Modular Monolith + Repository Pattern

**Request flow:** `HTTP Request → Controller → Service → Repository → Supabase/Postgres`

**Directory roles:**
- `src/common/` — Guards (e.g. JwtAuth, Roles), decorators (e.g. `@CurrentUser`, `@Roles`), interceptors, exception filters, Zod validation pipe
- `src/modules/[domain]/` — One NestJS module per business domain
- `src/infrastructure/` — Database client singleton, storage service, queues, and one provider abstraction per external vendor (mail, AI, media, …)

**Simple module:** `module + controller + service + repository + dto/`

**Complex module** (several workflows, background sync, cross-entity rules): adds a `use-cases/` directory and a repository interface (domain port).

**RBAC:** follow the repo's role hierarchy. Enforced at NestJS guards (API) + Postgres RLS (DB) — always both: the Supabase anon key ships in every client bundle for auth, so every table is reachable through Supabase's REST API and needs RLS policies even though the frontend never queries it. Never make an authorization decision in a controller body or on the client.

**JWT claims:** when the repo uses a Supabase `custom_access_token_hook` (or an equivalent) to put `role` and other claims into `app_metadata`, resolve display values once at login rather than per request. The hook must be enabled per remote project in the auth config — `db push` deploys the function, not its enablement.

**Module import rules:**
- Cross-module communication goes through NestJS DI (exported services), never direct file imports
- common/ is imported by all modules, never the reverse
- infrastructure/ is imported by modules that need it, never the reverse

## Backend Integrations

### Vendor providers — one port, swappable adapters

Every external vendor (mail, AI, biometrics, payments, media) sits behind a provider port in `apps/api/src/infrastructure/<capability>/`, with one adapter per vendor plus a `noop` adapter for dev and tests. A factory picks the adapter at boot from env. Callers use a domain service (e.g. `EmailService`: template rendering, dev no-op, structured logging) and never touch a provider directly.
- Secrets and model/endpoint names come from env only (documented in `apps/api/.env.example`), never from code or the client.
- Timeouts, retries (with a total time budget) and caching live in the adapter, not in callers.
- One provider is active per process (chosen at boot, not swapped at runtime).
- Never call a vendor from a controller.
- Email templates live in a shared package (e.g. `@<scope>/emails`) and are locale-aware.

### AI extraction — prefill forms from an image

When an AI model pre-fills a form from a captured or uploaded image:
- **Skip when complete:** do not call the API when every patchable field is already filled. It saves quota and latency and respects manual input.
- **Explicit retake is the exception:** when the user retakes a photo to re-read it, call the API again and **clear** the fields the result owns (plus fields that depend on them) before applying it, so a value never outlives the photo it came from.
- **Prefill policy:** patch a field only when its confidence ≥ the configured threshold; never patch `null`; only fill empty fields unless the flow cleared them on purpose.
- **Failure is visible, never silent:** a failed request, an unusable result or a failed config request renders an inline error telling the user to fill the fields manually. A feature that is switched off stays silent — that is opt-out, not failure.
- Rate-limit per caller (NestJS throttler).

### Optional safety nets — fail open, honor retention

For a secondary check that guards a primary flow (e.g. a biometric or fraud match run after the main check finds nothing):
- **Fail open everywhere:** an error, timeout or 429 from the check never blocks the primary flow.
- Run exactly one probe per attempt, and reuse the existing alert UI for a hit.
- Enroll asynchronously (fire-and-forget plus a scheduled reconciler via `@nestjs/schedule`).
- **Retention duty outlives the kill switch (NON-NEGOTIABLE):** disabling the feature tombstones every enrolled record, and the reconciler's sweep deletes the vendor-side copies even while the feature flag is off. Re-enabling does not restore them (no backfill).
- Mapping tables that point at vendor-side records use FKs `ON DELETE SET NULL`, never `CASCADE`: the tombstone is what lets the sweep delete the vendor copy.
- With several replicas, pin scheduled jobs to one instance (e.g. a `*_CRON_ENABLED=false` env on the others).
- Sensitive opt-ins are toggled only by the highest role; the API rejects the field for everyone else.

### Media streams — the API is never in the media path

For live media (cameras, streaming gateways), the API stores configuration and issues short-lived stream credentials; the client connects directly to the media server (e.g. over WebRTC). Never proxy media through NestJS. The repo's own runbook, if any, covers deployment.

## Pre-work checklist

Before implementing backend work, confirm:
- A feature spec + plan exist for the target work (superpowers or speckit artifact).
- The target module follows `module + controller + service + repository + dto/`; complex domains add `use-cases/` and a repository interface.
- Every handler is guarded in the canonical guard layer.
- Migrations are authored with the repo's migration command (e.g. `pnpm db:new`) and NEVER applied by Claude (the user applies them). Their version timestamp must never be in the future: a future-dated version, once applied, blocks every later real-dated migration (Supabase refuses to insert a version before the last applied one). Use the real current timestamp, and do not backdate or pass `--include-all` to get around it.
