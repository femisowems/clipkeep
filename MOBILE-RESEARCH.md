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

---

## AWS integration research — Nov 18, 2026

Researched Wed Nov 18, 2026, at Femi's request, the evening he opened an AWS
account (new AWS experience, Google sign-in; free plan, US$100 credits to start,
up to US$100 more earnable; CLI profile `starterdev`, region us-east-2). His
stated purpose for the account: testing his apps on cloud versions of macOS and
mobile devices. This section asks the follow-on questions: should the mobile
companion's sync/backend live on AWS instead of (or alongside) the §3 plan —
Drive folder for v1, Supabase + client-side encryption as the v2 path — what
would it cost, how do user profiles fit, and what is AWS Device Farm worth for
testing?

**The one-sentence answer:** AWS does not change the v1 plan — Drive still
ships the companion fastest, and Femi's AWS free plan hits a hard cliff in
May 2027 that makes it a poor foundation to build on right now — but AWS
becomes a co-equal candidate for the v2 backend (in one specific shape:
Cognito + API Gateway + Lambda + DynamoDB + S3, *not* Amplify), and it is
genuinely useful *today* for the thing he actually bought it for: Device Farm
test minutes and EC2 Mac clean-room sessions. Details and receipts below.

### 6.1 User profiles — the account model for sync

Everything in this section hangs on one product decision, so it gets treated
first: **what is a "user" in ClipKeep sync?**

- **Today the Mac app is account-free, and it stays that way by default.**
  No sign-up, no sign-in, local history only. That is a feature of the
  current product, not a gap. Sync — on any backend — must be **opt-in**:
  the app works fully without a profile, forever.
- **A profile is the sync identity.** Creating a profile (or signing in) is
  the act that turns sync on. One profile spans every device: sign in with
  the same profile on the Mac and the phone and they see one history.
  Devices are interchangeable clients of the profile; there is no "primary
  device" concept and no pairing ceremony required (an optional device list
  / revoke screen is a later nicety, not a v1 need).
