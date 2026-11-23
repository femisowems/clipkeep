# ClipKeep Panel — Sync View Design Notes

Companion to `variations.html` (three signed-in mocks + one signed-out strip).
All variations share the same foundations, tightened against the first drafts:

- **Real panel chrome.** The search row is drawn at true proportions (36pt pill
  field, 32pt avatar and ••• buttons), the search row stays visible in Sync
  mode, and the avatar button is shown *active* — blue ring plus its sync
  status dot — so it reads as the selected tab, not a passive icon.
- **A way back that isn't a guess.** A mode row under the search field carries
  a ‹ Clips back link, a SYNC eyebrow title, and an `esc` keycap hint. (In B
  the rail's Feed tab does this job.)
- **Spacing locked to the app's scale** — 24pt side margins, 20pt card gaps,
  16pt card padding, hairline `#e7dcc8` borders, 14pt card radius, white cards
  on the warm frosted material. Nothing is eyeballed per-variation anymore.
- **A real type scale.** 19pt status headline / 13.5pt identity / 12.5pt body /
  11.5pt secondary / 11pt letterspaced uppercase card titles — replacing the
  first drafts' near-uniform 12–13pt, which made status, identity and fine
  print all compete at the same weight.
- **All four sync states are designed**, not just "Synced" (state-dot legend in
  A, banner tints in C). Delete Account is a first-class row in the account
  card, and the "Sensitive clips never sync" note is promoted from a caption
  to a card or a locked row — it's a product promise, not a footnote.

---

## Variation A — Hero Dashboard

**Idea.** A full-width hero card gives sync status a single glanceable moment —
a progress-ring check, a 19pt "Synced", and the last-sync/clip-count line —
with the toggle and Sync Now grouped at its right edge. Below it, three
feed-style cards (Account · Devices · Privacy & Data) carry everything else at
feed density.

**Improved over the first draft.** The first "feed swap" draft made status one
row inside one of three equal cards; here it owns the top of the view and the
eye lands on it first. The card row now uses the feed's exact 20pt gap and
card language, device rows gained platform subtitles, and the privacy note got
its own card with backend/format facts instead of floating as grey text.

**Trade-off.** The hero spends ~90pt of the 520pt height on one state, and the
four-state legend is documentation-grade — in the shipping UI it collapses to
just the current state. Account actions are text rows, so the view reads
calm/informational rather than button-forward.

## Variation B — Rail Tabs

**Idea.** The panel body gains a 58pt vertical rail — Feed and Sync as icon
tabs, the account avatar anchored at the bottom — making Sync a true panel
tab with a persistent home. Content splits into a fixed 308pt account column
(identity, the local-only reassurance, actions pinned to the bottom) and a
fluid right side: a one-line status strip over a full-width device list.

**Improved over the first drafts.** Neither draft gave Sync a permanent place
in the panel's navigation model; the rail does, and it gives the panel room to
grow (Boards, Settings) without new chrome. The status strip is the densest
treatment of the three — one 15.5pt line — which leaves the device list the
tallest, most comfortable version in any variation.

**Trade-off.** The rail is a structural change, not a view: for consistency it
should also exist in Feed mode, which costs the clip feed ~78pt of width and
makes this the biggest build of the three. It pays off only if more panel
tabs are actually coming.

## Variation C — Banner + Ledger

**Idea.** A slim tinted banner (~46pt) carries status and both controls —
dot, "Sync is on · All devices up to date", Sync Now, toggle — in the visual
language of the Settings-page status-first idea, so panel and Settings agree.
Below it, a wide device *ledger* (52pt rows, two-line right-hand meta: state +
clip count per device) sits beside a compact account stack with the privacy
card underneath.

**Improved over the first drafts.** The overlay-sheet draft squeezed devices
into a 400pt sheet with one-line rows and left the feed's pill tabs visible
underneath as clutter; the ledger gives each device a full row with platform,
state and clip count, and the banner replaces the pills' row entirely. The
account stack is the most compressed here, which is what buys the ledger its
width.

**Trade-off.** Status is scannable but less glanceable than A's hero — it's a
13pt line in a tinted strip, not a moment. Identity gets the least presence of
the three, and the banner's tint is one more colour surface to theme across
warm/midnight/ember/lagoon.

## Signed-out state (shown for Variation A)

The same frame becomes a single centred card: invitation headline, what sync
does in one line (including the sensitive-clips promise), Sign in with Apple
and Sign in with Google buttons (decided Nov 22, 2026 — no password form),
an "or" divider, and an email field with an "Email me a code" passwordless
fallback, with the reassurance "ClipKeep stays fully local if you never
sign in" sitting directly under the form with a lock mark.
The avatar button greys out and swaps its initial for a person glyph — no
status dot, because there is no sync to report. The layout ports unchanged to
B (form replaces the account column) and C (banner turns neutral: "Sync off —
sign in to enable").

---

## Recommendation

**Build Variation A (Hero Dashboard).** It is the only variation that changes
nothing about the panel's existing chrome — the feed keeps its full width and
the Sync view is purely a body swap — while still giving sync status the
glanceability the user asked for when they said "status before settings." It
speaks the feed's card language fluently, fits the 520pt height with air to
spare, and its signed-out form drops into the same frame with no new layout
to learn. Borrow one thing from C when building it: if sync ever errors, A's
hero card should adopt C's tinted-banner treatment (red wash, error line,
Retry button) so the failure state is as designed as the success state. B's
rail is the better long-term answer, but only on the day the panel grows a
third tab — building it now would spend feed width on navigation the app
doesn't yet need.
