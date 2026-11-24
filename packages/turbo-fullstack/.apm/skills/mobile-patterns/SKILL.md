---
name: mobile-patterns
description: Use when building or modifying apps/mobile (Expo / React Native) screens, forms, feeds, uploads, cameras/scanners, or photo capture — KeyboardAwareScrollView requirement, focus-refetch rule for list feeds, Expo fetch FormData file parts, direct binary uploads, NativeWind dynamic-color and dark-theme gotchas, group-qualified Expo Router hrefs, and low-end Android performance rules (mounted tabs, camera sessions, photo memory, temp files, lists, polling, device perf checks).
---

# Mobile Patterns (apps/mobile)

> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo's `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.

Expo (React Native) app, often with role-branched route groups (e.g. `(admin)` and `(member)`). These rules exist because React Native and Expo Router break web assumptions silently.

## Keyboard must never cover a focused input

React Native does **not** auto-scroll a focused `TextInput` above the on-screen keyboard, and a bare `ScrollView`/`View` does not fix it — the field stays hidden under the keyboard. Every mobile view that contains a text input MUST keep the focused field visible. Use `react-native-keyboard-controller`, with `KeyboardProvider` mounted once at the root layout (`apps/mobile/app/_layout.tsx`).

**Rules:**
- Any screen, form, or component that contains a `TextInput` (directly, or via shared `Input` / `Textarea` / search components) is wrapped in the repo's shared `KeyboardAwareScrollView` wrapper (e.g. `apps/mobile/src/shared/ui/keyboard-aware-scroll-view.tsx`, imported from `@/shared/ui`) — **never** a bare RN `ScrollView` or a non-scrolling `View` around the fields.
  - For a screen that is normally centered/non-scrolling (e.g. login), give the `KeyboardAwareScrollView` `contentContainerStyle={{ flexGrow: 1, justifyContent: "center" }}` so it stays centered when the keyboard is closed and scrolls when it opens.
- **The root provider's context does not cross an RN `Modal` boundary.** A shared bottom `Sheet` built on `Modal` must re-mount `KeyboardProvider` inside the Modal and lift its panel with the library's `KeyboardAvoidingView`. Put input-bearing bottom-sheet content inside that shared `Sheet`; do not hand-roll a Modal with inputs.
- Inputs overlaid on a full-screen surface where a scroll view is impractical (e.g. a manual-entry bar over a camera preview) may use a `KeyboardAvoidingView` directly instead.
- A top-anchored search field in a list header is exempt — it sits above the keyboard and is never covered; do not add a scroll wrapper there.

**Red-flag checklist (reject at review):**
- A new mobile form/screen with a `TextInput` (or `Input`/`Textarea`) wrapped in a bare RN `ScrollView` or a static `View` instead of the shared `KeyboardAwareScrollView`.
- A hand-rolled RN `Modal` containing a text input instead of the shared `Sheet`.
- Importing `KeyboardAwareScrollView` from `react-native-keyboard-controller` directly in a feature file instead of the shared wrapper (defaults like `bottomOffset` / `keyboardShouldPersistTaps` live there).
- Removing `KeyboardProvider` from `app/_layout.tsx`.

## List feeds must refetch on screen focus

Expo Router keeps tab and stack screens **mounted** after first render. Unless the app wires React Query's `focusManager` (AppState) and `onlineManager`, React Query's automatic refetch triggers (mount, window focus, reconnect) never fire again after the first fetch. Without an explicit trigger, a feed displays its first-fetch data forever (typical bug: a list shows its empty state for an item published minutes ago, until pull-to-refresh).

**Rules:**
- Every screen-level list/feed component backed by a query refetches on focus:

  ```ts
  import { useFocusEffect } from "expo-router";

  const refetch = query.refetch;
  useFocusEffect(
    useCallback(() => {
      void refetch();
    }, [refetch]),
  );
  ```

- Pull-to-refresh (`refreshing` + `onRefresh` on the `FlatList`) complements the focus refetch; it never replaces it.
- Do NOT rely on `staleTime` / `refetchOnMount` for freshness on a tab screen — tab screens never remount, so those options never re-trigger.

**Known cost, open experiment:** `refetch()` ignores `staleTime`, so every tab revisit refetches a full page even seconds after the last fetch. A prototype kept the effect and skipped the call when the data was fresh (`if (isStaleRef.current) void refetch()`, with `isStaleRef.current = query.isStale` set on each render); requests per focus fell from 2 to 0.7. The result was suggestive only (two iterations, an unexplained CPU rise, the reconnect case untested), so the rule above is unchanged. Do not apply the stale gate to a feed without a measured before and after, and never remove the effect.