- **On AWS, a profile is a Cognito user-pool account.** Sign-up with email +
  password (passkeys and managed login pages exist on the Essentials tier),
  sign-in returns tokens, and the profile's Cognito `sub` becomes the
  partition key for everything that profile owns:
  - DynamoDB: partition key = `sub` (one user's clips are one partition).
  - S3: every object under `users/{identity-id}/…`, with an IAM policy
    variable (`${cognito-identity.amazonaws.com:sub}`) that restricts each
    signed-in identity to its own prefix — isolation enforced by AWS IAM,
    not by app code remembering to filter.
  - AppSync (if used): owner-based authorization rules keyed on the same
    `sub`.
- **What a profile buys beyond sync:** a durable identity that the future
  iOS app and the existing ClipKeep Web app can share; password reset /
  account recovery that Femi doesn't have to hand-roll; and — if ClipKeep
  ever goes public — a multi-user path that doesn't require re-architecting.
  This is the same property that made Supabase attractive in §3; Cognito
  matches it.
- **The honest trade-off vs the Drive plan:** with Drive (§3 Option A),
  identity is *borrowed* — the user's Google account is the account, and
  ClipKeep builds zero auth UI. With AWS (or Supabase), identity is *owned* —
  ClipKeep must ship sign-up, sign-in, and recovery flows and own the
  support burden when someone locks themselves out. Cognito's managed login
  shrinks that to hosted pages plus token handling, but it doesn't erase it.
- **Profiles are not a cost decision.** Cognito's always-free tier is
  10,000 monthly active users (Lite and Essentials tiers, per account, no
  expiry) — one profile or ten thousand cost the same $0. Above the free
  tier it's $0.015/MAU (Essentials) or $0.0055/MAU (Lite). Two pricing
  traps to note for later: new user pools default to the pricier Essentials
  tier, and *enterprise* SAML/OIDC federation gets only 50 free MAU
  (built-in social sign-in like Google counts under the 10,000).

### 6.2 The backend options, compared

Assumed workload, so the comparison has a scale: one user (later, a handful),
a few thousand clips at most (the Mac app already caps history), tens of sync
operations a day across two or three devices, image clips totalling a few GB
in the worst case. Every option below is technically capable of a thousand
times this; they differ in sync behaviour, encryption story, and how much
service Femi ends up operating.

#### Option AWS-A — S3 as the sync folder ("Drive pattern, on S3")

The §3 Option A design, transplanted: the Mac app and phone exchange
per-clip files, tombstones, and a manifest in a bucket, each device keeping
its local store as the source of truth.

- **Offline-first:** identical to Drive — because it *is* the Drive design.
  Local store first, sync is file exchange whenever connectivity exists,
  conflicts are per-clip last-writer-wins + tombstones. No new sync theory
  needed; the mirror format from §3 carries over unchanged.
- **Auth:** Cognito user pool (the profile) federated through a Cognito
  identity pool, which hands each device scoped AWS credentials limited to
  that profile's bucket prefix. No API to build at all.
- **E2EE:** encrypt each clip file on-device before upload (§6.3); S3 only
  ever holds ciphertext.
- **Operational burden:** the lowest of any AWS option — a bucket, two
  Cognito pools, one IAM policy. Nothing runs, nothing to patch.
- **Friction points:** delta discovery via S3 LIST is clunky (hence the
  manifest object — an index file each device updates, with the merge
  headaches that implies under concurrent edits); no realtime (sync on app
  open / foreground / interval); and the Mac app — currently dependency-free
  single-file Swift — must either adopt the AWS SDK for Swift or hand-roll
  SigV4 request signing. SigV4 is well-documented and a few hundred lines,
  but it's real work the Drive plan doesn't need (Drive's REST + OAuth is
  comparatively mundane). Android gets the AWS SDK for Kotlin, which is
  fine.
- **Verdict:** viable, and the closest AWS analogue to v1 — but it inherits
  Drive's weaknesses while adding signing complexity, so it only wins if
  Femi specifically wants the data out of Google. It is not better than
  Drive *for v1*; it's a lateral move.

#### Option AWS-B — API-first: Cognito + API Gateway + Lambda + DynamoDB + S3

A small purpose-built sync API: Cognito issues the profile's tokens; an
HTTP API (API Gateway) fronts Lambda functions (TypeScript/Node — Femi's
home stack) implementing push/pull sync against DynamoDB (clip records:
metadata + encrypted payload, `updatedAt`, tombstone flag); image blobs go
to S3 via presigned URLs the API hands out.

- **Offline-first:** the standard outbox pattern, hand-built: local DB +
  an outbox queue on each device; push sends queued mutations, pull asks
  for "changes since cursor X" (a DynamoDB query on the profile partition
  ordered by `updatedAt`). More code than AWS-A or Drive, but the sync
  semantics live in exactly one place (the Lambda), and conflict handling
  (LWW per clip) is enforced server-side instead of emerging from file
  races. This is the same engineering the Supabase path (§3 Option C)
  requires — neither backend gives it for free.
- **Auth:** Cognito user pool + API Gateway's JWT authorizer. No identity
  pool needed; the API sees the profile's `sub` on every call. The Mac app
  needs only HTTPS + a Bearer token — *no AWS SDK, no SigV4* — which keeps
  the single-file Swift app dependency-free. This is a quietly decisive
  practical advantage over AWS-A.
- **E2EE:** clip payload fields are encrypted on-device before they ever
  reach the API (§6.3); DynamoDB stores ciphertext plus the plaintext
  metadata the sync protocol genuinely needs (timestamps, tombstones, type).
  Encrypting the metadata too is possible but buys little and complicates
  the pull query.
- **Operational burden:** moderate and real — infrastructure as code
  (CDK/SAM), Lambda code to maintain, logs to glance at. But every component
  is managed, nothing idles at a cost, and it's all inside one AWS account
  he already has. This is the "you operate a small service" option, with
  the smallest possible service.
- **Verdict:** the strongest AWS shape, and the one to compare Supabase
  against when v2 actually starts.

#### Option AWS-C — Amplify (Gen 2) / AppSync — *not recommended in 2026*

The obvious AWS answer, and currently a trap for this project:

- Amplify's offline-first sync engine is **DataStore**, and DataStore is a
  **Gen 1** feature. Amplify Gen 1 has entered maintenance mode and reaches
  **end of life on May 1, 2027**. **Amplify Gen 2 does not support
  DataStore** — its data layer is AppSync GraphQL + DynamoDB without the
  offline sync engine, so offline-first behaviour (local store, mutation
  queue, delta sync, conflict resolution) must be hand-assembled anyway,
  on top of the GraphQL schema machinery.
- That inverts the sales pitch: the one thing Amplify existed to give this
  project — sync without writing sync — is the thing the current
  generation doesn't ship. What remains is AppSync's genuine strengths
  (managed GraphQL, subscriptions for realtime push, owner-based auth
  rules that map cleanly onto the profile model) wrapped in schema-first
  tooling whose generated resolvers and redeploy cycle are a debugging
  surface of their own, and whose per-operation pricing ($4.00 per million
  queries/mutations, $2.00 per million real-time updates, $0.08 per million
  connection minutes) is the highest of the options here — though still
  pennies at this scale.
- Starting a new project on Gen 1 today, against a May 2027 end-of-life,
  needs no further argument. **Avoid.** If realtime push ever becomes the
  deciding feature, AppSync can be adopted later as a notification layer
  in front of Option AWS-B's store — it doesn't have to be the foundation.

#### Where DynamoDB fits

DynamoDB is not a fourth architecture; it's the store inside AWS-B and
AWS-C. (Clients *can* talk to it directly with identity-pool credentials
and per-user IAM policies, skipping the API — but then validation and sync
rules have nowhere to live, and every client re-implements them. Not
recommended beyond a spike.) Its numbers are the friendliest on AWS:
**always-free tier of 25 GB storage + 25 provisioned WCU + 25 RCU per
region**, and on-demand pricing beyond that of $0.625 per million writes /
$0.125 per million reads / $0.25 per GB-month. A clipboard workload fits
inside the free allowance with orders of magnitude to spare.

### 6.3 End-to-end encryption — the same answer on every backend

E2EE is a client property, not a backend feature, and it works identically
on Drive, Supabase, and every AWS option above — which is precisely why the
transport can be swapped later (§3's design already assumes this):

1. When a profile is created, the device generates a random **sync key**.
   Every clip payload (and image blob) is encrypted with it on-device
   (AES-GCM / XChaCha20 — both platforms have this in their standard
   crypto libraries) before upload. The backend — any backend — only ever
   stores and transports ciphertext.
2. Other devices get the key by **key wrapping**: the sync key is
   encrypted under a key derived from the profile password (plus,
   optionally, a one-time recovery code shown at setup), and the *wrapped*
   key is stored server-side (a DynamoDB row, an S3 object — it's just a
   blob). A new device signs in, fetches the wrapped key, unwraps it with
   the password, and can read history. Password changes re-wrap the key;
   they never re-encrypt the clips.
3. The trade-off is the standard E2EE one and should be stated in the
   product, not discovered: **lose the password and the recovery code and
   the synced history is unrecoverable** — by design, because nobody,
   including the backend operator, holds the key.
4. What does **not** count as E2EE: S3 server-side encryption and KMS
   envelope encryption. Those protect against bucket exposure and are
   worth having anyway, but AWS holds those keys — the operator can read
   the data. For a personal app the operator is Femi, so the honest claim
   is narrower than for a public product, but if ClipKeep's privacy story
   is "not even the backend can read your clipboard," only client-side
   encryption (§6.3.1–2) makes it true — same conclusion §3 reached for
   Supabase.
5. And the standing rule from §3/§5 is untouched by any of this: clips from
   concealed/transient pasteboard types and anything flagged sensitive are
   **never synced at all** — encryption is not a licence to sync secrets.

### 6.4 Costs — credits, free tiers, and the month after

Femi's account: $100 in credits on creation, up to $100 more for completing
five guided "Explore AWS" activities (worth doing — it's free money, but
they must be finished inside the free-plan window). Prices below are US
list prices from AWS's pricing pages, checked Nov 18, 2026.

**Always-free allowances (no expiry, survive onto the paid plan):**

| Service | Always-free allowance | Rate beyond |
|---|---|---|
| Lambda | 1M requests + 400,000 GB-seconds / month | $0.20 / M requests + duration |
| DynamoDB | 25 GB storage + 25 WCU + 25 RCU (provisioned) | on-demand $0.625 / M writes, $0.125 / M reads, $0.25 / GB-mo |
| Cognito | 10,000 MAU (Lite/Essentials) | $0.015 / MAU Essentials, $0.0055 Lite |
| Data transfer out | 100 GB / month (account-wide) | $0.09 / GB |

**Not always-free (credits or the 12-month new-customer offers carry these):**

| Service | Price | Note |
|---|---|---|
| S3 Standard | $0.023 / GB-mo; PUT $0.005 / 1k; GET $0.0004 / 1k | No permanent free tier under the new model — the old "5 GB free" was a 12-month offer |
| API Gateway | HTTP APIs $1.00 / M calls; REST $3.50 / M | 1M calls/mo free for the first 12 months |
| AppSync | $4.00 / M operations; $2.00 / M real-time updates; $0.08 / M connection-minutes | 250k ops/mo free for the first 12 months |

**The personal-scale monthly bill, after credits, on the paid plan** —
using the §6.2 workload (a few thousand clips, tens of syncs a day, a few
GB of images): Cognito $0 (one profile ≪ 10,000 MAU), DynamoDB $0 (inside
the always-free allowance), Lambda $0 (a rounding error against 1M free
requests), API Gateway ≈ $0.00–0.05, S3 ≈ $0.10–0.25. **Realistic total:
$0–$0.50 a month — call it effectively free, with S3 storage the only line
that reliably shows up at all.** The AppSync variant lands in the same
place (≈ $0.20–0.40). Cost is simply not the axis this decision turns on;
operational burden and the free-plan cliff (§6.6) are.

**What the $100–$200 of credits is actually for:** not the backend (it
costs ~nothing) but the *testing* spend in §6.5 — Device Farm minutes and
EC2 Mac days are the only items in this whole research that burn money at
a noticeable rate, and credits absorb them comfortably if the plan window
is respected.

### 6.5 Testing on AWS — Device Farm and EC2 Mac

**AWS Device Farm** runs automated tests and remote-access sessions on
real Android and iOS devices hosted by AWS (Appium, Espresso, XCUITest;
a browser-based remote session with swipe/gesture support for manual
passes).

- **Pricing:** $0.17 per device minute, pay as you go; a **one-time free
  trial of 1,000 device minutes**; unmetered slots at $250/month (absurd
  at this scale — ignore); private devices from $200/month (likewise).
- **Fit for the companion:** good, for exactly one job — the pre-release
  device matrix. The companion's risky surfaces are OEM-specific (share
  intents, Quick Settings tiles, clipboard toasts behave differently on
  Samsung vs Pixel vs Xiaomi), and Femi owns exactly one Android phone.
  A 10-device × 15-minute automated pass is 150 device minutes ≈ $25.50 —
  or free inside the trial. Later, the same route gives the iOS companion
  real-device coverage before App Store submission.
- **Limits to know:** Device Farm lives in **us-west-2 only**; sessions
  cap at **150 minutes**; default quotas are 5 automated / 2 remote-access
  devices until raised; Android test packages must be **APKs — it won't
  accept an .aab**. It is a test-runner, not a phone to live on: it does
  not replace his S23+ for daily driving, and interactive remote sessions
  at $10.20/hour are for debugging a failure, not exploring. (Firebase
  Test Lab's free daily quota is the zero-cost alternative for a smaller
  matrix; Device Farm wins on AWS integration and the trial minutes.)
- **Free-plan caveat:** the free plan restricts some services; verify
  Device Farm is enabled on the free plan before counting the trial
  minutes as spendable there — if it isn't, that's a paid-plan activity
  and the $0.17/min meter applies against credits after upgrading.

**EC2 Mac instances** are the Mac-side counterpart, already on the roadmap
(item 17, cloud-Mac clean-room testing) — positioned here, not re-planned:
real Mac minis on Dedicated Hosts, M1 (`mac2`) at $0.65/hr and M2
(`mac2-m2`) at $0.878/hr, M4 at $1.23/hr — but with a **24-hour minimum
allocation** (an Apple licence condition), so one clean-room session
costs a floor of **$15.60** (M1) no matter how short it is, and the host
bills until explicitly released. Against $100–$200 of credits that's
roughly 6–12 M1 session-days: plenty for first-launch / Gatekeeper /
clean-machine verification passes, provided each host is released the
moment the session ends. Device Farm + EC2 Mac together are the "test on
cloud versions of macOS and mobile devices" goal Femi opened the account
for — and they're a *testing* story, entirely separate from the sync
backend question.

### 6.6 Free-plan gotchas (account-specific — read before building anything)

Femi's account is on the **new** AWS free model (accounts created on or
after Jul 15, 2025), which is *not* the old "12 months of free tier" that
most tutorials still describe:

