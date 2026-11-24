---
name: web-frontend-patterns
description: Use when building or modifying UI in apps/web or apps/www (the Next.js apps) — feature-slice architecture, import rules, React Query vs Zustand split, data access only through the API, Sheet-sidebar create/edit forms (never dedicated pages), footer-slot CTA placement, shared DatePicker rule, component decomposition, web performance rules.
---

# Web Frontend Patterns (apps/web + apps/www)

> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo's `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.

Architecture and UI invariants for the Next.js apps (`apps/web` = the authenticated app, whatever the repo calls it, e.g. `apps/admin`; `apps/www` = the marketing site). Offline/PWA/outbox rules live in the `web-offline-pwa` skill; i18n rules in `i18n-workflow`; shared feature rules in `shared-feature-modules`; re-render, query and measurement rules in `frontend-performance`. Before any visual UI work also invoke the `frontend-design` plugin skill.

### `apps/web` and `apps/www` — Feature-Based + App Router

**Directory roles:**
- `src/app/` — Routing ONLY (page.tsx, layout.tsx, route groups). No business logic.
- `src/features/[domain]/` — All domain logic (components, hooks, API calls, types). Self-contained vertical slice.
- `src/shared/` — Cross-feature utilities, generic components, HTTP client.

**Import rules (strictly enforced):**
```
app/ → features/, shared/       (app imports from features and shared)
features/A/ ✗ features/B/       (features NEVER import from each other)
shared/ ✗ features/             (shared NEVER imports from features)
```

**State management:**
- React Query (TanStack Query v5) owns all server/async state
- Zustand (from the shared store package, e.g. `@<scope>/store`) owns client/UI state (toasts, modals, sidebar)
- React Query keys follow `[resource, modifier, filters]`: query keys include every parameter the data depends on
- No overlap between React Query and Zustand

**Data access (NON-NEGOTIABLE):**
- All database operations (`supabase.from()`, `.rpc()`, `.storage`) go through the NestJS API — never called directly from frontend code
- Allowed frontend Supabase usage: Authentication (`supabase.auth.*`) and Realtime (`supabase.channel()`, `.on()`) only
- No Server Actions (`"use server"`) for data queries or mutations — use `fetch`/TanStack Query to call NestJS REST endpoints
- Frontend Supabase client files carry the comment: `// AUTH & REALTIME ONLY — no .from(), .rpc(), .storage`
- Data fetching: TanStack Query v5 calls NestJS API endpoints — never direct Supabase DB queries
- Live updates: Supabase Realtime for receiving live updates; all writes through NestJS API

**Direct-to-storage uploads (the one Storage exception):**
- Default: every upload (photos, CSVs, signatures) goes through a multipart API route. A direct upload to a signed URL is an exception the repo's docs approve per file kind (typically large video or documents).
- Always through the repo's direct-upload hook if it has one (e.g. `useDirectUpload()`): mint a signed URL from the API → `PUT` the binary → tell the API it completed. It falls back to the multipart route on its own; callers pass that route as the fallback.
- Never `supabase.storage.*` and never a `supabase-js` upload helper in the web app. The only code that touches Storage is one bare `PUT` helper to an absolute signed URL with no auth headers (e.g. `src/shared/lib/features/put-binary.ts`).
- Red flags: a new file kind added to the direct-upload path without a documented decision; a component calling `fetch(signedUrl, …)` directly instead of the hook; a direct upload without a fallback.

`apps/www` is the same architecture but simpler — no auth, no store, no PWA/offline.

### Component size & decomposition

Keep React components focused — target **~250–300 lines** per file. This is a convention, **not lint-enforced** (no `max-lines` rule). When a component grows past it, decompose along these seams:
- **State/effects/submission logic** → a `use-*.ts` hook (no JSX) in `[feature]/hooks/` or co-located `[component]/use-*.ts`.
- **Presentation chunks** → sub-components co-located in a `[component-name]/` folder next to the orchestrator.
- **Pure transforms** → standalone `.ts` helpers; if reused across features, put them in `shared/`.
- Sub-components/hooks reused by two sibling features (e.g. two entity sidebars that share a person form) belong in the shared features package (e.g. `packages/features/src/shared/`), not duplicated.

## UI Patterns (NON-NEGOTIABLE)

### Create / Edit forms — right-side Sheet, never a dedicated page

All catalog create and edit flows use a right-side `Sheet` (from the shared UI package, e.g. `@<scope>/ui`) — **never** a dedicated `/new` or `/[id]/edit` route.

**Rules:**
- No `app/[locale]/(dashboard)/[catalog]/new/page.tsx` or `[id]/edit/page.tsx` files. Dedicated page routes for create/edit are prohibited.
- Every catalog feature exposes a `[Domain]Sidebar` component in `features/[domain]/components/[domain]-sidebar.tsx` that wraps the form in a `Sheet`.
- The parent list/table component owns the sidebar state: `sidebarOpen: boolean`, `sidebarMode: "create" | "edit"`, `selectedId: string | undefined`.
- Table keyboard navigation (e.g. a `useKeyboardNavigation` hook) receives `disabled: sidebarOpen` so arrow keys pause while the Sheet is open.
- i18n keys for Sheet titles follow `[domain].sidebar.createTitle` / `[domain].sidebar.editTitle` in the shared i18n package.
- The `[Domain]Sidebar` component prop contract: `{ open: boolean; mode: "create" | "edit"; [entityId]?: string; onClose: () => void }`.
- Fetch hooks inside the sidebar gate on `enabled: Boolean(open && mode === "edit" && entityId)` — no fetch when `open === false`.
- Sheet width is applied centrally in one shared shell component (e.g. `SidebarShell`), never per sidebar:
  - Mobile + tablet (`< lg`): full viewport (`w-full sm:max-w-none`).
  - Desktop (`lg ≥ 1024px`): `lg:w-[66vw] lg:min-w-[50vw] lg:max-w-[75vw]`.
  Sheet body keeps `overflow-y-auto`.
