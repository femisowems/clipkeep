# ClipKeep — Mac sync engine: build scope & design

Scoped Fri Nov 27, 2026 against the deployed backend (PRODUCTION-READINESS.md
item 1). The contract below is not aspirational — it is what the live API
does today, read from `~/workspace/clipkeep-backend/lambda/` and proven
end-to-end on Nov 25, 2026 (AWS-SETUP-NOTE.md §7). The Mac app signs in
(v2.19.3/v2.19.4) but does not sync; cloud storage is provisioned and empty.

## 1. The deployed contract

Base: `https://ajiilxo2e6.execute-api.us-east-1.amazonaws.com`, every call
carrying the Cognito **ID token** as a Bearer JWT (HTTP API JWT authorizer;
the `sub` comes from the token, never from the body).

| Route | Shape |
|---|---|
| `GET /sync/pull?sinceRev=N` | → `{ items: StoredClip[], currentRev, nextSinceRev, hasMore }`. Rows with `rev > N`, ascending, tombstones included (`deleted: true` rows in the same stream). Page cap 200; `hasMore` drives continuation. First sync is `sinceRev=0` — same path. |
| `POST /sync/push` | `{ clips: ClipRecord[] }` (1–100) → `{ currentRev, results: [{ id, rev, applied, current? }] }`. Server reserves a contiguous rev range atomically, then writes each clip under an LWW condition on `updatedAt`. A clip that loses gets `applied: false` + the winning stored version in `current` — server wins true simultaneity; device id is the client-side tiebreak for equal timestamps. A delete is a push with `deleted: true` (becomes a TTL'd tombstone, 30 days). |
| `POST /uploads/presign` | `{ sha256, contentType?, ext? }` → `{ exists, key }` or `{ exists: false, key, uploadUrl, expiresIn: 900 }`. Images are content-addressed (`users/<sub>/images/<aa>/<sha256>.<ext>`); bytes PUT straight to S3, never through Lambda. |
| `DELETE /account` | Wipes the Cognito user, all sync rows, all S3 objects. Already wired to the app's delete-account action. |

**ClipRecord** (wire schema 1): `id, kind (text|link|image|file|color),
text?, linkTitle?, image? { file, sha256, width?, height? }, ocrText?,
file? { name, size, bytesSynced }, sourceApp?, sourceId?, createdAt,
updatedAt (seconds, Double — matches the Mac), pinned, board (name|null),
origin { deviceId, platform }, deleted`. Stored rows add `rev` +
`serverUpdatedAt`, which clients never set. Sensitive clips never enter
the format — exclusion happens at capture, and ClipKeep already skips
concealed/transient copies at capture, so nothing extra is needed there.

## 2. Gap found while scoping: no image download leg

Presign mints **PUT** URLs only — there is no route by which a receiving
device can fetch image bytes (the bucket is private). The design intent
(MOBILE-C-RESEARCH §5.4) is lazy download: metadata first, bytes on first
open. That needs one small backend addition before the engine can
complete an image round-trip:

- Extend `POST /uploads/presign` with `{ action: "download", sha256, ext? }`
  → `{ exists, key, downloadUrl, expiresIn }` (GET-signed, caller's own
  prefix derived from the JWT exactly as today), **or** a sibling
  `POST /uploads/download` route. The extend-in-place variant is one
  Lambda edit + one CDK touch (none — same function/route).
- Ship it in the **same backend deploy** as PRODUCTION-READINESS item 6
  (RemovalPolicy DESTROY → RETAIN) so the backend is redeployed once.
- Mac side treats a missing image file as a first-class state: tile
  renders from metadata, bytes fetch lazily on first display/open,
  then cache into the existing images/ store + thumbnail cache.

## 3. Mac engine design

Lives in the app alongside AuthManager (main.swift today; a separate
`SyncEngine.swift` is fine if build.sh picks up the folder — check at
build time; the codebase is one-file by history, not by rule).

**State (persisted, per account):**
- `syncWatermark` — last fully-applied pull rev. Written ONLY after a
  page is fully applied locally (the pull handler's own rule).
- `syncOutbox` — set of clip ids with unpushed mutations. Every local
  mutation path (capture, pin, board, OCR arrival, edit, delete,
  retention purge) enqueues the id; delete enqueues a tombstone record.
- `syncEnabled` already exists (v2.18.0, default off); engine runs only
  when signed in AND enabled.

**Push cycle:**
1. Drain the outbox in batches of ≤100, oldest first.
2. Image clips: hash the local file → presign → PUT if `exists: false`
   → only then include the clip (its `image.file` = the returned key).
   File clips: metadata only in v1 (`bytesSynced: false`; bytes stay on
   the Mac, per the design's v1 deferral).
3. On `applied: false`, adopt `current` wholesale (server wins) and
   refresh that card.
4. Clear outbox ids only for clips the server accepted or superseded.

**Pull cycle:**
1. `sinceRev = watermark`; loop while `hasMore`.
2. Apply in rev order: upsert by id (accept when incoming `updatedAt`
   ≥ local, device-id tiebreak on equality — mirroring the server's
   condition so the two never fight), `deleted: true` → remove locally
   + record the local tombstone (schema v2 already keeps 30-day
   tombstones).
3. Persist the watermark after each fully-applied page.
4. Pulled image clips land metadata-first; bytes lazily (§2).

**Triggers:** sign-in completes; sync toggled on; any local mutation
(debounced ~2s); panel opened (if last sync > 60s ago); manual "Sync
Now" (already in the Sync view). No background timer below 15 min —
clipboard sync is foreground-shaped, and the app is a menu-bar citizen.

**Auth & failure:** ID token from AuthManager; on 401, one silent
refresh + one retry, then stop quietly. Offline / 5xx → outbox and
watermark simply wait; the Sync view shows last-synced time and a
plain-language state (Offline / Syncing… / Up to date / Sign-in
expired). No alerts, ever — sync must never interrupt clipboard work.
Signed-out or disabled = the engine does not exist, exactly as today.

**First sync (existing local history):** pull `sinceRev=0` first (the
account may have clips from the Nov 25 API tests — it doesn't; storage
is empty, but the order matters for every future device), merge, then
push everything local that the server doesn't have. Retention rules
apply locally as today; nothing about sync weakens them.

**Mapping checks at build time:** Mac `kind` ↔ wire kind (link is a
text subtype on the Mac — the wire wants it explicit); Mac board
membership → the wire's single `board` name (confirm the Mac model is
single-board per clip; if multi-board exists anywhere, v1 syncs the
first board and the rest stay local — flag, don't silently drop);
`sourceId` nullability; colour clips carry their hex in `text`.

## 4. Build sequence (new branch workflow)

1. Backend: presign download leg + RemovalPolicy RETAIN, one CDK
   deploy; re-run the Nov 25 §7 test script + a download round-trip.
2. `feature/sync-engine` off `develop`: engine + Sync-view status +
   tests in the existing check suite (the suite is logic-level —
   add the mapping/merge rules there; target the check count growing,
   not just passing).
3. PR into `develop`, CI green; release cut `develop` → `main`
   through the standard pipeline when Femi calls it (this is a
   feature release — v2.21.0 shape, not a patch).
4. Live proof: Femi signs in on the Mac, copies on the Mac, and the
   clip round-trips (verifiable server-side via a pull as his user
   from the CLI — no second device needed for the first proof).

## 5. What this scope deliberately leaves out

Mobile clients (their own programme item), ClipKeep Web sync (v2 per
the research), file-byte sync (v1 metadata only, by design), board
list sync as its own entity (the clip's `board` field carries v1),
conflict UI (LWW is silent by design for clipboard data).