1. **The free plan ends 6 months after account creation, or when the
   credits run out — whichever comes first.** For this account (created
   Nov 18, 2026) that's **~May 18, 2027** — matching the May 19, 2027
   credit expiry in his welcome email. (AWS's own pages are inconsistent
   about the details — the terms say credits are usable within 12 months
   while the plan itself runs 6 — so plan against the earlier date.)
2. **When the free plan ends, the account closes and resources become
   inaccessible.** AWS keeps the content for **90 days**; upgrading to the
   paid plan inside that window restores everything and carries any
   remaining credit balance over. Miss the window and the account and its
   contents are permanently deleted. **Anything built on this account —
   a sync backend included — must either graduate to the paid plan by
   ~May 2027 or be treated as disposable.** On the paid plan, the
   always-free allowances in §6.4 continue, so graduating a personal-scale
   backend costs ≈ $0/month — but the upgrade is a deliberate act with a
   deadline, not a default.
3. **The upgrade is one-way, and some actions trigger it accidentally:**
   joining AWS Organizations, enabling Control Tower, or a HIPAA
   attestation converts a free-plan account to paid on the spot. Don't
   wander into Organizations while exploring.
4. **The free plan fences off some services** (Savings Plans, Reserved
   Instances, some Marketplace offers) and free-plan accounts aren't
   eligible for other promotional credits (e.g. AWS Activate).
