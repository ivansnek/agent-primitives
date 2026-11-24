---
name: i18n-workflow
description: Use when adding, renaming, or referencing any user-facing string or i18n key in web or mobile — every-locale parity requirement, key-before-reference order, namespace double-prefix gotcha, check:i18n behavior, the marketing-site (apps/www) exception, and mobile react-i18next interpolation.
---

# i18n Workflow (shared i18n package)

> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo's `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.

User-facing strings come from one catalog per locale in the shared i18n package (e.g. `packages/i18n/src/messages/<locale>.json`, published as `@<scope>/i18n`). Parity is enforced by the repo's parity check (e.g. `pnpm check:i18n`, usually wired into a pre-push hook and, where configured, a hook that runs it after any catalog edit).

## Keys must exist in EVERY locale before reference

User-facing strings for the authenticated web app, the mobile app, and shared features come from the shared i18n package. Adding and referencing a translation key follows a strict order, enforced by the parity check (e.g. `pnpm check:i18n` on `git push` via `.husky/pre-push`, backed by a full-catalog parity test in the i18n package's own tests).

**Rules:**
- Add every key to **every** locale catalog in the same change — never one locale only. The catalogs stay at full parity (every dot-path present in all of them).
- A translation key MUST exist in the catalogs **before** any feature references it with `t("…")`. Do not reference a key you have not yet added.
- Run the parity check locally before pushing to catch missing counterparts and dangling references early. Empty-string values are worth reporting as warnings.
- A reference scan of this kind is **best-effort with zero false positives**: it verifies literal `t("key")` calls whose namespace is also a literal. Dynamic keys (`` t(`status.${x}`) ``) and variable-namespace bindings (`useTranslations(ns)`) are skipped — when you add those, you are responsible for ensuring every resolvable key exists in every locale.
- **A static marketing app (e.g. `apps/www`) may be the exception**, if the repo says so: it ships its OWN catalog (e.g. `apps/www/src/messages/<locale>.json`), is NOT part of the shared i18n package, and is excluded from the parity check. Keep its locale files at parity by hand.

**Red-flag checklist (reject at review):**
- A key added to one locale catalog but not the others.
- A `t("…")` reference to a key that does not exist in every catalog.
- A namespace-prefixed key passed to a `t` already scoped to that namespace — e.g. `const t = useTranslations("orders"); t("orders.toasts.deleted")` resolves to `orders.orders.toasts.deleted` (use `t("toasts.deleted")`).
- Hardcoded user-facing strings bypassing the shared i18n package.
- A new namespace introduced in one locale only.

## Mobile interpolation

When the shared catalogs use next-intl single-brace placeholders (`{var}`), the mobile app's react-i18next must be configured with `interpolation: { prefix: "{", suffix: "}" }` to match — do NOT convert catalog strings to double-brace `{{var}}`, and do not remove that interpolation config from the mobile i18n setup.
