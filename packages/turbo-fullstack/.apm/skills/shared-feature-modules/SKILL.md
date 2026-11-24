---
name: shared-feature-modules
description: Use when adding a feature that exists (or may exist) in BOTH web and mobile (apps/web and apps/mobile), or when deciding where any new feature lives — shared features package (@<scope>/features) authoring rules, adapter/extension points, host-app wiring, and the shared-vs-single-app decision tree.
---

# Cross-App Shared Feature Modules

> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo's `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.

Features present in more than one host app (web app and mobile app) are authored ONCE in a shared features package (e.g. `packages/features`, `@<scope>/features`). Per-app duplication is prohibited. If the repo has no such package yet, propose creating one to the user before duplicating a feature across apps — do not create it as a side effect of feature work.

### Shared feature modules (NON-NEGOTIABLE for shared features)

Features that exist in more than one host app (e.g. a list + detail + create flow both the web and mobile apps show) are authored **once** in the shared workspace package and consumed by each app.

**Policy — shared core with platform extensions:**
- The shared module owns the common body: layout, forms, tables, sidebars, data-fetching hooks, user-facing strings, validation wiring.
- Each app owns: routing, shell/layout, auth bootstrap, Zustand provider wiring, and any **deliberate** platform-specific behavior injected through documented extension points (props, slots, adapter hooks).
- Deliberate divergence is expressed via extension points, never by forking the feature.
- Typical deliberate divergences:
  - **Web-only**: draft recovery across browser reloads (e.g. a `useFormPersistence` hook).
  - **Web-only**: admin-only actions the mobile UI does not offer.
  - **Host-specific transports**: the shared mutation hook accepts a transport; each host wires its own (web: online HTTP, plus the offline outbox where the app has one; mobile: the native API client and native binary upload).

**Rules for the shared feature module:**
- No `"use client";` directive. No `next/*` imports. No host-specific globals or Node-only APIs.
- i18n strings are obtained through an abstraction injected by the host app (web wires `next-intl`, mobile wires `react-i18next`). Message catalogs live in the shared i18n package, not per app.
- Data fetching goes through an injected transport. Shared hooks call the NestJS API; they do NOT hardcode `fetch` + URL assumptions that break a host's transport.
- If the transport port has a binary-upload method (e.g. `putBinary`), every host provides it; it serves only the approved direct-to-storage uploads, which keep their multipart fallback; every other upload stays on the multipart API route.
- Zod schemas live in the shared package (e.g. `@<scope>/shared`) and are reused verbatim.
- Role-gated UI is injectable by the host app.
- The shared module does NOT own routing, layout shell, auth bootstrap, or store provider wiring.
- Shared hooks and components run on low-end Android as well as desktop browsers, so the `frontend-performance` rules apply to them first: a `queryFn` takes `{ signal }` and passes it to the transport; an input that feeds a query key goes through a debounce hook (the repo's, if it has one, e.g. `useDebouncedValue` / `useDebouncedQueryFilters`); a large form or wizard root does not subscribe to per-field state (the input component does).

**Rules for each host app:**
- Import the shared feature module; do not reimplement its components or hooks in `apps/[web|mobile]/src/features/[same-domain]/`.
- Wire the transport adapter, the i18n adapter, and any platform-specific extensions at the app level.
- Keep app-local `src/features/[domain]/` for features that are intentionally single-app (e.g. web-only user administration). Do not force unification where none is intended.

**Red-flag checklist (reject at review):**
- New `.tsx` / `.ts` component or hook added under both `apps/web/src/features/X/` and `apps/mobile/src/features/X/` for a feature that already lives in the shared features package.
- Shared feature module importing `next/*`, `"use client";`, or a concrete i18n library.
- Locale strings for a shared feature duplicated in both apps' message files instead of the shared i18n package.
- Shared mutation hook assuming online HTTP and bypassing the injected transport.
- A shared query hook whose key contains an input's live (undebounced) value, or a shared form root that subscribes to every field.

## Adding New Features

**First decide: is this a shared feature (web AND mobile) or single-app?**
- Shared → author once in the shared features package (see above). Do NOT create parallel directories under `apps/web/src/features/` and `apps/mobile/src/features/`.
- Single-app (e.g. web-only user administration) → use the per-app path below.

1. **Shared frontend (web + mobile):** Author UI, interaction logic, and TanStack Query hooks in the shared features package. Each host app imports from it and wires the transport adapter, the i18n adapter (web: `next-intl`; mobile: `react-i18next`), and any platform-specific extensions. Wire into each app's routing (`src/app/` on web, `app/` on mobile).
2. **Single-app frontend (web only, or mobile only):** Create `src/features/[domain]/` in the target app with components, hooks, types. Data fetching via TanStack Query against NestJS API endpoints — no direct Supabase DB access. Wire into `src/app/` (web) or `app/` (mobile).
3. **Backend (api):** Create `src/modules/[domain]/` with module, controller, service, repository, dto/. Register in AppModule. Every controller handler uses `@ZodRoute()` + `ZodValidationPipe` — see the `add-api-endpoint` skill. Run the repo's OpenAPI gate (e.g. `pnpm --filter @<scope>/api openapi:gate`) before pushing, if it has one.
4. **Shared types/validators:** Add to `packages/shared/src/types/` or `packages/shared/src/validators/`.
5. **Shared i18n messages:** Add to the shared i18n package's message catalogs (single source of truth for strings used in both apps).
6. **UI primitives:** `cd packages/ui && pnpx shadcn@latest add [component]`, then re-export from `src/index.ts`.
7. **Database migrations:** create with the repo's migration command (e.g. `pnpm db:new [name]`), write SQL, then the user applies it; regenerate DB types (e.g. `pnpm db:types`). Claude never applies migrations.