5. **Budget alerts lie by default on credit-funded accounts:** AWS Budgets
   counts credits as negative cost, so a $0 budget stays silent while
   credits drain. If a budget alarm is set up as a safety net, configure
   it to exclude credits — especially before any EC2 Mac or Device Farm
   session, the two things here that can actually spend.

### 6.7 Recommendation — and what this changes (and doesn't)

**Keep the existing plan; re-point its v2.**

1. **v1 is unchanged: Drive folder sync, no backend, no ClipKeep-owned
   accounts.** AWS evidence strengthens rather than weakens this: the
   companion is parked until the Mac app is done, the Drive design needs
   no auth work and no service to operate, and the AWS free plan's
   May 2027 cliff sits squarely inside the window when a v1 backend would
   be under construction. Building v1 sync on a foundation that must be
   migrated or upgraded within months — to save nothing, since Drive is
   free too — is all downside.
2. **What changes: the v2 backend is now an open decision, not
   "Supabase by default."** §3 named Supabase + client-side encryption as
   the v2 path. Option AWS-B (Cognito profiles + API Gateway + Lambda +
   DynamoDB + S3) matches it on every axis that mattered — realtime-
   capable sync, client-side encryption (§6.3), an owned profile model
   (§6.1) — and adds three Femi-specific advantages: the account and
   credits already exist, the always-free tiers make the running cost
   ≈ $0 permanently rather than free-tier-for-now, and the Lambda layer
   is TypeScript, his strongest backend language. Supabase keeps one real
   edge (Postgres and a mature auth/storage bundle in one box, less to
   assemble). Decide when v2 starts; §3's transport-interface design
   means the apps don't care which way it goes. **Amplify/AppSync should
   not be the AWS entry — Gen 1 (the one with DataStore) is end-of-life
   May 1, 2027, and Gen 2 dropped the offline sync engine.**
3. **Use AWS now for testing, which is what the account is for:** burn
   the Device Farm trial minutes on the companion's pre-release device
   matrix when there's a companion to test, and use EC2 Mac day-sessions
   for the roadmap's clean-room passes — releasing every host promptly,
   and finishing the five credit-earning activities early while the free
   plan window is open.
4. **Put one date on the calendar: before ~May 18, 2027,** upgrade the
   account to the paid plan (keeping the always-free allowances and any
   remaining credits) or accept the account and everything in it being
   deleted after the 90-day grace. This applies whether or not any
   ClipKeep backend exists by then — the Device Farm/EC2 Mac testing
   setup lives in this account too.

### Sources consulted (Nov 18, 2026)

- AWS API Gateway pricing page — free-plan terms (6-month plan, credits
  usable within 12 months), 1M-call 12-month offers, HTTP $1.00/M and
  REST $3.50/M rates. https://aws.amazon.com/api-gateway/pricing/
- AWS Lambda pricing page — free tier of 1M requests + 400,000 GB-seconds
  per month; $0.20/M requests beyond. https://aws.amazon.com/lambda/pricing/
- AWS Device Farm pricing page and FAQ — $0.17/device minute, 1,000-minute
  one-time trial, $250/slot unmetered, device-minute definition.
  https://aws.amazon.com/device-farm/pricing/
- AWS DynamoDB on-demand pricing (via AWS pricing summaries) — always-free
  25 GB + 25 WCU + 25 RCU; $0.625/M writes, $0.125/M reads, $0.25/GB-mo.
  https://aws.amazon.com/dynamodb/pricing/on-demand/
- Amazon Cognito pricing (AWS pricing page, via Oct–Nov 2026 analyses) —
  Lite/Essentials/Plus tiers, 10,000 free MAU on Lite/Essentials, 50 free
  MAU for SAML/OIDC federation, Essentials as the default tier.
- Amazon S3 pricing (AWS Price List data, via Oct 2026 analyses) —
  $0.023/GB-mo Standard, PUT $0.005/1k, GET $0.0004/1k, 100 GB/mo free
  data transfer out.
- AWS AppSync pricing page — $4.00/M operations, $2.00/M real-time updates,
  $0.08/M connection minutes; 250k ops/mo free for 12 months.
- AWS Amplify Gen 1 documentation — "Amplify Gen 1 has entered maintenance
  mode and will reach end of life on May 1, 2027"; Amplify Gen 2 FAQ via
  aws-amplify issues — "Amplify Gen 2 supports GraphQL APIs without
  DataStore."
  https://docs.amplify.aws/gen1/android/prev/build-a-backend/more-features/datastore/
- AWS Free Tier explainers (Oct–Nov 2026, checked against AWS's Free Tier
  pages) — $100 sign-up credit + up to $100 in activity credits, 6-month
  free plan, 90-day post-closure recovery, Organizations auto-upgrade,
  Budgets-counts-credits behaviour.
  https://unifiedpathmedia.com/aws-free-tier-credits-plans-explained/
  https://builder.aws.com/content/3Kkt4kNiDSUnO3n6db2weSNubzE/the-dollar0-aws-account-in-2026-free-plan-credits-guardrails
