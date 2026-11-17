# ClipKeep — Top 10 improvement list

Saved Mon Nov 16, 2026 at Femi's request. Ordered by impact.
Check items off here as they ship.

- [ ] **1. Quick actions / text transformations** — right-click a clip to paste as plain text, change case, trim whitespace, extract links, pretty-print JSON, copy as Markdown.
- [ ] **2. Keyboard-first navigation** — arrow keys move through the feed, Enter pastes, Space previews, typing jumps to search.
- [ ] **3. Snippets with placeholders** — a pinned clip becomes a template with {date}, {name}, {clipboard} filled in at paste time.
- [ ] **4. Smart boards** — rules that auto-file clips by source app, keyword, or type (e.g. github.com links → Links board).
- [ ] **5. Secret detection & auto-expire** — spot likely API keys, passwords and one-time codes; optionally hide from the panel and auto-delete after first paste or 24h.
- [ ] **6. Code intelligence** — detect a code clip's language, syntax-highlight it on the card, plus "Open in Editor".
- [ ] **7. Sync + export/import** — history follows across Macs via an iCloud Drive folder; export/import the whole library.
- [ ] **8. Capture health, remembered** — pause state survives relaunches; menu-bar icon shows capture is live at a glance.
- [ ] **9. Drag & drop** — drag a card into Finder/Mail/chat; drag files in to add; drag pinned clips to reorder.
- [ ] **10. Menu-bar recents** — last 9 clips from the 📋 icon menu, paste without opening the panel.
- [x] **11. UI/UX design pass** *(added Nov 17 at Femi's request)* — Paste-style polish as a deliberate design track: frosted vibrancy panel background (visual mock first, Femi picks the direction), top-aligned full-height cards, image-text redesign (chip + one-line teaser on the card, full text in Preview), and consistent spacing/typography across cards and menus.
  *Status Nov 17: core shipped — Warm Tint frosted background (Femi's pick, option C), image-text redesign and panel auto-hide in v2.3.1; cards hugging the top of the panel in v2.3.2. Remaining if wanted: a dedicated spacing/typography consistency sweep.*
- [ ] **12. Button layout UI/UX review** *(added Nov 17 at Femi's request — look into it later)* — a deliberate pass over button placement and alignment across the panel (card actions, filter rows, menus): what should be centered, grouped, or demoted to a menu. Mock first, Femi picks the direction — same process as the Warm Tint background pick.

## Shipped log

- **v2.3.3** (Nov 17, 2026) — Colour literals: copied `#RGB` / `#RRGGBB` / `#RRGGBBFF` / `rgb()` / `rgba()` / `hsl()` / `hsla()` text files as a colour clip (whole string must be the colour; translucent stays text). Colour card right-click gains Copy as RGB / Copy as HSL. Filter-aware empty states per tab. The last-used filter tab is remembered across relaunches.
- **v2.3.2** (Nov 17, 2026) — Links filter section: segments are now All / Text / Links / Images / Files / Colours, Text shows plain text only. Default panel is a bottom-anchored strip (full screen width, ~half height, above the Dock). Card feed hugs the top of the panel — its height is set by the tallest card.
- **v2.3.1** (Nov 17, 2026) — Panel auto-hides when it loses focus (Preview / Excluded Apps / alerts exempt). Cards top-aligned at natural height. Image cards: "Contains text" chip + one-line teaser, full OCR in Preview with Copy Text / Paste as Text. Frosted Warm Tint panel background.
- **v2.3.0** (Nov 16, 2026) — Horizontal card feed (300pt cards, pinned first), ••• overflow menu, current-clip outline. Confirmed working on Femi's Mac.
- **v2.2.x** (Nov 16, 2026) — Rich link previews, Preview & edit window, card right-click menus, gist-based update checker, source/recency search filters; panel sizing and right-click fixes.
