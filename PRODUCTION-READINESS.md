# ClipKeep — production readiness plan

Opened Fri Nov 27, 2026 at Femi's word: get ClipKeep production ready,
with a separate development branch, ahead of online/social marketing.
Ordered as approved — accounts/sync go-live first, then app hardening,
then the marketing push. Source record: `~/workspace/clipkeep-backend/AWS-SETUP-NOTE.md` §6
plus the ROADMAP.

## Branch workflow (from Nov 27, 2026)

- `main` is release-only: it always matches the latest published
  release, so anything marketing points at is the stable build.
- `develop` is the integration branch. All new work lands through
  short-lived feature branches + PRs into `develop` (the Nov 25, 2026
  GitHub Flow adoption, retargeted at `develop`).
- Releases are cut `develop` → `main` through the existing pipeline:
  CI checks green, inner-zip verified, gist feed bumped.

## The list, in order

### Accounts & sync go-live
1. [ ] **Mac sync engine** — backend is deployed and the sync API is
   end-to-end tested (Nov 25), but the app does not sync yet; cloud
   storage is provisioned and empty. Build against pool
   us-east-1_JvBBixLP9 / the deployed API; LWW on server revs,
   tombstones, image presign flow (all API-proven).
2. [ ] **Privacy policy** — written and hosted at a public URL;
   covers accounts and server-side clip storage. Unblocks #3 and
   the marketing landing page.
3. [ ] **Publish the Google consent screen** — needs the homepage +
   privacy-policy URLs from #2. Until then only
   femi.starterdev@gmail.com can sign in (Testing mode).
4. [ ] **SES production access** — Cognito's default sender caps at
   50 emails/day; email-code sign-in needs the production limit.
5. [ ] **AWS Budget + cost-anomaly alerts** — replaces the $20/mo
   spend limit deleted by the Nov 25 activation.
6. [ ] **CDK RemovalPolicy DESTROY → RETAIN** + redeploy the backend
   stack, so an accidental teardown can't take user data with it.
7. [ ] **clipkeep-backend into a private GitHub repo** — the deployed
   backend currently exists only in ~/workspace/clipkeep-backend/.
8. [ ] **Management-account root password + MFA** — Femi's hands
   only (AWS console recommendation from activation day).

### App hardening for strangers
9. [ ] **v2.20.0 — secret detection & auto-expire** (ROADMAP item 5,
   the reserved headline): spot likely API keys/passwords/codes,
   optionally hide from the panel, auto-delete after first paste
   or 24h. Builds on v2.19.0's retention machinery.
10. [ ] **Performance pass** — the Nov 25 approved plan
    (~/workspace/perf-evening-2026-11-25/clipkeep-perf-fix-plan.md),
    parked until v2.19.3 shipped; now unblocked. Headline: gate
    refreshList on panel visibility so a copy anywhere on the
    system stops rebuilding the whole feed.
11. [ ] **Signing & notarization** — DECISION OWED (Femi): the app is
    ad-hoc signed, so new users hit Gatekeeper's "Open Anyway".
    The fix is the paid Apple Developer enrolment + Developer ID +
    notarization. Everything else on this list can proceed without
    it; the marketing push lands better with it.
12. [ ] **Mac confirmation backlog** — checklist steps 26–27 and 32
    (v2.19.4 code-detection) still open; close them in one pass,
    ideally alongside a fresh-user check.

### Marketing (after the above, per Femi's sequencing)
13. [ ] Landing page (features, download → GitHub release, privacy
    policy link — shares #2's hosting).
14. [ ] Launch content: demo clips, screenshots, Product Hunt,
    r/macapps, LinkedIn. Hold the public push until sync (#1) and
    v2.20.0 (#9) have landed, so the first wave gets the real
    product.