- EC2 Mac pricing summaries (Oct 2026, from AWS Dedicated Host price
  data) — mac2 M1 $0.65/hr, mac2-m2 $0.878/hr, M4 $1.23/hr, 24-hour
  minimum allocation. https://macrun.dev/ec2-mac-alternative

---

## Free alternatives to the AWS backend — Nov 18, 2026

Follow-up to §6, researched the same evening at Femi's request ("look into any
free alternatives that exist"). §6 compared AWS against the §3 plan on the
basis that AWS-B costs ≈ $0–0.50/month — but that $0 rests on Femi's free plan
until ~May 2027 and on always-free allowances after a deliberate upgrade. This
section asks the stricter question: **what is genuinely $0, with no cliff, no
card, and no expiry — and what does each "free" quietly take away?** Every
figure below was checked against the vendor's own pricing/docs pages (or
documentation quoting them) on Nov 18, 2026; sources at the end.

**The one-sentence answer:** nothing here displaces Drive for v1, but the v2
picture widens and sharpens — Firebase becomes a real third candidate (the
only free option with an offline sync engine included), Cloudflare and
PocketBase-on-Oracle emerge as the no-cliff sovereignty options, and the
hosted free tiers of Supabase and Appwrite both turn out to *pause* — with
Appwrite Cloud going further and *deleting* long-paused free projects, the
single worst trap in this survey. A pattern emerges: **every hosted free tier
has a designed failure mode for an always-on sync backend**; the durable free
homes are the ones whose limits ClipKeep's workload cannot reach, or a server
Femi owns.

### 7.1 Firebase (Spark plan) — the offline-sync heavyweight

- **Free limits (Spark, no card, no expiry):** Authentication 50,000 MAU
  (email/social/anonymous; SAML/OIDC only 50 MAU). Firestore: 1 GiB stored,
  50,000 reads/day, 20,000 writes/day, 20,000 deletes/day, 10 GiB/month
  egress. Realtime Database: 1 GB stored, 100 simultaneous connections,
  ~10 GB/month downloaded. FCM push free. No pausing, no sleeping, no
  time limit — quotas are daily hard caps that reset at midnight; on Spark,
  hitting one means refusals until reset, never a bill.
- **Offline sync — the best in this survey, and it isn't close.** Firestore's
  Android SDK has offline persistence **on by default**: local cache, queued
  writes, realtime listeners that keep firing against the cache, and
  automatic sync on reconnect. §3 and §6 both noted that every other backend
  makes Femi hand-build the outbox/delta-sync layer; Firestore is the one
  place it comes in the box. For a sync viewer whose whole job is "show the
  Mac's history, queue changes offline," that is a genuine engineering
  saving, not a convenience.
- **Fit for profiles + E2EE:** profiles are Firebase Auth accounts; rules
  key data to the auth `uid` exactly as §6.1 keyed AWS data to the Cognito
  `sub`. E2EE works unchanged — clip payloads are ciphertext blobs in
  documents; Firebase never needs to read them.
- **The trap — and it's a ClipKeep-shaped one:** **since February 3, 2026,
  Cloud Storage is not available on Spark at all.** Buckets require the
  Blaze plan (a billing account attached). ClipKeep's image clips need blob
  storage, so Spark alone cannot host the full product; Firestore's 1 GiB
  is not a serious image store. The escape is painless but changes the
  claim: on Blaze, the `*.firebasestorage.app` buckets include 5 GB-months
  stored and 100 GB/month downloaded at no cost (US regions), and every
  Spark quota above still applies — so the realistic bill at ClipKeep scale
  is $0.00, **but with a card on file and pay-as-you-go exposure above the
  quotas** (budget alerts exist; spending caps do not). "Free" becomes
  "free with a card attached."
- **Lock-in: the deepest in this survey.** Proprietary NoSQL model,
  proprietary security-rules language, SDK-centric access, no self-host
  option, no meaningful export story for live data. Leaving Firebase means
  rewriting the sync layer, not re-pointing it. Google also demonstrated
  with the February 2026 Storage change that Spark's contents can shrink
  unilaterally.

### 7.2 Supabase free tier — the pause, pinned down

§3 named Supabase the v2 path and §6 made it one of two finalists; neither
priced the free tier's behaviour precisely. From Supabase's pricing page and
docs:

- **Free limits:** 2 active projects; 500 MB database per project; 1 GB file
  storage; 5 GB egress (+ 5 GB cached); 50,000 MAU; unlimited API requests;
  500,000 Edge Function invocations/month; 200 realtime connections.
  Generous — ClipKeep's workload is nowhere near any of these.
- **The trap: free projects pause after 1 week of inactivity.** A paused
  project answers nothing until a human resumes it from the dashboard
  (restorable for up to 1 year; data is kept). Warning emails go out about a
  week ahead. For a sync backend this is a peculiar failure mode: daily use
  keeps it alive, but a two-week holiday — exactly when "copied at my desk,
  need it while travelling" matters — can end with sync silently down until
  Femi opens the Supabase dashboard. Keep-alive pings (a scheduled request
  counts as activity) are the standard workaround, which is to say the free
  tier requires a small permanent hack to be a backend. No automatic backups
  on free, either.
- **E2EE / profiles:** unchanged from §3/§6 — Postgres rows of ciphertext,
  RLS by user id, auth included. **Lock-in is the lowest of the hosted
  options:** it's Postgres, the data is SQL-exportable, and self-hosting the
  same stack (Docker) is a documented exit.
- **Net effect on §6.7:** Supabase stays a v2 finalist on technology, but
  its *free tier* should be understood as trial-grade housing. A v2 launch
  on Supabase means Pro ($25/month) or self-hosting from day one — the
  "$0 Supabase" version has a weekly heartbeat requirement.

### 7.3 Cloudflare (Workers + D1 + R2) — permanent free, but bring your own auth

