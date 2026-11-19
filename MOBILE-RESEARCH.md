# ClipKeep Mobile — Feasibility Research

Researched Tue Nov 17, 2026, at Femi's request ("begin looking into this in the background").
Scope: whether ClipKeep — the macOS menu-bar clipboard manager (native Swift/AppKit,
repo `femisowems/clipkeep`) — can have a mobile version, what shape it would take on
iOS and Android, how it would sync with the Mac app, and what it would cost to build.

**The one-sentence answer:** a mobile ClipKeep is viable on both platforms, but it
cannot be the Mac app ported. Both mobile OSes have spent six years deliberately
killing passive clipboard capture. The mobile product is a *sync companion plus
deliberate capture* (share sheet, tap-to-save, keyboard), not a background recorder.
Android should go first — it's Femi's daily phone (Galaxy S23+), and Android allows
a slightly richer capture story than iOS.

Platform facts below were verified against current (Oct–Nov 2026) sources: Apple's
UIPasteboard / UIPasteControl documentation as summarized in recent developer
guides, Google's "Secure Clipboard Handling" page on developer.android.com, the
OWASP MASTG pasteboard entry, and Google Play policy trackers current to late 2026.

---

## 1. Clipboard access limits — can a mobile app passively capture copies?

**No — on either platform. This is the central constraint and it shapes everything else.**

### iOS

- **Foreground only, and only since iOS 9.** Pasteboard access has been restricted
  to foreground apps for a decade; there is no background clipboard listener. The
  `UIPasteboard.changedNotification` exists, but it only fires reliably while your
  app is in the foreground — so it tells you the clipboard changed *while you were
  already looking*, which is useless for passive history.
- **iOS 14: the paste banner.** When an app reads general-pasteboard content that
  was copied in a *different* app without established user intent, the system shows
  the user a "pasted from …" notification. Silent reads became visible reads.
