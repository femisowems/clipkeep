# ClipKeep v2 — spec

ClipKeep v1 (Nov 14, 2026) covered the basics: background capture of text
and images, search, pins, click-to-paste-back, concealed copies never
recorded, local-only storage. v2 closes the practical gaps against
Paste (assessed Nov 15, 2026 from its App Store listing, v7.0.5),
keeping ClipKeep's constraints: a single Swift file, no dependencies,
no account, no network, free.

## In scope for v2

1. **Source app per clip** — every clip records the app it was copied
   from (the frontmost app at capture time), shown on the row and
   included in search.
2. **More content types** — file copies (Finder) and colours join text
   and images. Files paste back as files; colours show a swatch and
   paste back as the colour (hex on the clipboard as text too).
3. **OCR search** — images are run through on-device text recognition
   (Vision framework) at capture time; the recognized text is stored
   with the clip and searched, so screenshots are findable by their
   contents. Nothing leaves the Mac.
4. **Filters** — type filter (All / Text / Images / Files / Colours)
   next to the search field.
5. **Pinboards** — named boards alongside pins. A clip can be filed on
   one board; the board picker filters the list. Boards never expire
   (exempt from the history limit, like pins).
6. **Quick paste ⌘1–⌘9** — while the panel is open, ⌘ plus a digit
   pastes that item in the current view; the first nine rows show
   their number.
7. **Paste Stack** — queue clips, then paste them in order with
   ⌃⌥⌘V (or the Paste next button), for form-filling and repetitive
   entry.
8. **Per-app exclusions** — an Excluded Apps list (on top of the
   existing concealed/transient skipping): copies made while an
   excluded app is frontmost are never recorded. Managed in a small
   window: add any installed app, remove with one click.
9. **History limit choice** — 200 (default) / 500 / 1000 / unlimited
   unpinned clips, switchable in the panel footer.

## Deliberately out of scope

- **iCloud sync and iPhone/iPad apps** — needs CloudKit entitlements
  and a full Xcode project; breaks the single-file build. (Paste's
  real moat; noted, not chased.)
- **MCP / AI-tool exposure of history** — a server surface on a
  privacy-first local app; revisit only if wanted explicitly.
- **Rich-text storage** — ClipKeep stores plain text on purpose;
  formatting is stripped at capture. Paste-as-plain-text is therefore
  the only mode, which most people want anyway.
- **Apple Intelligence suggestions** — no equivalent API for this
  app's shape; skip.

## Compatibility

- Existing v1 history files load unchanged (new fields are optional).
- Settings (exclusions, boards, limit) live in UserDefaults under the
  existing bundle id `io.starterdev.clipkeep`.
- Minimum system stays macOS 11.