- **Free limits (no expiry, no pausing):** Workers 100,000 requests/day with
  10 ms CPU per invocation. D1 (SQLite): 5 million rows read/day, 100,000
  rows written/day, 5 GB total storage across up to 10 databases, no egress
  charges; exceeding a daily cap returns errors until the 00:00 UTC reset —
  no bill, ever, on the free plan. R2: 10 GB-month storage, 1 million
  Class A (write/list) ops/month, 10 million Class B (read) ops/month, and
  **zero egress fees at every tier** — the only storage here where image
  clips being downloaded constantly costs nothing.
- **The gap — auth.** Cloudflare has no consumer sign-up product. The
  profile system §6.1 needs must be (a) hand-rolled in Workers
  (email/password, hashing, JWTs, reset flows — all standard, all Femi's to
  build and secure), or (b) fronted by Cloudflare Access (Zero Trust Free,
  up to 50 users) — but Access is a team-oriented gate in front of an app
  via an external IdP, not a consumer account system; it fits "protect my
  admin/API" better than "users sign up for ClipKeep," or (c) delegated to
  a third-party auth free tier, which reintroduces a vendor. This is the
  stack's true price: **the sync API and the account system are both DIY.**
  The 10 ms CPU cap also rules out doing encryption *server-side* in the
  Worker — irrelevant here, since §6.3's design encrypts on-device anyway.
- **Small print:** enabling R2 requires adding a payment method (a
  subscription checkout) even though the free allowance is $0 within it.
- **E2EE / lock-in:** E2EE is clean — Workers route ciphertext between
  clients, D1 and R2. Lock-in is moderate and mostly at the compute layer:
  D1's data is SQLite (exportable), R2 is S3-compatible (blobs walk away
  freely), but Worker code uses Cloudflare's runtime APIs. No servers to
  run, nothing sleeps, nothing expires — of the hosted options this is the
  hardest free tier to be evicted from.

### 7.4 Appwrite — two different answers wearing one name

- **Appwrite Cloud Free:** 2 projects; 75,000 MAU; 2 GB storage; 5 GB
  bandwidth; 750,000 function executions; per project 1 database, 1 storage
  bucket, 2 functions. Full feature set in miniature: auth (30+ OAuth
  providers), databases, storage, functions, realtime, messaging.
- **The trap — the worst found in this survey.** Appwrite Cloud adopted
  Supabase-style pausing in early 2026, with two sharpeners: per Appwrite's
  own billing docs, a free project pauses after 7 days without **development
  activity in the Console — end-user traffic does not count as activity** —
  and per its June 2026 changelog, **free projects are deleted after 90 days
  paused.** Read that as a sync backend: ClipKeep could sync happily every
  day, Femi never opens the Appwrite Console, the project pauses underneath
  live traffic, and 90 days later the backend — profiles, clip metadata,
  stored blobs — is *deleted*, not slept. AWS's cliff (§6.6) at least has a
  known date, an upgrade path, and a 90-day recovery window. This is a
  data-loss trap wearing a free tier's clothes. **Appwrite Cloud Free is
  disqualified as a place to run v2**, whatever its feature list.
- **Self-hosted Appwrite is a different product in practice:** BSD-3-Clause,
  every feature, no usage limits, no pausing — because it's Femi's server.
  It runs as a Docker Compose stack (MariaDB/Postgres, Redis, storage) and
  wants ~4 GB RAM to be comfortable. The cost is operational: updates,
  backups, TLS, and uptime are his job, and the stack is the heaviest thing
  in this section to keep alive. Viable on the Oracle instance in §7.6;
  reasonable if ClipKeep ever needs Appwrite's breadth (messaging, sites,
  many runtimes); overkill for one sync API.

### 7.5 PocketBase — the one-binary backend

- **What it is:** MIT-licensed, open source, a single Go executable (~20 MB)
  containing an embedded SQLite database (WAL mode), user auth
  (email/password, email OTP, MFA, 15+ OAuth2 providers), file storage
  (local disk or any S3-compatible bucket), realtime subscriptions,
  an admin UI, and built-in backups (snapshots of the data directory,
  optionally to S3). No usage limits of any kind — the limits are the
  hardware's. It needs an always-on machine with a persistent disk; it
  cannot run on serverless or ephemeral-filesystem platforms.