- **iOS 16: the permission alert.** Programmatic paste (reading the value without a
  user gesture) now raises an approval alert — "X would like to paste from Y" —
  which the user can refuse. iOS 16.1 added a per-app Settings row ("Paste from
  Other Apps": Ask / Deny / Allow). There is no entitlement or Info.plist key that
  opts an app out of this.
- **What does *not* trigger the alert:** metadata checks — `hasStrings`, `hasImages`,
  `hasURLs`, `types`, and `detectPatterns(for:)` (probable web URL, number, search
  query). You can quietly ask "*is* there a URL?" but reading the URL itself needs
  the gesture. The sanctioned no-prompt path is a user tap: the system **Paste**
  menu item or a `UIPasteControl` button, which *is* the user's intent.
- **Universal Clipboard is not an API.** Copy on iPhone → paste on Mac works via
  Continuity/Handoff (same Apple Account, Wi-Fi + Bluetooth on, devices within
  ~10 m), but it carries exactly **one** item, keeps it for roughly two minutes,
  and exposes nothing to third-party apps — a ClipKeep iOS app cannot observe,
  enumerate, or extend it. It also doesn't exist for Android at all.
- **Consequence:** an iOS ClipKeep can never see a copy it didn't ask for. Every
  clip enters through a deliberate user action (see §2).

### Android

- **Android 10 (2019): background access closed.** Google's rule, verbatim in
  effect: unless your app is the **default input method editor (IME)** or the app
  that **currently has focus**, it cannot access clipboard data. An
  `OnPrimaryClipChangedListener` still fires in the background, but reads return
  empty — the notification without the content.
- **Android 12: the toast.** First time an app reads a clip copied by another app,
  the system shows "*App* pasted from your clipboard." Reads are user-visible.
- **Android 13: preview + hygiene.** Copying shows a system preview overlay;
  content flagged sensitive (`ClipDescription.EXTRA_IS_SENSITIVE`) is masked in
  previews; and the system **auto-clears the clipboard after about an hour** —
  which is also why Gboard/Samsung Keyboard histories expire unpinned clips.
  Clipboard history on modern Android lives in the keyboard (Gboard, Samsung
  Keyboard) precisely because the IME is the exempt app.
- **Android 14/15:** foreground services need declared types and Play
  declarations; none of this re-opens background clipboard reads. A foreground
  service does **not** regain clipboard access — focus or IME status is what
  counts, not process liveness.
- **The "workarounds" and why they're not a product:**
  - *Accessibility service:* some clipboard apps historically abused accessibility
    to regain focus/read content. Google Play's Accessibility API policy restricts
    the API to apps whose purpose is assisting users with disabilities
    (`isAccessibilityTool`), with a declaration + disclosure + demo-video regime
    for everyone else; an Oct 2025 policy update (enforcement ~Jan 28, 2026)
    tightened this further, and Android 17's Advanced Protection Mode reportedly
    restricts non-accessibility-tool use at OS level. Building ClipKeep on this is
    building on a policy trapdoor — **avoid**.
  - *ADB / READ_LOGS tricks:* older managers (Clipper-era) read clipboard events
    from logcat after a manual `adb` grant. Not shippable: requires a computer,
    breaks across versions, and Play would never accept it as the mechanism.
  - *Automation apps (Tasker/Automate) and notification listeners:* fragile,
    user-hostile, and outside anything a store listing can promise.
  - *Root / Shizuku:* power-user only; not a product.
- **What *is* legitimate on Android:** reading the clipboard while your app is in
  the foreground (including an activity summoned by a Quick Settings tile or a
  floating button — the tap *is* the capture), being a share target, and being
  the keyboard (IME). See §2.

### The asymmetry that matters

The Mac app polls `NSPasteboard` every 0.5 s and nobody asks permission. Neither
phone OS will ever grant a third-party app that capability again — both vendors
treat the clipboard as a top-tier exfiltration channel (passwords, 2FA codes,
crypto addresses). Any mobile design that starts from "capture everything" is
dead on arrival; every successful mobile clipboard product (Gboard's history,
Paste's iOS app, ClipboardKeyboard, Clipper) is built on the deliberate-capture
routes below.

---

## 2. Viable product shapes

### Android (the richer platform for this)

1. **Sync viewer (the core).** Browse, search, pin, and copy back the *Mac's*
   history — the history Femi actually accumulates all day — plus anything saved
   on the phone. Copy-back is a clipboard *write*, which neither platform
   restricts or reports. This alone justifies the app: "my Mac clipboard, in my
   pocket."
2. **Share-to-save.** Register as a share target (`ACTION_SEND` / `ACTION_SEND_MULTIPLE`):
   from any app, Share → ClipKeep saves text/links/images into history. Zero
   permission friction, works from every app that has a Share button. This is
   the primary on-phone capture route.
3. **Tap-to-capture.** A "Save current clipboard" button in-app, plus a **Quick
   Settings tile** (and optionally a home-screen widget button): one tap brings
   ClipKeep to the foreground, where reading the clipboard is allowed, and saves
   the current clip. One toast may appear the first time per source app (Android
   12+) — acceptable, and honest.
4. **Later, if ever: a keyboard.** An IME is the only app class that can watch
   copies continuously, and a ClipKeep keyboard could offer a history strip like
   Gboard's. But it means asking Femi to *replace Samsung Keyboard/Gboard as his
   daily keyboard* — a big trust ask, a large build (a good keyboard is a product
   by itself), and it competes with two free, excellent incumbents. **Not v1.**
   Revisit only if the companion proves itself and he wants phone-native history.
5. **Push to Mac.** Clips saved on the phone write into the same sync store; the
   Mac app imports them, so phone → Mac works as well as Mac → phone (see §3).

### iOS (a later, narrower version)

1. **Sync viewer** — identical concept: Mac history, search, pins, copy-back.
2. **Share extension.** The canonical iOS capture route: select text / a link /
   an image anywhere → Share → ClipKeep. This is how every serious iOS clipboard
   app (e.g. Paste, ClipboardKeyboard) takes input.
3. **Tap-to-capture via UIPasteControl.** A system paste button in the app reads
   the clipboard with no permission alert, because the tap is the consent. Plus
   an App Intent / Shortcuts action ("Save clipboard to ClipKeep") the user can
   put on a home screen or Action button — user-invoked, so policy-clean.
4. **Keyboard extension (optional, later).** With "Allow Full Access" a custom
   keyboard can read the shared App Group store and the pasteboard, and shipped
   clipboard keyboards do exactly this. Costs: the scary system warning sheet
   ("everything you type can be transmitted"), no access in secure fields or
   apps that refuse custom keyboards, and again — it's a whole keyboard to
   build and maintain. A *paste-only* mini keyboard (a clips strip over a basic
   key row) is more plausible than a full typing keyboard, but still not v1.
5. **What iOS can't do:** widgets that silently read the clipboard (reads from
   extensions hit the same prompt rules), background change detection, and
   anything involving Universal Clipboard beyond what the OS does by itself.

### Feature parity reality check

| Mac ClipKeep feature | Android | iOS |
|---|---|---|
| Passive capture of everything | ✗ (share / tap only) | ✗ (share / tap only) |
| Full history, search, pins, boards | ✓ via sync | ✓ via sync |
| Text / link / colour clips | ✓ | ✓ |
| Image clips | ✓ via sync + share | ✓ via sync + share |
| File clips | View/download only | View/download only |
| OCR search of image text | ✓ (ML Kit, on-device) | ✓ (Vision — same framework as Mac) |
| Paste Stack, ⌘1–9 quick paste | ✗ (no system paste injection) | ✗ |
| Source-app attribution | Mac clips only (phone saves are "shared from X") | Mac clips only |

Phone-saved clips can record the sharing app where the platform provides it
(Android share intents often carry the caller; iOS share extensions get limited
context) — good enough for the source-app field.

---

## 3. Sync options (Mac app ⇄ phone)

Today the Mac app is a local JSON file (`history.json`) + an `images/` folder.
Any option below starts with the same Mac-side step: a small "sync mirror" writer
that emits the history in a stable, versioned format (one JSON per clip or a
single versioned JSON + content-addressed image files), plus tombstones for
deletes. That work is needed regardless of transport, and it's small.

### Option A — Shared folder (Google Drive) — *recommended for v1*

- **How:** the Mac app mirrors into a "ClipKeep" folder in Google Drive (Femi
  already lives on Drive); the Android app reads/writes the same folder via the
  Drive API (appDataFolder or a visible folder). Phone saves land in the folder;
  the Mac app watches/imports.
- **Why Drive and not iCloud Drive:** there is no iCloud Drive client or API on
  Android. Drive is the only folder both a Mac and a Galaxy actually share.
  (Dropbox would also work; Femi's accounts point to Drive.)
- **Effort:** lowest of the real options. Mac side ≈ a few days (mirror writer +
  importer + conflict rule). Mobile side ≈ a week (OAuth, Drive REST, local
  cache). No server to run, no accounts system — the user's Drive *is* the
  account, and clipboard data stays in the user's own storage, which is the
  right privacy story for clipboard content.
- **Trade-offs:** sync is eventually-consistent (seconds to minutes, Drive-paced,
  not realtime push); conflict handling must be deliberately simple
  (per-clip files + last-writer-wins + tombstones beats one big JSON file);
  image clips make the folder grow — needs the same history-limit discipline
  the Mac app already has; offline edits queue naturally since it's file-based.

### Option B — CloudKit / iCloud — *rejected*

- Best-in-class for Mac ⇄ iPhone (free, no backend, SwiftData/Core Data
  mirroring) — and a **dead end for Android**: CloudKit has no native Android
  support at all; the only bridges are CloudKit Web Services through a custom
  server layer, which Apple positions for web, not for shipping an Android
  client. Since the first phone is Android, choosing CloudKit now would mean
  re-platforming sync later. Only reconsider if the plan flips to iPhone-first.

### Option C — Small backend / BaaS (Supabase or Firebase) — *the v2 path*

- **How:** Mac app and phone both sync to Supabase (Postgres + storage buckets
  for images; Femi already knows Postgres) or Firestore (realtime listeners,
  offline cache). Auth via a simple account or a device-pairing token.
- **Effort:** medium. ≈ 1–2 weeks beyond Option A: schema, auth, storage for
  image blobs, conflict/merge logic, and a Mac-side sync client. Running cost
  on free tiers is effectively $0 at personal scale.
- **Trade-offs:** realtime (a copy on the Mac appears on the phone in seconds,
  pushable via FCM/APNs), one sync design serves Android + iOS + the existing
  ClipKeep Web app — but now Femi operates a service holding *clipboard data*,
  among the most sensitive data classes there is. That demands client-side
  encryption of clip payloads (encrypt before upload, keys on devices) to keep
  the privacy story honest, which adds real complexity. Worth it when/if
  realtime matters; overkill for v1.

### Option D — Local-network sync (KDE Connect style) — *not recommended*

- No cloud at all: devices pair over Wi-Fi and exchange history directly.
  Cheapest privacy story, most protocol work (discovery, pairing, TLS,
  resumable transfer), and sync only happens when both devices are awake on
  the same network — which fails the actual use case ("copied at my desk,
  need it on the train").

### Sync recommendation

Build the **mirror format + Option A (Drive folder)** for v1, behind a thin
transport interface in both apps, so Option C can replace the transport later
without touching the data model. Also carry over the Mac app's existing privacy
rule — clips from concealed/transient pasteboard types (password managers'
copies) are never captured on the Mac, and phone saves should honour Android's
`EXTRA_IS_SENSITIVE` flag and iOS's concealed type the same way: what's
sensitive on one device must not become synced plaintext on another.

---

## 4. Build approach and rough effort

Key insight first: **the OS limits are identical under every framework.**
Share extensions, keyboard extensions, Quick Settings tiles, and paste
controls are native code no matter what — the framework choice only decides
how the (simple) list/search/detail UI gets built. ClipKeep's UI is a
searchable list of cards; that's a weekend of UI in any stack. The estimates
below are for one developer (Femi), part-time pace, MVP = sync viewer +
share-to-save + tap-to-capture + search/pins/copy-back, reusing the §3
Option A sync.

| Route | Android MVP | iOS MVP (later) | Notes |
|---|---|---|---|
| **Native** (Kotlin/Compose · Swift/SwiftUI) | ~3–5 weeks | ~2–4 weeks | Extensions are first-class; no bridge friction. Swift side reuses Femi's Mac-app Swift and even code (ClipItem model, colour parsing, sync mirror). Kotlin/Compose is new to him but adjacent to his TypeScript/Java-style experience. Two codebases to maintain. |
| **React Native / Expo** | ~3–5 weeks | ~3–5 weeks | Plays to his strongest stack (React/TS) for the UI, and one UI codebase serves both phones. But every differentiating feature — share target/extension, QS tile, keyboard — is a native module or app extension; with Expo that means config plugins / native targets and ejecting from the happiest path, which eats the savings and adds a class of build friction he's hit before with native tooling. |
| **Flutter** | ~4–6 weeks | ~4–6 weeks | One codebase, good UI velocity once running — but Dart is a third language in his stack, extensions are still native Swift/Kotlin, and nothing from the Mac app or his React work carries over. Weakest fit for *this* developer. |
| **Kotlin Multiplatform** (shared model/sync, native UI) | ~4–6 weeks | ~4–6 weeks | Shares exactly the parts worth sharing (ClipItem model, Drive sync, merge logic) and keeps UI/extensions native. Attractive end-state, but the setup/tooling tax is real for a first mobile project, and iOS KMP tooling still lags the Android side. A v2 refactor candidate, not a starting point. |

For calibration: the Mac app shipped 13 releases in four days because it was
one file, one platform, and no store review. Mobile adds store accounts,
review cycles (Play: days; App Store: days plus a real chance of a
clipboard/keyboard-related rejection conversation), and device testing.
Budget the calendar accordingly — these estimates are effort, not elapsed
time, and review latency sits on top.

Also budget the unglamorous line items: Google Play developer account ($25
one-time) and Apple Developer Program ($99/yr) if/when iOS ships; a privacy
policy page (both stores require one, and a clipboard app will be read
closely); Play's data-safety form and Apple's privacy nutrition labels —
for a clipboard app these are substantive, not boilerplate.

---

## 5. Recommendation

**Platform first: Android.** Femi's daily phone is the Galaxy S23+, so the
companion gets used (and tested) every day; Android's share-target +
foreground-capture rules allow a genuinely useful capture story without
policy games; and Play's review path for this app shape is well-trodden.
iOS comes second, reusing the sync design and the Swift he already writes.

**The MVP (Android, native Kotlin):**

1. **Sync viewer of the Mac history** over a Google Drive folder (Mac-side
   mirror writer first — it's the long pole and it also de-risks everything
   after it). Search, type filters, pins, copy-back.
2. **Share-to-save** from any app (text, links, images).
3. **Tap-to-capture**: in-app "Save current clipboard" + a Quick Settings tile.
4. **Phone → Mac**: phone saves flow back through the same folder and appear
   in the Mac panel.
5. Honour sensitive-content flags; keep the Mac's history limits.

That's a coherent product — "ClipKeep everywhere, captured deliberately" —
in roughly a month of part-time effort, with no backend to operate.

**Then:** iOS native Swift version (share extension + `UIPasteControl`
capture + Shortcuts action) on the same Drive sync; evaluate Supabase with
client-side encryption only if realtime sync starts to feel necessary;
consider the Android keyboard or iOS paste-keyboard only after the
companions are boring and reliable.

**What to avoid — explicitly:**

- **Do not promise or attempt passive/background capture** on either
  platform, in code or in store copy. It's technically blocked, and
  claiming it invites rejection and bad reviews.
- **No accessibility-service hacks, no ADB/logcat tricks, no root routes.**
  Play policy (tightened Oct 2025, enforced from Jan 2026) makes these a
  when, not if, removal risk.
- **No CloudKit** while Android is in the picture — it's a sync dead end
  that would have to be ripped out.
- **No custom keyboard in v1** on either platform — it's a second product
  wearing a feature's clothes, with the scariest permission prompt in
  mobile attached.
- **No framework detour for its own sake:** React Native/Flutter don't
  change a single OS rule above; pick native Android now (Kotlin), native
  iOS later (Swift), and let KMP earn its way in only if maintaining two
  apps actually hurts.
- **Don't sync secrets:** password-manager copies and anything flagged
  sensitive stay off the sync store entirely, on every platform.

---

### Sources consulted (Nov 17, 2026)

- Google, "Secure Clipboard Handling" — developer.android.com (Android 10
  background restriction context, Android 12 toast, `EXTRA_IS_SENSITIVE`,
  Android 13 auto-clear).
- OWASP MASTG, "MASTG-KNOW-0083: Pasteboard" — iOS foreground-only access,
  iOS 14 notification, iOS 16 user-interaction requirement, `UIPasteControl`.
- Apple developer documentation (UIPasteboard, UIPasteControl, custom
  keyboard / RequestsOpenAccess) as summarized in Oct–Nov 2026 developer
  guides, including paste-permission behaviour on iOS 16+ and keyboard
  Full Access capabilities and limits.
- Apple Support, "Use Universal Clipboard…" (Feb 2026) — same-account,
  proximity, single-item, short-lived behaviour.
- Google Play Accessibility API policy coverage and policy trackers
  (Oct 2025 update, ~Jan 28 2026 enforcement) via Play policy summaries.
- 2026 storage/sync comparisons (CloudKit's lack of Android support;
  Firestore/Supabase as the cross-platform routes) from current developer
  references.