- `tw-animate-css` must be installed so Sheet slide/fade animations work.
- **CTA buttons (submit / cancel) go in the shell's footer slot (e.g. `footerSlot`) — never inside the body.** The footer renders as a fixed bar pinned to the bottom of the Sheet, separated by a top border, so CTAs are always visible regardless of scroll position. Never render form action buttons inline at the bottom of the body or inside the `<form>` element outside the footer slot.
  - Pass a `buildFooterSlot()` helper (or inline JSX) to the footer slot. Return `undefined` when the footer should be hidden (loading state, error state, or non-default sub-views).
  - Button layout inside the footer: primary action (`type="submit"` with `form={FORM_ID}`, `className="flex-1"`) comes first; secondary/cancel action comes second. The shell wraps them in `flex flex-col gap-2 sm:flex-row sm:gap-3` — do not add your own wrapper.
  - The `<form>` element lives in the body; the submit button in the footer slot links to it via `form={FORM_ID}` (an exported constant string per domain, e.g. `USER_FORM_ID_CREATE`).

**Red-flag checklist (reject at review):**
- A new `/new/page.tsx` or `/[id]/edit/page.tsx` added under any catalog route.
- A `[Domain]PageClient` wrapper component that navigates to a standalone form page.
- `router.push(…/new)` or `router.push(…/[id]/edit)` calls inside a catalog table/list component.
- A `[Domain]Sidebar` that does NOT pause table keyboard navigation while open.
- CTA buttons (submit / cancel) rendered inside the body instead of the footer slot.
- A `<Button type="submit">` placed directly inside the `<form>` in the body (use `form={FORM_ID}` in the footer slot instead).
- A custom footer wrapper div added inside the footer slot (the layout flex container is owned by the shell).

### Date selectors — always the shared DatePicker

Every date input uses the shared `DatePicker` component (e.g. `packages/ui/src/components/ui/date-picker.tsx`, exported from `@<scope>/ui`) — **never** a native `<input type="date">` or a one-off calendar.

**Rules:**
- Import `DatePicker` from the shared UI package and pass `value: Date | undefined` / `onChange: (Date | undefined) => void`.
- When the form state stores an ISO date string (`yyyy-MM-dd`), convert with `date-fns` `parse` / `format` at the DatePicker boundary — keep the string format on the wire (API / DTO).
- Use the `placeholder`, `minDate`, and `disabled` props for in-component UX (e.g., `minDate={new Date()}` to prevent past dates).
- Time-of-day pickers pair `DatePicker` with the shared `TimePicker`.

**Red-flag checklist (reject at review):**
- `<Input type="date" …>` or `<input type="date" …>` in any form.
- A custom popover/calendar combination that duplicates `DatePicker`'s behavior.
- A `Date` object on the wire — DTOs and API contracts use `yyyy-MM-dd` strings.

## Additional rules

- No Server Actions (`"use server"`) for data queries or mutations — Server Actions are allowed only for auth-related operations (login, logout).
- Server vs Client Component decisions: Server Components by default, `"use client"` only when hooks, event handlers, or browser APIs are needed.
- Tailwind styling: the content path configuration includes the shared UI package and the shared features package (e.g. `packages/ui` and `packages/features`).

## Performance (web)

These rules apply React performance findings to web, plus standard Next.js practice; measure on the web app before claiming a win there. Read the `frontend-performance` skill first; it holds the shared React rules (subscription isolation in large forms, no server state in Zustand, debounced query inputs, request cancellation) and the rule that a performance claim needs a measured before and after.

- **A closed `Sheet` holds nothing.** The `enabled: Boolean(open && …)` rule above is also a performance rule: no fetch, subscription or heavy form tree while closed.
- **Unbounded lists are paginated on the server.** Adding a virtualization library is a deliberate dependency decision with a measurement. Paginated tables keep the previous page with `placeholderData`.
- **Polling pauses in a hidden tab.** React Query does this by default on web; never set `refetchIntervalInBackground: true` without a reason.
- **Heavy, rarely used components load with `next/dynamic`** (charts, signature pads, QR scanners are the usual candidates). Check the route bundle before and after.
- **`"use client"` goes on the leaf that needs it**, not on a layout or page to make one child interactive.
- **Images use `next/image` with explicit size.** A raw `<img>` needs a reason (signed Storage URL, blob preview) and still needs dimensions and `loading="lazy"` below the fold. Tables show thumbnails, never the stored original.
- **Bulky or live-only queries stay out of the persisted cache** (a never-persist list of query keys, if the app persists its cache).

**Red-flag checklist (reject at review):**
- A client-side `.map()` over a list that grows with the customer's data size.
- `refetchIntervalInBackground: true` on a new polling query.
- A chart, editor or scanner imported statically into a route most users open without using it.
- `"use client"` added to a layout or page file for one interactive child.
- A new raw `<img>` with no dimensions, or a full-size photo as a table thumbnail.