- **Fit for ClipKeep:** at this workload (one profile, a few thousand
  clips, tens of syncs a day) PocketBase is not merely adequate, it's
  *sized* for the job — the author reports 10,000+ persistent realtime
  connections on a $4 VPS. Profiles are its built-in user collections;
  per-user API rules (`@request.auth.id`) give the same isolation model as
  §6.1; E2EE is untouched (it's a REST API moving ciphertext and files).
- **What it lacks vs the others:** horizontal scaling (SQLite is
  single-server, single-writer — vertical growth only, replication via
  add-ons like Litestream); a serverless-functions story (custom logic is
  JavaScript hooks via an embedded interpreter, or Go extensions compiled
  into the binary); **an official Android/Kotlin SDK — official SDKs are
  JavaScript and Dart only**, so the Kotlin companion talks raw REST (fine,
  and arguably in keeping with the Mac app's no-SDK approach to AWS-B, but
  it's hand-written client code); polish items like per-file size defaults
  (~5 MB per file field, configurable — image clips need it raised).
- **The structural risks:** PocketBase is **pre-1.0** (v0.41.x) and its own
  README warns backward compatibility isn't guaranteed before 1.0; it's
  essentially a **one-maintainer project**; and the repository has moved off
  GitHub. None of these is disqualifying for a personal backend whose data
  is one SQLite file Femi can copy anywhere — the exit cost is the lowest
  in this survey — but they are the price of the simplicity.

### 7.6 Oracle Cloud Always Free — the forever server underneath 7.4/7.5

Self-hosting needs a machine that never bills and never sleeps. Oracle's
Always Free tier is the only big-cloud offer that is literally that:

- **What you get, for the life of the account, no expiry:** Ampere A1 (Arm)
  compute totalling **2 OCPUs + 12 GB RAM** (the first 1,500 OCPU-hours and
  9,000 GB-hours/month), as one VM or two; up to two AMD micro VMs (1/8
  OCPU, 1 GB each); 200 GB of block/boot storage in total with five volume
  backups; 20 GB object storage; 10 TB/month outbound data. (Note for
  anyone reading older guides: the Arm allowance was **halved in 2026** —
  it was 4 OCPUs + 24 GB until June 2026. "Always Free" describes the
  price, not the permanence of the terms.)
- **What runs there:** PocketBase without noticing the machine exists;
  self-hosted Appwrite within its ~4 GB comfort zone; self-hosted Supabase
  fits the spec on paper (its documented minimums are ~4 GB RAM / 2 cores /
  40 GB disk) — but verify ARM64 images for every container in the stack
  before committing, since the A1 is Arm and the AMD micros are far too
  small to be the fallback. TLS via Caddy/Let's Encrypt, backups to the
  included object storage or to Drive.
- **The caveats, which are real:** (1) **Idle reclaim** — Oracle may
  reclaim an Always Free instance whose 7-day 95th-percentile CPU, network,
  *and* (on A1) memory utilisation are all under 20%. A live sync backend
  with a database cache will usually sit above the memory line; a
  near-empty PocketBase on a 12 GB box might not — this is a knowable,
  monitorable risk, not a surprise, but it never fully goes away.
  (2) Accounts idle 30+ days may be deemed abandoned. (3) Sign-up requires
  a credit card, is famously finicky (declined cards, silent rejections),
  the home region chosen at sign-up is permanent, Always Free capacity in
  popular regions is often simply unavailable ("out of capacity" is a
  rite of passage), and free accounts get no SLA and no support.
  (4) Outbound port 25 is blocked — irrelevant for this use.
- **Net:** Oracle Always Free + PocketBase is the only combination in this
  entire research where $0 is structural rather than promotional: no
  dashboard to keep warm, no plan to upgrade by a date, no quota a good
  month can breach. What it costs instead is Femi — patching, backups,
  monitoring, and the small standing risk that Oracle reclaims or re-terms
  the gift.

### 7.7 Device testing, briefly — Firebase Test Lab vs Device Farm

One subsection, per the brief. **Firebase Test Lab's Spark quota is
10 virtual-device + 5 physical-device test runs per day, every day, free
forever** (plus 30 minutes/month of Android Device Streaming). Set against
§6.5's Device Farm maths — a one-time 1,000 trial minutes, then
$0.17/minute — Test Lab is the better *routine* deal for the companion: a
pre-release smoke matrix of four or five physical devices fits inside a
single day's free quota, and the quota refills tomorrow. Its limits are a
smaller iOS device catalogue and less depth for large one-off matrices,
which is where Device Farm (or the trial minutes) still wins. **Net: Test
Lab replaces Device Farm for day-to-day companion testing at $0; Device
Farm remains the big-matrix and iOS option.**

### 7.8 Comparison

| Option | Headline free allowance | Sleeps / expires? | Offline sync engine | Profiles included | E2EE | Lock-in / exit |
|---|---|---|---|---|---|---|
| Drive folder (§3-A) | User's own Drive storage | No | File-based (hand-built) | Borrowed (Google account) | ✓ (encrypt files) | None — it's files |
| AWS-B (§6) | Always-free Lambda/DynamoDB/Cognito after paid-plan upgrade | Free **plan closes ~May 2027**; allowances permanent after upgrade | Hand-built outbox | ✓ Cognito (10K MAU free) | ✓ | Low-moderate (standard services, TS code) |
| Firebase Spark | 50K MAU; Firestore 1 GiB + 50K r / 20K w per day; RTDB 1 GB | No — but **Storage removed from Spark Feb 2026** (Blaze + card required; $0 within quotas) | **✓ Built in (Firestore)** | ✓ Auth | ✓ | **High** — proprietary everything, no self-host |
| Supabase Free | 50K MAU; 500 MB DB; 1 GB files; 5 GB egress | **Pauses after 1 week idle** (manual resume; 1-yr restore) | Hand-built outbox | ✓ Auth | ✓ | Low — Postgres, self-hostable |
| Cloudflare Workers+D1+R2 | 100K req/day; D1 5M r / 100K w per day, 5 GB; R2 10 GB, **$0 egress** | No | Hand-built (REST) | **✗ DIY** (Access ≤50 users is a gate, not sign-up) | ✓ | Moderate — SQLite/S3 data portable, Workers code isn't |
| Appwrite Cloud Free | 75K MAU; 2 GB storage; 5 GB bandwidth | **Pauses after 7 days w/o Console activity (traffic doesn't count); deleted after 90 days paused** | Hand-built (REST/realtime) | ✓ Auth | ✓ | Moderate — open source, self-hostable |
| Appwrite self-hosted | Unlimited (your hardware) | No | Hand-built | ✓ Auth | ✓ | Moderate — heaviest stack to operate |
| PocketBase (self-hosted) | Unlimited (your hardware) | No | Hand-built (REST/realtime) | ✓ Auth | ✓ | **Lowest** — one SQLite file + files; pre-1.0, one maintainer |
| Oracle Always Free (host) | 2 OCPU + 12 GB Arm, 200 GB storage, 10 TB egress | No expiry; **idle reclaim possible** | — (runs 7.4/7.5) | — | — | None — it's a Linux VM |

### 7.9 Recommendation — what this changes (and doesn't)

1. **v1 is unchanged, again: Drive folder sync.** No candidate beats
   "no accounts, no service, data in the user's own storage" for shipping
   the companion, and the two options that could host v1 for free all
   charge their price in Femi's time instead (Cloudflare's DIY auth,
   PocketBase's server). Drive remains the only zero on both axes.
2. **What changes: the v2 decision is now a three-way, and "hosted free"
   is downgraded as a production plan.** §6.7 left v2 as Supabase vs
   AWS-B. **Firebase joins them** — it is the only candidate that removes
   the sync-engine work (Firestore offline persistence) instead of
   repricing it, its free quotas are unreachable by this workload, and it
   never sleeps. Its costs are the card-on-file Blaze requirement for
   image storage and the deepest lock-in in the survey; for a personal
   product with a Mac-side local store as the source of truth, both are
   tolerable, and the local store means Firebase holds a *mirror*, which
   caps the lock-in damage. Meanwhile **Supabase Free and Appwrite Cloud
   Free are reclassified from "free homes" to "free trials"** — pausing
   (and in Appwrite's case, deletion) makes them places to prototype v2,
   not to run it. Running v2 on Supabase means Pro or self-hosting;
   running it on Appwrite Cloud Free should not happen at all.
3. **The sovereignty option is now concrete: PocketBase on Oracle Always
   Free.** If the deciding value is "no vendor can pause, close, or
   re-term this backend," this is the answer — structurally $0, no
   heartbeat, data in one copyable SQLite file — bought with solo
   operations duty and a pre-1.0, one-maintainer dependency. It is the
   natural hedge if any hosted finalist's terms move the way Spark's did.
4. **Cloudflare is the middle path if egress ever matters:** permanent
   free tiers and $0 image downloads, at the price of hand-building auth.
   It loses to Firebase on sync engineering and to PocketBase on
   simplicity, but it is the only hosted option with neither a pause, a
   cliff, nor a card-gated storage tier.
5. **Testing:** adopt Firebase Test Lab's daily free quota as the
   companion's routine device matrix; keep Device Farm's trial minutes
   for large matrices and iOS depth (§7.7). This slightly reduces the
   §6.5 credit burn, which is welcome given §6.6's deadline.

Nothing in this section changes §5's product recommendation, §6.1's profile
model, or §6.3's encryption design — every candidate above was evaluated
against them, and E2EE in particular survives every transport, because it
was never the transport's property.

### Sources consulted (Nov 18, 2026)

- Firebase pricing page (official, read Nov 18, 2026) — Spark/Blaze quotas:
  Auth 50K MAU, Firestore 1 GiB + 50K reads / 20K writes / 20K deletes per
  day + 10 GiB/month egress, RTDB 1 GB + 100 connections, Hosting and Test
  Lab quotas (10 virtual + 5 physical tests/day).
  https://firebase.google.com/pricing
- Firebase Storage FAQ / Sept 2024 storage changes (via Firebase docs and
  Oct–Nov 2026 coverage) — Cloud Storage requires Blaze from Feb 3, 2026;
  `*.firebasestorage.app` no-cost allowance of 5 GB-months + 100 GB/month
  downloads on Blaze.
  https://firebase.google.com/docs/storage/faqs-storage-changes-announced-sept-2024
- Firestore offline documentation (official) — "For Android and Apple
  platforms, offline persistence is enabled by default."
  https://firebase.google.com/docs/firestore/manage-data/enable-offline
- Firebase Test Lab usage, quotas and pricing (official) — Spark: 15 test
  runs/day total (10 virtual, 5 physical); 30 no-cost Device Streaming
  minutes/project/month.
  https://firebase.google.com/docs/test-lab/usage-quotas-pricing
- Supabase pricing page (official) and project-pausing docs (via Oct–Nov
  2026 checks against supabase.com/pricing) — 2 active projects, 500 MB DB,
  1 GB storage, 5 GB egress, 50K MAU; "Free projects are paused after
  1 week of inactivity"; 1-year restore window; no free backups.
  https://supabase.com/pricing
- Cloudflare D1 pricing (official docs, updated Oct 30, 2026) — Workers
  Free: 5M rows read/day, 100K rows written/day, 5 GB total storage,
  10 databases, no egress charges, errors-not-bills past the daily caps.
  https://developers.cloudflare.com/d1/platform/pricing/
- Cloudflare Workers limits/pricing and R2 pricing (official docs, via
  Oct–Nov 2026 checks) — 100,000 requests/day, 10 ms CPU on Free; R2
  10 GB-month + 1M Class A + 10M Class B ops/month, zero egress fees; R2
  activation requires a subscription/payment method.
- Cloudflare Zero Trust plans (official, via Sept–Oct 2026 checks) —
  Access on the Free plan for up to 50 users.
  https://www.cloudflare.com/plans/
- Appwrite pricing and billing docs (via Nov 4, 2026 check of
  appwrite.io) — Cloud Free: 2 projects, 75K MAU, 2 GB storage, 5 GB
  bandwidth, 750K executions; free projects pause after 7 days without
  Console development activity (user traffic does not prevent pausing);
  Appwrite changelog (Jun 29, 2026): free projects deleted after 90 days
  paused. Self-hosted: BSD-3-Clause, all features, Docker Compose.
- PocketBase documentation and FAQ (pocketbase.io, via Oct–Nov 2026
  checks) — single Go binary, embedded SQLite (WAL), auth incl. OAuth2/MFA,
  local or S3 file storage, realtime, built-in S3 backups; vertical scaling
  only; official SDKs for JavaScript and Dart; pre-1.0 compatibility
  warning (v0.41.x).
- Oracle Cloud Always Free Resources and Free Tier FAQ (official docs, via
  checks on Oct 28 – Nov 18, 2026) — Ampere A1: first 1,500 OCPU-hours +
  9,000 GB-hours/month (≈ 2 OCPUs + 12 GB), 2 AMD micro VMs, 200 GB block
  storage, 10 TB/month outbound; idle-instance reclaim rule (7 days, 95th
  percentile CPU/network/memory all < 20%); accounts idle 30+ days may be
  deemed abandoned; home-region rule. The 2026 reduction from 4 OCPUs +
  24 GB is recorded in Oct 2026 coverage of Oracle's docs.
