# ClipKeep for Mac

[![Build](https://github.com/femisowems/keepsake/actions/workflows/build.yml/badge.svg)](https://github.com/femisowems/keepsake/actions/workflows/build.yml)

**Everything you copy, kept — privately, on your Mac.**

ClipKeep is a tiny, free, open-source macOS menu bar app that remembers
what you copy — text, images, files and colours — so the thing you copied
an hour ago is still one shortcut away. It was built as a free,
local-only alternative in the spirit of clipboard managers like Paste:
the same core job, in a single Swift file with **no dependencies, no
account, no sync, no tracking, and nothing sent anywhere**. What you
copy never leaves your Mac.

*(Repository codename: **keepsake** — it keeps what you copy, for
safekeeping. The app itself is called ClipKeep.)*

---

## Features

- **Menu bar app, no Dock icon** — a 📋 in your menu bar (⏸ while
  capture is paused), and a floating panel toggled by clicking it or
  pressing **⌘⇧V** from any app.
- **Captures almost everything** — plain text, images, files copied in
  Finder, and colours, recorded in the background as you copy. Each
  clip shows **which app it came from**.
- **Search that sees inside images** — image clips are run through
  on-device text recognition (Apple's Vision framework) when they're
  captured, so you can find a screenshot by the words in it. Search
  also covers text, file names and source apps, and type filters
  (Text / Images / Files / Colours) sit next to the search field.
- **Pinboards** — file keepers onto named boards (snippets, templates,
  colours). Pinned and boarded clips never expire; a board picker
  filters the list to one board at a time.
- **Paste back, three ways**
  - Click any clip to put it back on the clipboard — and if you've
    granted Accessibility permission, ClipKeep presses ⌘V for you so
    it lands where your cursor is.
  - **⌘1–⌘9** quick-pastes the first nine visible clips while the
    panel is open (the rows show their numbers).
  - **Paste Stack** — queue clips with **+ Stack**, then paste them
    in order with **⌃⌥⌘V**, built for forms and repetitive entry.
- **Private by design**
  - Copies marked *concealed* or *transient* (how password managers
    mark theirs) are **never recorded**.
  - An **Excluded apps** list: copies made while an excluded app is
    frontmost are never recorded either.
  - History lives in one local folder; there is no network code in
    the app at all.
- **Your history, your limit** — 200 unpinned clips by default, or
  500, 1000, or no limit. Identical copies are de-duplicated (copying
  the same thing again just brings it back to the top).
- **Pause capture** any time from the panel.
- **A card for every clip** (v2.1) — the panel is styled after Paste:
  white rounded cards on a light backdrop, a coloured header band per
  clip (text cards take their colour from the app you copied from,
  links are green, files blue, images purple, colour clips wear the
  colour itself), the source app's icon in a badge, relative times
  ("4 hours ago"), and Paste-style footers — character counts, image
  dimensions, file sizes.
- **Link previews** (v2.2) — copied links fetch the page title and
  preview image in the background and render as rich cards.
- **Preview & edit** — the eye button on a card (or right-click →
  Preview / Edit) opens any clip full-size; text clips can be edited
  and saved in place.
- **Right-click menu** on every card: Paste, Copy, Preview / Edit,
  Pin, Move to Board, Add to Paste Stack, Delete.
- **Update checker** — at launch the app checks a tiny public version
  feed and banners new releases at the top of the panel.
- **Search filters** — by source app and recency (Today / 7 / 30
  days), next to the pinboard filter.

## Requirements

- macOS 11 (Big Sur) or later
- To build from source: the free **Xcode Command Line Tools** (for
  `swiftc`). You do **not** need the full Xcode app, an Apple Developer
  account, or the App Store.

## Quick start

```bash
git clone https://github.com/femisowems/keepsake.git
cd keepsake
chmod +x build.sh
./build.sh
```

That compiles the app and produces **`ClipKeep.app`** in the same
folder, with its icon bundled and an ad-hoc code signature applied.

If the build says `swiftc` is missing, install the Command Line Tools
first, wait for Apple's installer to finish, then run `./build.sh`
again:

```bash
xcode-select --install
```

## Installing

1. Drag **`ClipKeep.app`** into your **Applications** folder.
2. Double-click it. A 📋 appears in your menu bar — there is no Dock
   icon; the app lives in the menu bar and its floating panel.
3. **First launch:** the build is ad-hoc signed rather than notarized,
   so a *downloaded* copy is blocked by Gatekeeper until you approve
   it once — see *First launch* below. (A copy you built yourself
   opens with no warning at all.)
4. Optional but recommended: the first time you click a clip to paste
   it back, grant **Accessibility** permission when macOS asks
   (System Settings → Privacy & Security → Accessibility). With it,
   ClipKeep pastes directly into the app underneath; without it, the
   clip still lands on your clipboard and you press ⌘V yourself.

## First launch — the "Apple could not verify" dialog

If you downloaded a prebuilt `ClipKeep.app` (for example the artifact
from a CI run) instead of building it yourself, the first launch will
likely show:

> **"ClipKeep" Not Opened** — Apple could not verify "ClipKeep" is
> free of malware that may harm your Mac or compromise your privacy.

This is expected, and it does not mean anything is wrong with the app.
ClipKeep is signed with an ad-hoc signature, not a paid Apple Developer
ID, and it is not notarized — so Gatekeeper blocks any *downloaded*
copy until you approve it once. The source is right here in this repo;
the build takes one command, and CI builds it from this exact code.

**Do not click "Move to Trash."** Click **Done**, then approve it once:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the **Security** section. You will see a line saying
   "ClipKeep" was blocked to protect your Mac.
3. Click **Open Anyway**, authenticate (Touch ID or password), then
   click **Open** in the confirmation dialog.

ClipKeep launches, and macOS remembers the exception — every later
launch, including updates you replace in place in Applications, opens
normally.

**Terminal alternative** (same result, one command — it removes the
"downloaded from the internet" quarantine flag that triggers the
block):

```bash
xattr -dr com.apple.quarantine /Applications/ClipKeep.app
```

**Skip the dialog entirely:** build from source instead (see *Quick
start*). An app compiled on your own Mac is never quarantined, so it
opens without any of this.

## How to use it

| Action | What it does |
| --- | --- |
| **⌘⇧V** or click 📋 | Show / hide the panel |
| **Click a clip** | Put it back on the clipboard (and paste it, with Accessibility permission) |
| **⌘1–⌘9** (panel open) | Quick-paste that numbered clip |
| **Pin / Unpin** | Keep a clip forever, shown in the Pinned group |
| **Board…** | File a clip on a pinboard (or create a new one) |
| **+ Stack** | Add a clip to the Paste Stack |
| **⌃⌥⌘V** | Paste the next clip from the stack, in order |
| **✕** | Delete a clip |
| **Clear history** | Delete everything except pinned and boarded clips |
| **Pause capture** | Stop recording new copies until you resume |
| **Excluded apps…** | Manage the list of apps whose copies are never recorded |
| **Limit popup** | History size: 200 / 500 / 1000 / no limit |

### Good to know

- The panel remembers its size and position between launches.
- Text is stored as **plain text** — formatting is stripped at
  capture, deliberately. What you paste back is clean text.
- Deleting an image clip deletes its stored PNG too; there are no
  orphaned files.
- Quitting the app stops capture; your history is still there next
  launch.

## What it deliberately does not do

- **No iCloud sync, no iPhone/iPad app.** Sync needs CloudKit
  entitlements and a full Xcode project; ClipKeep stays a single
  file you can read end to end. (This is the commercial apps' real
  advantage — noted honestly.)
- **No AI features.** The one exception is on-device text
  recognition for search, which runs entirely on your Mac.
- **No rich-text storage** — see above; plain text on purpose.

## How it works

ClipKeep is a single-file AppKit app (`main.swift`, ~1,100 lines). It
polls the system pasteboard's change count twice a second; on a
change it skips concealed/transient copies and excluded apps, then
records the first matching type — file, image, colour, or text —
along with the frontmost app's name. Images are written as PNGs to
`~/Library/Application Support/ClipKeep/images/` and indexed in
`history.json` next to them; the Vision framework reads their text
for search. Paste-back writes the clip to the pasteboard and, with
Accessibility permission, synthesizes ⌘V. Global hotkeys use the
Carbon hot-key API, so no entitlement or helper is needed.

## Project layout

```
keepsake/
├── main.swift         # the whole app — capture, panel, paste-back
├── build.sh           # compiles ClipKeep.app with swiftc (no Xcode project)
├── SPEC.md            # the v2 spec this build implements
├── AppIcon.icns       # bundled app icon (all macOS sizes)
├── AppIcon-1024.png   # icon source artwork
├── LICENSE            # MIT
└── README.md
```

## Downloading vs building

Prebuilt copies are published on the
[Releases page](https://github.com/femisowems/keepsake/releases) —
each is the exact artifact produced by this repo's CI from the tagged
commit, so what you download is verifiably what this source builds.
Downloaded copies need the one-time **Open Anyway** approval described
above. Building from source takes one command, needs nothing but the
free Command Line Tools, and skips the Gatekeeper dialog entirely —
recommended if you're comfortable in a terminal.

## Privacy

ClipKeep collects nothing, stores nothing beyond your clipboard
history and its own settings, and makes no network connections. There
is no analytics, no account, and no update checker phoning home. Your
history folder is yours: delete `~/Library/Application
Support/ClipKeep` and everything is gone.

---

Built by [Femi Sowemimo](https://github.com/femisowems) (StarterDev).
