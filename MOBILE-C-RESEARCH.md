# ClipKeep Mobile — Design C + React Native Research

Researched Sun Nov 22, 2026, at Femi's request. Companion to `MOBILE-RESEARCH.md`
(§§1–8, Nov 17–22), which remains the source for platform limits, the sync
options survey, and the backend comparisons. This document covers what changed
since: **design C (Gallery) is the chosen mobile design**, and **React Native
is the stack for both iOS and Android** (Femi's decision, Nov 22 — it plays to
his React/TypeScript strength and supersedes §8's native-Kotlin-first plan).
Everything settled in `MOBILE-RESEARCH.md` still holds and is not re-argued
here: no passive capture on either platform, deliberate capture only, no
accessibility hacks, no CloudKit, Drive folder for v1 sync, v2 backend an open
three-way (Firebase / Supabase / AWS), sensitive clips never sync, Amplify out.

**The one-sentence answer:** design C is fully buildable in React Native —
every C screen is ordinary RN — and the only genuinely native work is a short,
known list of escape hatches (share intake, one Android tile, one iOS paste
control, one OCR module), all of which fit the Expo prebuild model without
ejecting. Nothing in C has to be redesigned for RN; two Mac features
(Paste Stack, ⌘1–9 injection) stay impossible on phones for OS reasons that
have nothing to do with the framework.

---

## 1. Design C — full spec

Design C ("Gallery") as approved from the Nov 22 mockups. Palette from the
mocks: light lagoon theme — pale teal background (`#eef7f5`), deep teal primary
(`#0e7c6f`), white tiles, the Mac app's per-kind band colours reused as tile
accents (orange text, teal link, green messages/text, purple image).

### 1.1 Screens

**Home (the gallery).** Top to bottom:

1. **Header** — "ClipKeep" wordmark left; sync state right ("Synced · Drive",
   "Syncing…", "Offline — will sync later", "Sync off"). Sync state is a real
   state machine (§5), not decoration.
2. **Search field** — rounded, placeholder "Search history…". Focusing it
   collapses the summary cards (below) and turns the grid into live results.
   Search covers clip text, link titles, source-app names, **and OCR text**
   inside image clips (same promise as the Mac).
3. **Summary cards row** — three cards: **All clips** (count), **Pinned**
   (count), **Boards** (count). All clips = the home grid unfiltered; Pinned
   opens the pinned view; Boards opens the boards screen. Counts are live
   from the local store.
4. **Tile grid** — two columns, newest first. Tiles are fixed-structure cards
   (not true masonry — uniform rows scan better and recycle better, §2.4).
5. **Capture button** — a prominent full-width button pinned at the bottom:
   "＋ Save current clipboard". Always visible; it is the primary on-phone
   capture route alongside share-to-save.

**Clip detail.** Reached by tapping any tile. Large rendering of the clip
(image clips: the image large, full width), the OCR text block when present
(labelled "Text inside this image", selectable/copyable as text), then
metadata rows — Source (app + origin device, e.g. "Chrome · Mac"), Copied
(timestamp), Board (name or "—"). Bottom action bar: **Copy / Pin / Board /
Delete**. Copy writes the clip back to the phone clipboard (unrestricted on
both platforms) and confirms with a toast/snackbar. Board opens a board
picker (existing boards + "New board"). Delete confirms inline (it writes a
tombstone, §5 — other devices must learn about it).

**Boards screen.** A list of boards, each row: cover (the board's most recent
image clip thumbnail, or a colour block with the board's initial), name, clip
count, "updated …" relative time, chevron. A "＋ New board" row at the end.
Tapping a board opens **the same tile grid**, filtered to that board, with
the board name as the header and the capture button still present (captures
while inside a board file straight into it — decide in build; default: no,
capture files to All and the user boards it from detail — simpler mental
model).

**Pinned view.** The same grid filtered to pinned clips, reached from the
Pinned summary card.

### 1.2 Tile types (the grid's vocabulary)

| Tile | Rendering | Notes |
|---|---|---|
| Image | Full-bleed thumbnail, kind + time badge overlaid bottom-left; "Contains text" marker when `ocrText` is non-empty | Thumbnails generated on sync-in (not the full PNG) — grid performance depends on it |
| Text | White card, text preview (≈5 lines, squarer than a list row), meta line: kind · time · source | Long text truncates; full text in detail |
| Link | White card, page title (from Mac's fetched `linkTitle`, or fetched on phone save), domain beneath, source/time meta | Falls back to the raw URL when no title exists yet |
| Colour | Large swatch filling most of the tile + hex string | Tap copies the hex (detail still available via long-press) — decide in build; default: tap = detail like everything else, for consistency |
| File | White card, file name + size + "On Mac" tag | **View/download deferred in v1** — the file's bytes stay on the Mac (§5.2); the tile is a metadata placeholder so the history is complete |

### 1.3 Interactions

- **Tap tile** → detail. **Long-press tile** → quick action sheet with the
  same four actions (Copy / Pin / Board / Delete) — no navigation.
- **Pull-to-refresh** on any grid → nudges a sync cycle now (§5.4) and shows
  the sync state in the header while it runs.
- **Search** → cards row collapses, grid becomes results, tile types unchanged.
- **Capture button** → reads the current clipboard *in the foreground* (§3d)
  and saves it as a new clip with origin = this device; duplicates (same
  content hash as the newest clip) are swallowed silently, matching the Mac.
- **Share-to-save** (§3a) → shared content lands as a new clip and the app
  opens on the home grid with the new tile briefly highlighted.

### 1.4 States

- **Empty (no clips at all):** the grid area shows the C empty state — app
  icon, "Nothing here yet", and three hint rows mirroring the Mac's empty
  state: copy something on the Mac, share to ClipKeep, or tap the capture
  button. If sync is off, the first hint is "Turn on sync" instead.
- **Empty (no results / empty board):** "Nothing matches" variant, same as
  the Mac's distinction.
- **Loading (first sync):** skeleton tiles in the grid + header sync state
  "Syncing…"; the app is usable (local clips, capture) while the first pull
  runs.
- **Offline:** everything local works; header shows "Offline"; captures and
  edits queue in the outbox (§5.4) and flush on reconnect/foreground.
- **Sync error (auth expired, folder missing):** header state becomes a
  tappable warning row under the header ("Sync needs attention — tap to
  reconnect"), never a modal.

### 1.5 What carries over from the Mac data model unchanged

Kinds (text/link/image/file/colour), pins, boards-as-names, source-app
attribution, OCR text, content-hash dedupe, the history limit concept, and
the sensitive-clip exclusion all map 1:1 — C is a presentation of the same
model, not a new one. Two deliberate deviations, both from the approved
mockups: **(1)** pinned clips do *not* float to the top of the mobile home
grid (the Mac sorts pinned first); they live behind the Pinned card —
the grid is strictly newest-first. **(2)** The Mac's Paste Stack and ⌘1–9
have no mobile counterpart at all (§4).

---

## 2. Stack — React Native

### 2.1 Expo (prebuild) vs bare RN — recommendation: **Expo, prebuild workflow**

Current facts: Expo SDK 58 shipped Oct 15, 2026 (React Native 0.88,
React 19.2, built for iOS 27); SDK 57 (Jun 2026, RN 0.86) is what
`create-expo-app` still scaffolds by default — start with
`create-expo-app --template default@sdk-58` and a development build
([Expo SDK 58 changelog, expo.dev, Oct 2026](https://expo.dev/changelog/sdk-58)).

- **Expo Go is out** from day one: share extensions, the QS tile, and every
  custom module in §3 are native code Expo Go cannot load. That's fine —
  the workflow is **development builds** (`eas build --profile development`
  or local `expo run:*`), which is the normal professional Expo flow now.
- **Prebuild (Continuous Native Generation), not bare:** keep `ios/` and
  `android/` *generated* — native changes are expressed as config plugins
  and local modules (§3), and the native projects are regenerated, never
  hand-edited. This is what makes SDK upgrades survivable for a solo dev.
  Bare RN would give identical runtime capability at the cost of owning
  every native project file and every upgrade diff personally.
- The practical consequence: **every native need must be satisfiable by
  (a) a library with a config plugin, (b) a config plugin we write, or
  (c) a local Expo module.** §3 shows each C requirement fits one of those.

### 2.2 The stack, piece by piece

| Concern | Pick | Why |
|---|---|---|
| Language | TypeScript (strict) | His strongest language; the sync schema (§5.2) becomes shared TS types |
| Navigation | **Expo Router** | File-based, typed routes, and it has a defined story for share-intent deep links (§3a); React Navigation underneath |
| Local store | **expo-sqlite** (see §2.3) | First-party, New-Architecture-native, FTS5 for search |
| Settings/cursors | **react-native-mmkv** v4 | Tiny KV for sync cursors, device id, flags; v4 (Jun 2026) is the Nitro rewrite with RN 0.87+ support |
| Grid | **FlashList v2** (see §2.4) | Recycling grid; the C grid is the app's main surface |
| Styling | StyleSheet + a design-token file | C is a bespoke design; tokens mirror the mock palette and the Mac's kind colours. No UI kit (they fight custom designs), no NativeWind (extra compiler layer for one dev) |
| Images | `expo-image` | Disk/memory cache + thumbnails for image tiles; pairs with FlashList recycling |
| Clipboard | `expo-clipboard` | Writes + foreground reads (§3d) |
| Auth (Drive) | `expo-auth-session` | Google OAuth (PKCE) for Drive REST (§5.4) |
| Background sync | `expo-background-task` | First-party; WorkManager + BGTaskScheduler (§3f) |
| Secure storage | `expo-secure-store` | OAuth refresh tokens, device key material later (E2EE, §5.6) |

### 2.3 Local data — pick: **expo-sqlite**, not WatermelonDB

This is the one place 2026 evidence overturns the conventional pick:

- **WatermelonDB is no longer a safe foundation.** Its last stable release
  (0.28.0) was April 2025, its changelog stalls in 2023, and it is untested
  on the New Architecture that RN ≥0.82 makes mandatory; its Expo config
  plugin is a stale community package requiring patches and peer-dep
  overrides ([dev.to SDK 54 setup guide, 2026](https://dev.to/fasthedeveloper/watermelondb-expo-sdk-54-the-complete-mobile-offline-first-setup-guide-that-actually-works-5he5)).
  A 2026 fork (NitromelonDB) rebuilds it on Nitro Modules and targets
  SDK 58, but it is a months-old single-maintainer project — watch it,
  don't found on it.
- **expo-sqlite is first-party and current**: synchronous + async APIs,
  prepared statements, and — decisive for ClipKeep — **FTS5 full-text
  search** (config-plugin `enableFTS`, on by default) so one query covers
  text, link titles, source apps and `ocrText`, exactly the Mac's search
  promise. SQLCipher is available via config plugin if at-rest encryption
  is wanted before E2EE lands ([storage research survey, Aug 2026](https://rasd.khreshitech.solutions/docs/research/offline-storage-and-sync/)).
- The data volume is tiny (hundreds of clips, capped by the history limit),
  so the store's job is correctness and search, not scale. A thin
  repository layer over expo-sqlite (plain SQL, no ORM; Drizzle is
  available if wanted later) plus MMKV for cursors/flags is the whole
  data layer. Clip payloads (image files) live on disk via
  `expo-file-system`, referenced from rows — same shape as the Mac.

### 2.4 Grid performance

**FlashList v2** (`@shopify/flash-list`). V2 is a ground-up rewrite for the
New Architecture: JS-only, **no `estimatedItemSize`** (it measures items
itself), recycling pools per item type via `getItemType` — a natural fit
for C's five tile types — and it supports masonry layout if the design
ever wants it ([2026 RN performance guides](https://codezup.com/react-native-performance-optimization-guide/)).
At ClipKeep's scale (≤ a few hundred tiles) even FlatList would survive,
but FlashList costs nothing extra and removes the known jank class.
Rules that matter more than the library: stable tile components, thumbnails
never full-size PNGs in the grid, `keyExtractor` = clip id.

### 2.5 Build & release — EAS

- **EAS Build + Submit** for store binaries; **EAS Update** for OTA.
  2026 pricing (checked Nov 2026): Free plan = 15 Android + 15 iOS builds
  /month, low-priority queue (waits of 90+ min at peak are documented),
  store submission included, OTA updates capped at **1,000 monthly active
  users, hard stop**; Starter is $19/mo (+$45 build credit, 3,000 MAUs)
  ([Expo pricing survey, Nov 10, 2026](https://superapp.dev/blog/expo-pricing);
  [EAS Update cost analysis, Nov 18, 2026](https://dev.to/sunnylqm/what-expo-eas-update-actually-costs-at-50k-150k-and-1m-mau-in-2026-with-the-exact-formulas-57m5)).
  For a personal app the Free plan suffices; local builds on the MacBook
  (`eas build --local`, `expo run:*`) are the queue escape hatch.
- **OTA limits, stated plainly:** EAS Update ships JS and assets only,
  gated by `runtimeVersion` (use the fingerprint policy). Anything native
  — a new module, a config-plugin change, a permission, the share
  extension, the tile — is a **new store build**. UI fixes and sync-logic
  fixes can ride OTA; §3's features cannot.
- Versioning: one version for both platforms from `app.json`; build
  numbers auto-incremented by EAS.

### 2.6 Repo shape — recommendation: **separate repo**

Create `femisowems/clipkeep-mobile` (Expo app). Do **not** monorepo it with
the Mac app: the Mac repo's CI is a Swift/GitHub Actions pipeline and the
two toolchains share nothing but a spec. What *is* shared lives as
documents and fixtures, not code: `SYNC-SCHEMA.md` (§5.2) is canonical in
the Mac repo; the mobile repo vendors a copy of the schema + a folder of
sample clip JSON/image fixtures, and both sides run contract tests against
the fixtures (Mac: its logic test suite; mobile: Jest). If the schema
changes, the fixtures change in both repos in the same commit pair. A
Turborepo-style monorepo buys nothing for one developer and two unrelated
build systems.


---

## 3. The native escape hatches C needs

RN covers all of C's UI. Six capabilities need native code. Each is listed
with the concrete Expo-era mechanism, its maturity, and its scope. Total
native surface: **one library, two small local modules, one tiny native
view, one config plugin** — a few days of native work, not a second app.

### 3a. Share-to-save — iOS share extension + Android share target

**Pick: `expo-share-intent`** (v9.0.0, current Nov 2026, with an explicit
version matrix — 9.0+ for SDK 58, 8.0+ for SDK 57). It's a native module +
config plugin: the plugin generates the **iOS Share Extension target**
(App Group hand-off) and the **Android intent filters**
(`ACTION_SEND` / `ACTION_SEND_MULTIPLE` for `text/*`, `image/*`, files);
content is delivered to the main app, where a `useShareIntent()` hook /
`ShareIntentProvider` hands it to JS as `{ text, webUrl, files[], meta }`
([expo-share-intent, npm, Nov 2026](https://npm.io/package/expo-share-intent)).
That shape suits ClipKeep exactly: the extension is a redirect shell, the
*app* does the saving (dedupe, OCR queue, sync-out), so no logic is
duplicated inside an extension process.

- Content types to enable: text, web URL, images, files (files land as
  file clips — metadata + bytes stored locally on the phone; §5.2).
- Android gotcha: shared-content URIs are temporary grants — copy the
  bytes into app storage synchronously on receipt.
- iOS gotcha: the extension's memory ceiling (~120 MB) is irrelevant at
  redirect-shell scope; large images are read by the app, not the extension.
- Fallback if the library rots: the plugin's generated native code is
  visible in the prebuild output and can be vendored; Expo's first-party
  `expo-sharing` also added *experimental* receive support with its own
  config plugin (SDK 55 docs) — younger, but a credible second source.
- Maturity: **high** — this is the standard way Expo apps receive shares
  in 2026; requires a development build (no Expo Go), which is already
  the workflow (§2.1).

### 3b. Android Quick Settings tile

A `TileService` is a separate Android component; no part of RN renders it.
Two routes:

1. **Hand-rolled local Expo module (recommended).** ~120 lines of Kotlin:
   a `TileService` subclass whose `onClick()` calls
   `startActivityAndCollapse()` with an intent to a lightweight capture
   activity (the main activity with a `?capture=1` route is fine), plus a
   config plugin that writes the `<service>` declaration
   (`BIND_QUICK_SETTINGS_TILE`, QS intent action, Samsung category
   meta-data for One UI) into the generated manifest. The JS side needs
   almost nothing — optionally a call to set the tile's label/state.
   Scope: **half a day to a day**, including on-device testing on the S23+.
2. **`expo-invoke`** (v3.1.5, ~Sep 2026) generates a TileService (and
   Siri/widgets/Control Center surfaces) from `app.json` config with a
   `useQuickTile()` hook — zero native code
   ([expo-invoke, npm, Nov 2026](https://npm.io/package/expo-invoke)).
   Tempting, but it's a two-month-old package to hang a core capture
   route on. Verdict: spike it in Phase 1 if time allows; ship route 1.

**The behavioural fact that shapes the UX:** the tile *cannot read the
clipboard* — a background read returns empty (MOBILE-RESEARCH §1). The
tap's job is to foreground the app; the capture activity then reads the
clipboard in the foreground (an Android 12+ "pasted from your clipboard"
toast may appear the first time per source app), saves, and collapses.
From the user's seat it's still one tap → "Saved to ClipKeep".

### 3c. iOS tap-to-capture — UIPasteControl + App Intent

`UIPasteControl` is the sanctioned no-prompt read (the tap *is* the
consent), and it is a UIKit control — RN has no component for it.

- **Scope a tiny local Expo module with a native view** (Swift, ~80
  lines): a `UIView` wrapping `UIPasteControl` configured for
  `UIPasteboard.general`; the control's target/action fires on tap, the
  module reads the pasteboard *inside that gesture context*, and exposes
  the result to JS as an event/promise (`{ text?, imagePNG?, hasURL }`).
  In the C UI, the bottom capture button on iOS *is* this native view
  dressed in the button's styling. Scope: **half a day**, plus device
  testing (the prompt-free behaviour is the whole point — verify on real
  hardware via Test Lab/Device Farm, §6.3).
- **Fallback inside the same app:** `expo-clipboard`'s programmatic read
  works but raises the iOS 16+ paste permission alert per read (unless
  the user set "Paste from Other Apps: Allow"). Acceptable for a
  secondary "Import clipboard" menu item; not the primary button.
- **Shortcuts / App Intent route:** a small Swift `AppIntent` in the same
  local module — "Save to ClipKeep" taking text/URL/image *input*.
  The reliable composition is Shortcuts' own **Get Clipboard** action
  feeding ClipKeep's intent (Shortcuts reads the clipboard itself, so no
  prompt gymnastics), which the user can put on the Home Screen or Action
  Button. An intent that reads `UIPasteboard` directly from the
  background can still hit the prompt rules — don't spec it that way.
  Scope: **half a day**, Phase 2 (iOS phase) only.

### 3d. Clipboard read/write from RN

`expo-clipboard` covers the everyday paths:

- **Writes (copy-back) — unrestricted on both platforms**, silent, no
  permission: `setStringAsync`, `setImageAsync`, `setUrlAsync`. This is
  the detail screen's Copy action and the colour tile's copy. Android 13+
  shows the system's own copy preview overlay — system UI, not ours.
- **Reads — foreground only, by OS rule.** `getStringAsync` /
  `getImageAsync` / `hasStringAsync`: on Android a background read returns
  empty and the first cross-app read surfaces the system toast; content
  the source flagged sensitive (`EXTRA_IS_SENSITIVE`) must be honoured —
  read the flag via the native layer and refuse to save (parity with the
  Mac's concealed-type rule). On iOS a programmatic read is the prompt
  path in §3c — the in-app capture button on Android can use
  `expo-clipboard` directly (app is foreground by definition); on iOS it
  uses the UIPasteControl module.
- Change *detection* (`addClipboardListener`, `UIPasteboard.changedNotification`)
  only fires while foregrounded — useful for one nicety: if the clipboard
  changes while ClipKeep is open, the capture button can badge "new".
  Not a capture route.

### 3e. On-device OCR for phone-saved images

Only phone-origin images need OCR on the phone — everything synced from
the Mac arrives with `ocrText` already computed by Vision on macOS.

- **Android: ML Kit Text Recognition v2** (bundled Latin model, fully
  offline). The maintained RN wrappers are VisionCamera-centric
  (`vision-camera-ocr-plugin` v5.0.12; `react-native-vision-camera-mlkit`
  v2.0.1, which does expose a static-image API,
  `processImageTextRecognition`) — but ClipKeep has no camera feature,
  so pulling in VisionCamera for one still-image call is poor trade.
- **Recommendation: one local Expo module, `clipkeep-ocr`** —
  `recognizeText(imageUri) → string`. Android side: ML Kit directly
  (~100 lines of Kotlin). iOS side: **Vision** (`VNRecognizeTextRequest`,
  ~60 lines of Swift) — deliberately *not* ML Kit on iOS: it's the same
  engine the Mac uses (OCR text behaves consistently across the
  ecosystem), and ML Kit's iOS frameworks are known to lack an
  arm64-simulator slice, which would sabotage simulator-based iOS testing
  (§6.3) ([vision-camera-ocr-plugin notes, Oct 2026](https://npm.io/package/vision-camera-ocr-plugin)).
- OCR runs as a background job after a phone save (share/capture), writes
  `ocrText` into the local row, and marks the clip dirty for sync-out.
  Failure is non-fatal: the clip saves with empty OCR and search simply
  doesn't see inside it yet.

### 3f. Background sync triggers — and their honest limits

**Pick: `expo-background-task`** (first-party since SDK 53;
`expo-background-fetch` is deprecated). It wraps Android **WorkManager**
and iOS **BGTaskScheduler** behind one JS task registration
([background-work survey, 2026](https://folio.gurgul.pro/react-native/rn-background-tasks.html)).

- Android: periodic work with a **15-minute minimum interval** (that's a
  floor, not a promise), deferred by Doze and App Standby buckets;
  Samsung's battery management on the S23+ is among the more aggressive
  OEM layers — expect hours-scale, not minutes-scale, background cadence.
- iOS: BGAppRefresh/BGProcessing windows are system-scheduled (~30 s for
  refresh), **never run after a user force-quit**, and **cannot be tested
  in the simulator** (physical device only).
- **Design rule that follows:** background sync is a bonus, never a
  correctness dependency. Sync runs (1) on app launch/foreground, (2)
  after every local mutation (capture, pin, delete — debounced), (3) on
  pull-to-refresh, and (4) opportunistically in the background task.
  The outbox (§5.4) makes all four idempotent, so overlaps are harmless.
- No push in v1 — there is no server to send one. The v2 backend (§5.5)
  is what unlocks FCM/APNs silent-push sync nudges.

---

## 4. Feature coverage matrix — design C under RN

Legend: **RN** = plain React Native/Expo · **Native** = needs a §3 escape
hatch · **Deferred** = designed, not in v1 · **Impossible** = OS-blocked,
fallback named.

| C feature | Android (RN) | iOS (RN) |
|---|---|---|
| Home gallery grid (FlashList) | RN | RN |
| Header + live sync state | RN | RN |
| Summary cards (All / Pinned / Boards) | RN | RN |
| Search incl. OCR text (FTS5) | RN | RN |
| Tile types: text / link / colour | RN | RN |
| Tile type: image (+ thumbnails) | RN | RN |
| Tile type: file (metadata) | RN | RN |
| File clip view / download | Deferred (bytes stay on Mac in v1) | Deferred |
| Clip detail screen | RN | RN |
| Detail: OCR text block | RN (text arrives with clip / §3e) | RN |
| Copy-back to clipboard | RN (`expo-clipboard` write) | RN |
| Pin / Board / Delete (+ tombstones) | RN | RN |
| Boards screen + board grids | RN | RN |
| Long-press quick action sheet | RN | RN |
| Pull-to-refresh sync nudge | RN | RN |
| Empty / loading / offline states | RN | RN |
| Share-to-save | **Native** — library (§3a) | **Native** — library (§3a) |
| Capture button (in-app) | RN (foreground read) | **Native** — UIPasteControl view (§3c) |
| Quick Settings tile capture | **Native** — local module (§3b) | n/a — fallback: Home Screen widget / Shortcuts (Deferred) |
| Shortcuts "Save to ClipKeep" | n/a (share + tile cover it) | **Native** — App Intent (§3c), Phase 2 |
| OCR of phone-saved images | **Native** — local module, ML Kit (§3e) | **Native** — local module, Vision (§3e) |
| Link title fetch for phone-saved links | RN (fetch + parse; deferred if offline) | RN |
| Drive sync (pull/push, outbox) | RN (REST) | RN |
| Background sync | RN (`expo-background-task`, OS-limited) | RN (same, stricter limits) |
| Sensitive-clip exclusion | RN + flag read (§3d) | RN (concealed type via module) |
| Passive/background capture | **Impossible** — deliberate capture is the product | **Impossible** — same |
| Paste Stack / ⌘1–9 paste injection | **Impossible** — no paste injection exists; fallback: copy-back one clip at a time | **Impossible** — same |

**Headline:** no C feature is impossible under RN. The two impossible rows
are Mac features that were already impossible on *any* mobile stack
(MOBILE-RESEARCH §2) — RN changes nothing there.


---

## 5. Sync between all apps

One ecosystem, four clients: **Mac (Swift)**, **Android (RN)**, **iOS
(RN)**, **ClipKeep Web**. They interoperate because they share a *format*,
not a codebase. The format is the contract; the transport (Drive in v1, a
backend in v2) is replaceable underneath it — the thin-transport-interface
rule from MOBILE-RESEARCH §3, kept.

### 5.1 Principles

- **Per-clip files, never one big JSON.** One file per clip means conflicts
  are per-clip, syncs are incremental, and a corrupt file costs one clip.
- **Last-writer-wins per clip**, keyed on `updatedAt`. Clipboard data is
  low-conflict by nature (clips are mostly immutable; pins/board moves are
  the only real edits).
- **Deletes are tombstones**, not absences — a rewritten file with
  `deleted: true`, retained 90 days, so a device that was offline for a
  month still learns about the delete instead of resurrecting the clip.
- **Sensitive clips never enter the format at all** — exclusion happens at
  capture time on each device (Mac concealed types, Android
  `EXTRA_IS_SENSITIVE`, iOS concealed type). There is deliberately **no
  `sensitive` field in the schema**: what isn't written can't leak.
- **Images are content-addressed** (`sha256`), so the same image copied on
  two devices is one file, and integrity is checkable on every client.

### 5.2 The clip sync schema (v1)

One JSON file per clip, `clips/<id>.json`:

```jsonc
{
  "schema": 1,                          // format version, stamped in every file
  "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",  // UUID, minted by origin device
  "kind": "text",                       // text | link | image | file | color
  "text": "…",                          // text clips; the URL for link; "#B0D0D3" for color
  "linkTitle": "…",                     // link only, when fetched
  "image": {                            // image only
    "file": "images/ab/ab12cd….png",    // path in the sync folder, content-addressed
    "sha256": "ab12cd…",
    "width": 1170, "height": 2532
  },
  "ocrText": "…",                       // image only, when recognized (may arrive later as an update)
  "file": { "name": "report.pdf", "size": 48213, "bytesSynced": false },  // file only; v1 = metadata only
  "sourceApp": "Google Chrome",         // display name, as the Mac shows it
  "sourceId": "com.google.Chrome",      // bundle id (Mac/iOS) or package name (Android); null from web
  "createdAt": 1763846400.0,            // seconds since 1970 (matches the Mac's Double)
  "updatedAt": 1763846400.0,            // touched on ANY mutation: pin, board, OCR arrival, delete
  "pinned": false,
  "board": "Amazon prep",               // board name or null
  "origin": { "deviceId": "8C1D…", "platform": "macos" },  // platform: macos | android | ios | web
  "deleted": false                      // tombstone flag
}
```

Plus two folder-level files:

- `boards.json` — `{ "schema": 1, "boards": [ { "name": "Amazon prep",
  "createdAt": …, "updatedAt": … } ] }`. Boards are names (as on the Mac);
  the file exists so an *empty* board still syncs and board creation order
  is stable across devices. Renames are create + move-clips + delete in v1
  (no rename operation — keep the rule simple).
- `manifest.json` — `{ "schema": 1, "app": "ClipKeep", "createdBy": … }`.
  Clients refuse (politely, read-only) a folder whose manifest schema is
  newer than they understand. This is the schema-versioning seatbelt.

**Mapping from today's Mac model** (verified in `main.swift`, Nov 22):
`ClipItem` already has `id` (UUID string ✓), `createdAt` (Double ✓),
`pinned` ✓, `board` ✓, `sourceApp` / `sourceBundleID` ✓, `ocrText` ✓, and
`contentHash` (image dedupe — it becomes the content address). Links are
*not* a stored kind on the Mac (a link is a text clip + `linkTitle` /
`linkImageFile`); the mirror writer derives `kind: "link"` when the text
is a URL. What's missing is listed in §6.1.

### 5.3 Drive folder layout (v1 transport)

```
<user's Drive>/ClipKeep Sync/
  manifest.json
  boards.json
  clips/<id>.json            (one per clip, incl. tombstones)
  images/ab/ab12cd….png      (sha256, 2-char shard prefix)
```

The Mac writes this folder through the **Google Drive desktop app's local
folder** — the mirror writer (§6.1) writes plain files to a local path and
Drive's own client uploads them. Zero Google API code, zero OAuth, on the
Mac. The phones use the Drive REST API (below). A visible folder (not
`appDataFolder`) is the pick: the user can see and nuke their sync data,
the web app can reach it with the same scope, and "your clips live in your
Drive" is the honest privacy story. Cost of the choice: the folder is
user-visible and user-movable — clients must find it by name/id search,
not by hardcoded path, and tolerate it being renamed (track the folder id
after first pick).

### 5.4 v1 sync from the RN side

- **Auth:** `expo-auth-session` Google OAuth (PKCE) with the
  **`drive.file` scope only** — it covers files the app created or the
  user picked, and it is a non-sensitive scope, so it avoids Google's
  restricted-scope verification process entirely. Refresh token in
  `expo-secure-store`. One Google Cloud project hosts the OAuth clients
  for Android, iOS, and (later) web — one identity for the ecosystem.
- **First run:** find-or-create "ClipKeep Sync" (search by name + the
  manifest), let the user pick the existing folder if the Mac got there
  first (Drive Picker / folder list), store the folder id in MMKV.
- **Pull:** Drive `changes.list` with a stored page token (cursor in
  MMKV) scoped to the folder's descendants; cheap fallback: list
  `clips/` with `modifiedTime > cursor`. Downloads land in SQLite +
  file store; `updatedAt` comparison decides acceptance (LWW).
- **Push:** a `sync_outbox` table in SQLite — every local mutation
  (create/pin/board/delete/OCR-arrival) enqueues the clip id; the sync
  runner uploads the clip JSON (and image file first, if new), then
  clears the row. Idempotent by construction: re-uploading the same file
  is a no-op result. Runs on foreground, after mutations (debounced),
  pull-to-refresh, and in the background task (§3f).
- **Conflicts:** same clip edited on two devices while offline → the
  later `updatedAt` wins wholesale (no field merge). Acceptable for
  clipboard data; the loser is almost always a pin toggle.
- **Images:** upload/download lazily — metadata first (the tile can
  render), full image on first detail open, thumbnail generated locally
  after download and cached. This keeps first sync fast on a history
  full of screenshots.

### 5.5 How ClipKeep Web joins

The web app speaks the same schema; the only question is transport.

- **Possible in v1:** a browser Drive client — Google Identity Services
  token flow + Drive REST from JS, reading/writing the same folder. The
  schema makes it a peer, not a second-class citizen.
- **Recommendation: join fully at v2, read-only before that if wanted.**
  The web app's current shape (Library app, manual capture, its own
  store) makes it the weakest v1 client: browser OAuth in its sandboxed
  runtime is the fiddliest of the four, and its usage (occasional manual
  saves) doesn't need realtime parity. Pragmatic v1: web keeps manual
  capture and gains a **"export to sync folder"** (download/upload of
  schema files) only if Femi wants it. At v2, the backend gives all four
  clients one API and the web app becomes a first-class sync client with
  no Drive code at all.

### 5.6 v2 backend, reframed for RN — does Firestore change the balance?

Short answer: **somewhat — Firebase moves from co-equal to slight
favourite, and the decision stays deferrable.**

- **Firestore via React Native Firebase** is the only candidate whose
  offline sync engine is *native*: `@react-native-firebase/firestore`
  (v26/v27, Oct 2026) wraps the native iOS/Android Firebase SDKs —
  offline persistence, snapshot listeners, and background behaviour come
  from the same native code native apps use, and v26+ is
  New-Architecture-native and tested against Expo 58 / RN 0.88
  ([RNFirebase v26 release notes, Oct 2026](https://newreleases.io/project/github/invertase/react-native-firebase/release/v26.0.0);
  [rnfirebase.io, Nov 2026](https://rnfirebase.io/)).
  Under RN that erases most of the "you still have to build sync"
  objection from MOBILE-RESEARCH §7 — for the phone clients. The Mac
  still needs a Firestore client (REST or the gRPC API from Swift —
  real work, and the least pleasant of the three Mac-side integrations).
- **Supabase from RN** is the JS client (PostgREST + Realtime): clean and
  familiar (Postgres — his strength), but *no built-in offline cache* —
  the local SQLite store and outbox from v1 remain the offline layer and
  Supabase becomes a transport for them. That's fine — v1 already builds
  exactly that layer — but it means Supabase's v2 win is "least new code
  on the server side", not "sync for free".
- **AWS (Cognito + API Gateway + Lambda(TS) + DynamoDB + S3)** from RN is
  hand-rolled REST against the same outbox — no SDK magic, no magic
  missing either; Lambda in TypeScript stays a genuine plus for him, and
  the May 2027 free-plan cliff (MOBILE-RESEARCH §6.6) stays a genuine
  minus for starting there.
- **Net:** if v2's driver is *realtime + offline-done-for-you on phones*,
  pick Firebase and budget the Mac-side REST client. If the driver is
  *least operational novelty*, pick Supabase and keep the v1 sync engine.
  Either way the §5.2 schema and the transport interface mean **Phase 1–2
  code doesn't change** — which is why this decision is explicitly a
  Phase 3 gate, not a now decision.

### 5.7 E2EE — where it slots in

Encryption lives **in the mirror layer, above the transport**: each
client encrypts a clip's payload fields (`text`, `linkTitle`, `ocrText`,
and image bytes) with a per-profile key (XChaCha20-Poly1305 via libsodium
— available to RN, Swift, and web) *before* the sync writer sees them,
and decrypts after the sync reader returns them. Routing metadata (`id`,
`kind`, `createdAt`, `updatedAt`, `pinned`, `board`, `deleted`) stays
plaintext so LWW and tombstones keep working on any transport, Drive
included. The key derives from the profile passphrase (Argon2id) and is
wrapped per device; devices without the key see the folder as opaque
ciphertext. Because the seam is the mirror layer, E2EE can land in v1.5
on Drive or with the v2 backend, unchanged — it is not a transport
feature and must not be built as one (the §6.3 rule from the earlier
research, restated).

---

## 6. Mac-side readiness — before mobile development starts

Mobile Phase 1 cannot start until the Mac produces the §5 format. This is
the critical path, and it's Mac work, in Swift, in the existing app.

### 6.1 The sync mirror writer (+ importer)

A new `SyncMirror` component in the Mac app:

- **Watches** `ClipStore` the way `save()` already does (debounced
  snapshot on the existing save queue) and diffs against what it last
  wrote.
- **Writes** per-clip JSON (§5.2) + `boards.json` + `manifest.json` into
  the sync folder (a user-chosen local folder — normally inside the
  Google Drive desktop folder, §5.3), and copies image files to their
  content-addressed paths.
- **Imports** the other direction: scans the folder for clip files whose
  `updatedAt` beats the local copy (or that are locally unknown), applies
  them to `ClipStore` (inserts, pin/board updates, tombstone deletes),
  and pulls referenced images into the local `images/` folder.
- Loop safety: imports don't re-trigger exports (mark sync-originated
  mutations), and the content hash makes image copies idempotent.

### 6.2 Model gaps to close (verified against `main.swift`, Nov 22, 2026)

| Gap | Today | Fix (mirror layer, minimal ClipItem change) |
|---|---|---|
| No `updatedAt` | Only `createdAt` exists | Add `updatedAt: Double` to `ClipItem`; set at creation, touch on pin/board/delete/OCR-arrival. Old history decodes with `updatedAt = createdAt` (the v2-fields precedent in the model shows how) |
| No tombstones | Deletes are erasures | ClipStore keeps a `tombstones: [id: deletedAt]` sidecar (persisted JSON next to history.json), pruned at 90 days; the mirror emits `deleted: true` files from it |
| No origin device | — | Generate a per-install `deviceId` (UUID in UserDefaults) + constant platform `"macos"`; mirror stamps both |
| No schema version | — | `syncSchemaVersion = 1` constant; stamped in every clip file + `manifest.json` |
| Links aren't a kind | Link = text + `linkTitle` etc. | Mirror derives `kind: "link"` when text parses as a URL; on import, maps back to a text clip with link fields (lossless for the Mac) |
| Image names are random | `imageFile` = `UUID().png`; `contentHash` exists separately | Mirror publishes images under `sha256` (reuse `contentHash`; compute when absent). Local storage layout unchanged |
| Boards live in UserDefaults | `boards: [String]` in defaults | Mirror exports `boards.json` from it; imports merge board lists (union, by name) |
| Settings that must NOT sync | `excludedApps`, `historyLimit` are per-device | Explicitly excluded from the mirror — phone exclusion lists and limits are the phone's own |

### 6.3 The rest of the Mac checklist

- **Sync toggle in Settings** (new "Sync" tab or a General section):
  off by default (sync is opt-in — the profile rule from the earlier
  research), folder picker, status line ("Last synced … · N clips"),
  and plain-language privacy copy: what is mirrored, that sensitive
  copies are never mirrored, and that turning sync off stops writing
  (plus a "remove sync data" button that deletes the folder's ClipKeep
  files). No account, no sign-in on the Mac in v1 — the Drive folder
  *is* the identity.
- **History-limit interplay:** `trim()` currently deletes outright.
  Under sync, a trim must write tombstones or other devices resurrect
  the clips. Rule: trims tombstone like deletes do (90-day retention
  covers it); keepers (pinned/boarded) stay exempt, as today. Imported
  clips count toward the local limit exactly like native ones.
- **The Nov 21 Accessibility/TCC lesson:** nothing blocking. That saga
  was about *paste injection* — mobile never injects pastes, and the
  mirror needs no new macOS permission (it writes to a folder the user
  picks, inside storage the user already syncs). The only carry-over is
  a testing one: the Mac's paste features and the mirror are independent
  code paths, so mirror work can't regress the confirmed v2.16.5 paste
  behaviour — keep it that way (mirror observes the store; it never
  touches the pasteboard).

### 6.4 Development-machine & account readiness

| Item | State / action |
|---|---|
| Xcode | Install current (27.x for the iOS 27 SDK; RNFirebase v27 wants ≥ 26.2) — needed from Phase 2, and for iOS simulator work generally |
| Android Studio + SDK | Current studio, SDK 36 platform + S23+ USB debugging — Phase 1 |
| Node / JDK | Node 22.13+ (SDK 58's floor; 24 also fine), JDK 17 for Android builds |
| Expo account + EAS CLI | Free account; `eas init` in the new repo |
| Google Play Console | $25 one-time — before Phase 1 store builds (sideload/dev builds don't need it) |
| Apple Developer Program | $99/yr — **enrol before Phase 2**: App Groups (share extension hand-off) and TestFlight both effectively require the paid team |
| Google Cloud project | One project: OAuth clients (Android/iOS/web) for Drive `drive.file` scope |
| Test devices | Android: the S23+ (real, daily). iOS: **no iPhone** — simulator for UI (with the §3e Vision choice keeping OCR testable), **Firebase Test Lab** free daily quota (physical devices) for share/paste/background behaviour the simulator can't prove, **AWS Device Farm** trial minutes as overflow — spend them before the AWS credits expire **May 19, 2027** |


---

## 7. Effort re-estimate under RN + phased plan

Baseline (MOBILE-RESEARCH §4, native route): Android MVP ~3–5 weeks,
iOS MVP ~2–4 weeks *as a second native codebase*, both part-time, MVP =
sync viewer + share-to-save + tap-to-capture + search/pins/copy-back on
Drive sync. RN changes the shape, not the physics: the OS limits and the
native escape hatches are identical; what RN removes is the *second*
implementation of everything else.

| Phase | Scope | RN estimate (part-time) | vs native |
|---|---|---|---|
| **0 — Mac mirror** | §6.1–6.3: mirror writer/importer, model gaps, sync toggle, Drive folder live | **~1 week** (the "few days" of §3, plus the importer + tombstones done properly) | Identical — framework-independent |
| **1 — Android MVP** | Expo scaffold, C UI (grid/detail/boards/search), expo-sqlite store + FTS, Drive sync client + outbox, share-to-save (library), capture button, QS tile (local module), OCR module (Android half), background task, Play internal testing | **~4–6 weeks** | Native was 3–5 for a *plainer* UI; C's grid + the RN native pieces put RN at parity-to-slightly-more for platform #1 — the win is below |
| **2 — iOS** | Same codebase: share extension via the same library, UIPasteControl module + App Intent (§3c), OCR module (Vision half), iOS sync verification, TestFlight + App Store, Test Lab/Device Farm device passes | **~1.5–3 weeks** | Native was 2–4 weeks for a *rewrite in Swift*; here it's platform deltas + store work only |
| **3 — v2 gate** | Decide Firebase vs Supabase vs AWS (§5.6), implement backend transport behind the existing interface, profiles + E2EE (§5.7), web app joins as a full client (§5.5) | **~2–3 weeks** when taken | Same either way |

**Totals:** both phone platforms ≈ **5.5–9 weeks** part-time under RN vs
≈ 5–9 weeks native — a wash on the calendar for v1. The RN dividend is
everything after: one codebase, one bug fix, one OTA channel (§2.5) for
both phones forever, in the developer's strongest language. The honest
RN cost: the §3 native pieces are *less* trodden in Expo-land than in
native-land (the QS tile is the clearest case), so Phase 1 carries a
small spike risk the native route didn't.

### Phased plan (sequence)

0. **Phase 0 — Mac mirror first.** Nothing else can be tested end-to-end
   without it, it's useful alone (Drive backup of history), and it pins
   the schema with a real producer. Exit test: hand-edit a clip file in
   the folder on the phone's Drive app → it appears in the Mac panel.
1. **Phase 1 — Android MVP** on the S23+, Play internal track. Exit test:
   copy on Mac → tile on phone → copy-back → paste on phone; share from
   Chrome Android → clip on Mac; QS tile save works with the app closed.
2. **Phase 2 — iOS** deltas + TestFlight, device-verified via Test Lab /
   Device Farm. Exit test: the same three flows on a physical iPhone
   (borrowed from a test service, not a simulator).
3. **Phase 3 — v2 gate.** Only if Drive sync's latency/eventual
   consistency actually chafes in daily use. Decide with §5.6, implement
   behind the transport interface, bring the web app in as a peer.

---

## 8. Risks & open questions (RN route)

**Risks**

- **Single-maintainer libraries on the critical path.** `expo-share-intent`
  is the standard, but it is one maintainer between Femi and a hand-rolled
  share extension. Mitigation: pin versions, keep the prebuild output
  reviewable, and note the vendoring fallback (§3a). Same class of risk,
  smaller: `expo-invoke` (rejected as a dependency for the tile, §3b).
- **SDK churn tax.** Expo shipped SDKs 55–58 in ~13 months, and each
  boundary has broken things for adjacent ecosystems (RNFirebase needed
  config fixes at 53/54/55). Budget a half-day per SDK upgrade, stay on
  the current SDK at phase starts rather than chasing mid-phase, and let
  EAS's managed versions do their job.
- **The features the simulator can't prove are exactly the native ones.**
  Share sheet behaviour, the paste-prompt rules, background tasks, and
  the QS tile all need physical devices. With no iPhone in the house,
  Phase 2's verification leans entirely on Firebase Test Lab's free
  quota and AWS Device Farm minutes — schedule them, don't discover
  them. (Android is fine: the S23+ is the test device.)
- **Samsung-specific behaviour.** One UI's QS panel, its clipboard toast,
  and its aggressive background app killing all differ from Pixel
  Android. The S23+ *is* the target, so this is a testing instruction,
  not a surprise: every sync/capture claim gets verified on the Samsung,
  not the emulator.
- **EAS Free queue latency** (documented 90+ min at peak) can stall a
  build-test loop. Mitigation: local builds on the MacBook Air are
  first-class (`expo run:*`, `eas build --local`); treat cloud builds
  as the release path, not the iteration path.
- **Drive scope discipline.** Staying on `drive.file` avoids Google's
  verification regime; the moment a feature wants broader Drive access
  (e.g. browsing arbitrary folders), the project inherits a security
  review. Treat any such feature request as a red flag, not a scope
  change.
- **OCR text will differ slightly by platform** (Vision on Mac/iOS,
  ML Kit on Android). Search tolerates it; don't promise identical
  OCR in store copy or to users comparing devices.

**Open questions for Femi**

1. **Folder name & visibility:** "ClipKeep Sync" as a visible Drive
   folder (§5.3) — fine, or should the phones use `appDataFolder`
   (invisible, tidier, but the Mac's desktop-folder trick no longer
   works and the Mac needs real Drive API code)? Recommendation stands
   with visible; flagging because it's the one v1 choice that's awkward
   to reverse after data exists.
2. **Colour tile tap behaviour** (§1.2): tap = detail (consistent) vs
   tap = copy hex (fast). Mockups don't decide it.
3. **Capture while inside a board** (§1.1): file to All (recommended) vs
   file to the open board.
4. **Web app's v1 ambition:** export-only stopgap (§5.5) vs a real
   read-only Drive viewer in the browser during Phase 1. Recommendation:
   stopgap; the browser client is Phase 3 work wearing a v1 costume.
5. **Apple Developer enrolment timing:** Phase 2 needs it; enrolling
   earlier (during Phase 1) removes a silly blocker if iOS appetite
   arrives ahead of schedule. $99/yr either way.

---

### Sources consulted (Nov 22, 2026)

- Expo SDK 58 changelog (RN 0.88, iOS 27, Oct 15, 2026) — expo.dev.
- `expo-share-intent` v9 (SDK-version matrix, share model) — npm.io.
- `expo-sharing` receive support (experimental, config plugin) — Expo docs, SDK 55.
- FlashList v2 (New-Architecture rewrite, no `estimatedItemSize`, masonry)
  — 2026 RN performance guides (codezup.com; devico.io).
- WatermelonDB status (0.28.0, Apr 2025; New-Architecture untested; Expo
  plugin stale) — dev.to SDK 54 guide; NitromelonDB fork — GitHub.
- expo-sqlite (FTS5, SQLCipher, kv-store) & react-native-mmkv v4 —
  offline-storage survey, Aug 2026 (rasd.khreshitech.solutions).
- Expo services pricing (Free 15+15 builds, 1,000 update MAU cap; Starter
  $19) — superapp.dev, Nov 10, 2026; dev.to EAS Update analysis, Nov 18, 2026.
- `expo-background-task` (WorkManager / BGTaskScheduler, 15-min floor,
  force-quit rule) — background-work survey, folio.gurgul.pro, 2026.
- Quick Settings `TileService` mechanics — developer.android.com;
  `expo-invoke` v3.1.5 (generated tile) — npm.io.
- ML Kit OCR in RN (`vision-camera-ocr-plugin` 5.0.12;
  `react-native-vision-camera-mlkit` 2.0.1 static-image API; ML Kit iOS
  arm64-simulator gap) — npm.io package pages, Oct 2026.
- React Native Firebase v26/v27 (New Architecture required, Expo 58
  tested, native Firestore) — newreleases.io, Oct 2026; rnfirebase.io.
- Mac model facts — `main.swift` in this repo (ClipItem, ClipStore),
  read Nov 22, 2026.


---

## Decision addendum — Nov 22, 2026 (backend)

Femi's call, made the evening this research landed: **the backend is AWS**
(Cognito + API Gateway + Lambda (TypeScript) + DynamoDB + S3), chosen over
Firebase on cost. The deciding facts: the AWS always-free tiers (Lambda
1M requests/mo, DynamoDB 25 GB, Cognito, S3 at pennies) run at ≈ $0 and —
unlike the $100 credits expiring May 19, 2027 — do not lapse. Firebase's
Firestore sync engine remains the better *engineering* shortcut (it was this
document's slight favourite on those grounds), so the accepted trade is
explicit: **the sync layer (delta pull, conflict resolution, retry queue) is
hand-rolled on the AWS side**, on all three clients, behind the same
transport interface §5 specifies. Amplify stays ruled out (Gen 1 offline
sync dies May 1, 2027; Gen 2 dropped it) — the AWS build uses the raw
services, not Amplify. Still open at the time of the decision: whether
Google Drive still serves as the v1 transport with AWS arriving at the
Phase 3 gate, or AWS is the transport from the start (which front-loads the
sync-engineering into the MVP).


## Decision addendum 2 — Nov 22, 2026 (sequencing + Mac accounts)

The open question in the addendum above is resolved: **AWS from the start.**
Google Drive is dropped as the v1 transport — no throwaway adapter, no
migration. Femi also approved **integrating an account system into the Mac
app**: Cognito-backed, opt-in — signed-out, the Mac app remains exactly the
local-only app it is today; signing in turns on sync and makes the account
the single identity across Mac + iOS + Android + ClipKeep Web. Consequences
folded into Phase 0: Mac Settings gains an account/sync surface (sign in/out,
sync toggle, account email); tokens live in the macOS Keychain; the Mac
talks to Cognito over plain HTTPS (no heavyweight SDK in the menu-bar app).
Pre-launch checklist gains: in-app account deletion (required by Apple for
the iOS app; mirrored on Mac) and a privacy-policy section covering accounts
and server-side clip storage. The README's framing adjusts from "account-free"
to "no account needed unless you turn on sync" — same promise, accurate words.