**Red-flag checklist (reject at review):**
- A new feed/list screen whose query has no `useFocusEffect` refetch.
- Removing the `useFocusEffect` refetch from an existing feed as "redundant" with pull-to-refresh or `staleTime`.

## File uploads — Expo fetch rejects legacy FormData parts

Expo's WinterCG-compliant `fetch` rejects the legacy React Native `{ uri, name, type }` FormData file part **client-side** (the upload fails before any request is sent). Every mobile file upload builds parts with a helper that reads the file into bytes — the repo's, if it has one (e.g. `toExpoFilePart` in `src/shared/lib/expo-form-data.ts`). Never pass `{ uri, name, type }` objects to `FormData.append`.

## Direct uploads — large binaries never enter the JS heap

Reading a file into bytes (`File.bytes()`) is fine for a 300 KB photo and fatal for a 25 MB video on a low-end Android device. Large binaries (video, long documents) therefore go client → storage through a signed URL, when the repo's docs approve a direct upload for that file kind.

**Rules:**
- Use the repo's direct-upload helper if it has one (e.g. `createDirectUploader(transport)` or `useDirectUpload()` inside the transport provider — check the route group's layout actually mounts that provider). Pass the legacy multipart route as the fallback.
- Move the bytes with `UploadTask` from **`expo-file-system`** (not `expo-file-system/legacy`) with `uploadType: UploadType.BINARY_CONTENT`, `httpMethod: "PUT"`, `onProgress` and a native `signal` (e.g. in a `src/shared/lib/put-binary.ts`). It is JS-only, so it ships over the air — do not bump `expo-file-system` for it.
- Never `supabase.storage.*` and never a `supabase-js` upload helper in `apps/mobile`.
- Everything else keeps the bytes-part helper + the API client's multipart upload.

**Red-flag checklist (reject at review):** a new large-binary upload built with `File.bytes()`; a direct upload without a fallback; `expo-file-system/legacy` `createUploadTask` (no `signal`, so cancel does not work).

## Dynamic text colors — inline style, not className

NativeWind v4 compiles classes at build time: a runtime-computed class like `text-[${hex}]` is a silent no-op until the next recompile, and a shared `Text` component's own color classes can override late-applied ones. Any color computed at runtime is applied with `style={{ color }}`, never interpolated into a className.

## Forced dark subtrees

NativeWind v4 on native renders CSS-variable themes light even when the OS scheme is dark. To force a dark subtree, wrap it with `vars()` overrides; do NOT call `setColorScheme` (it flips the whole app).

## Route hrefs must be group-qualified

When two route groups (e.g. `(admin)` and `(member)`) own routes at the same URL paths (`/projects/[id]`, `/settings`, …), unqualified hrefs are ambiguous. expo-router's `getStateFromPath` sorter ranks candidate routes by `staticPartCount` BEFORE it applies "same group as the current screen" similarity, and an `[id]/index.tsx` file counts one static part more than an `[id].tsx` file. So an unqualified `router.push("/projects/1")` from inside `(member)` can resolve to `(admin)/projects/[id]/index`, and the auth gate bounces the user back to their home screen. Routes whose file shape happens to match in both groups only work by a sorter tie — not a guarantee.

**Rules:**
- Every absolute href in a role surface is group-qualified: `router.push("/(member)/projects/1")`, `pathname: "/(admin)/…"`, `<Redirect href="/(member)/…" />`, `/(auth)/login`. Never `/projects/1`.
- Registry-driven navigation (tile and notification route tables) keeps group-less `route` literals in the table and prepends the group in the resolver function — the resolver, not the caller, owns the prefix.
- If the repo has a static scan test for this (e.g. `group-qualified-hrefs.test.ts`, listing every offending `file:line`), keep it passing; do not add one as part of unrelated work.
- Screens at the ROOT of `app/` (e.g. `/change-password-required`, `/unsupported`, `/`) belong to no group on purpose and stay unqualified; the scan should exempt them by reading `app/*.tsx`.
- Residual hazards a syntactic scan cannot catch: (a) an OS scheme deep link (`<app>://projects/1`) arrives group-less with empty segments and resolves by the sorter — keep in-app push routing qualified; (b) an href whose leading segment is a variable — `` router.push(`${ROUTE_BASE[type]}/${id}/edit`) ``, `router.push(section.route)`, or a group-qualified route passed down as a prop. Keep the constant itself group-qualified — nothing will catch it if you don't.

**Red-flag checklist (reject at review):**
- A new `router.push` / `pathname:` / `href=` with an absolute path that does not start with `/(`.
- A new route registry whose target resolver returns the raw `route` without a group prefix.
- Deleting or narrowing the href scan to make a new href pass.

## Performance on low-end Android

If the app's users run 2 to 4 GB Android phones, these rules apply. They come from a performance audit of such an app; the measurement rules and the React rules shared with web are in the `frontend-performance` skill — read it before claiming or reviewing a performance change. Tags: **[measured]**, **[symptom]** (measured, no fix tried), **[code-read]** (cost unknown).

**Gate:** if the repo has a device performance check (e.g. `pnpm perf check` on a USB reference phone), a change to performance-sensitive surfaces or shared mobile code (`src/shared`) runs it before merge, in addition to the UI tests. It is human-invoked, never part of `pnpm test` or CI; a bundle-size check (e.g. `pnpm perf check-bundle`) can run in CI.

### Tabs stay mounted [symptom]

Inactive tabs keep their queries observed and their rows re-rendering (125 row renders in an unrelated tab during one flow). Treat every tab as live:
- No camera, timer or subscription in tab-level content unless it is gated on focus.
- Unless `focusManager` and `onlineManager` are wired, React Query never pauses a `refetchInterval` and retries ignore NetInfo. A new polling query must not assume the library pauses it in the background.

### Camera and scanners [code-read; memory inside budget]

- **One camera session at a time.** On Android a camera view binding unbinds every other camera. Every file that renders `<CameraView` checks whether an in-app capture is open (the repo's hook, if it has one, e.g. `useInAppCaptureOpen()`) and renders nothing while one is. If the repo has a test that scans for `<CameraView` (e.g. a `scanners-release-camera` spec), keep it passing.
- **Photos on Android use an in-app capture, never the system camera app.** Launching the phone's camera backgrounds the app; on a low-memory phone Android kills it and the photo and form state are lost. Route photos through the repo's shared picker helper if it has one (e.g. `launchPhotoPicker`). Save the draft before opening the capture.
- Unmount the preview when the scan is locked or a result sheet covers it.
- Dedupe scan callbacks with a real dedupe helper (e.g. `shouldSurfaceScan` in `src/shared/lib/scan-dedupe.ts`); returning early on `locked` is not a dedupe.
- Do not raise the preview or picture size above what the scan or the 2048 px photo needs.

### Photos and files

- **Never base64** in JS memory or state. Pick raw, bounded decode to 2048 px, one re-encode at a time [code-read; peak memory measured near its budget].
- **Local-file previews use expo-image with a size hint**, not react-native `Image` on a 2048 px file [code-read].
- **Every helper that writes a cache or temp file names who deletes it**, on the success and the failure path [symptom: the cache directory grew about 7.5 MB/h in a soak; image resizes were never deleted].
- No full-resolution image in a list row; rows use the API thumbnail through a cached image component (e.g. `CachedImage`).

### Lists

- An unbounded list is a `FlatList`, never `ScrollView` + `.map()`. Bounded pickers and sheets in a `ScrollView` are fine [code-read].
- Do not add `getItemLayout`, `windowSize` tuning or FlashList without a scroll measurement before and after; scroll jank was already inside budget.

### Sheets, WebViews, heavy mounts

- A closed sheet unmounts its content [symptom: about 59.5 MiB kept after the first sheet open, cause not established].
- WebView, signature pad and view capture are created on demand and destroyed after use; none belongs on a performance-sensitive route.
- Animations run in Reanimated on the UI thread: no react-native `Animated`, no `LayoutAnimation`, no interval driving visual state.

### Storage, location, realtime

- Draft fields update an in-memory store; the persistent write (e.g. MMKV) happens at step change and before a photo pick, never per keystroke. No large blobs in MMKV: files go to the file system, MMKV holds references.
- Location is one-shot at Balanced accuracy unless the feature needs a watcher; a watcher is removed in its focus cleanup.
- Realtime channels subscribe in an effect and call `removeChannel` in its cleanup.

### Build and bundle

- A new dependency that moves the Android bundle size answers the reviewer questions in the repo's performance runbook, if it has one. Check that a DOM-only package is not pulled into the RN bundle.
- Turning on R8 and resource shrinking is a store build and needs a full hand test.

**Red-flag checklist (reject at review):**
- A `<CameraView>` in a file that does not check for an open in-app capture, or one left previewing behind a sheet.
- `base64: true` on a picker or camera call; a photo path that bypasses the shared picker helper.
- A helper that writes to the cache directory with no delete.
- An unbounded `ScrollView` + `.map()` on a tab screen.
- A new `refetchInterval` with no thought for the background.
- A camera, timer or subscription mounted by tab content without a focus gate.
- A performance-sensitive or `src/shared` change merged without the device perf check, where the repo has one.
- A limit raised in the perf budget file to make the check pass.
