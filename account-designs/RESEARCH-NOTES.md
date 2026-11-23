# ClipKeep Account + Sync — Research Notes

Researched Sun Nov 22, 2026, as the follow-up pass Femi asked for after the
account-design package: *"research more into anything else that might be
needed to make this work smoothly."* Scope: everything **around** the settled
decisions (AWS — Cognito + API Gateway + Lambda (TS) + DynamoDB + S3;
Google + Apple + email-code sign-in; opt-in Mac account; RN clients later).
Nothing here re-opens those decisions — but three findings below **change how
they get built**, and one is a hard money gate on Apple sign-in.

---

## 1. Must have before building

Hard prerequisites. Items marked 💲 need Femi's money, 🔑 his accounts/action.

1. 💲🔑 **Apple Developer Program membership ($99/yr) — required before
   Sign in with Apple works *anywhere*, in any client.** Creating the App ID,
   the Services ID, and the `.p8` signing key all require the paid program;
   a free Apple ID cannot create any of them
   ([AWS Amplify SIWA guide](https://aws.amazon.com/blogs/mobile/enable-sign-in-with-apple-on-your-app-with-aws-amplify/);
   [sign_in_with_apple package docs](https://pub.dev/packages/sign_in_with_apple)).
   This is the single hard blocker in the whole plan — for Apple sign-in
   only. Google + email-code sign-in can be built and tested without it.
   Enrolment can take up to ~48h, so it should start before it's needed,
   not after.
2. 🔑 **A Google Cloud project** (free) with the OAuth consent screen
   configured and one **Web application** OAuth client for Cognito. No
   verification process, no cost, no waiting period — as long as the scopes
   stay `openid email profile` (all non-sensitive; §2).
3. **Decide the Cognito region before creating the pool — pools cannot move
   regions.** Recommendation: **us-east-1** for everything (pool, API,
   DynamoDB, S3). Reasons: the ACM certificate for a Cognito custom domain
   must be in us-east-1 regardless; SES-for-Cognito identities are
   best-supported there; his existing CLI profile is us-east-2, which is a
   reason to be deliberate, not a reason to put the pool there (§3, §7).
4. **Decide the pool's sign-in shape before creating it — it's immutable.**
   Sign-in identifier type (email as the sign-in alias), username
   case-sensitivity (set **case-insensitive**), and required attributes
   cannot be changed after pool creation; changing them means a new pool
   and a user migration
   ([AWS docs — settings you can't change](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pool-updating.html)).
   Custom attributes can be added later but never removed or renamed.
5. **Decide the hosted-login domain now: `auth.starterdev.io`** (custom
   domain) rather than the default
   `<prefix>.auth.<region>.amazoncognito.com`. The domain is baked into the
   Google redirect URI, the Apple Return URL, every app client's callback
   list, and what users see on the consent screens. Retrofitting it later
   means touching all of those. Needs: an ACM certificate in us-east-1 +
   a DNS-only CNAME in Cloudflare pointing at Cognito's CloudFront alias
   target (§6).
6. **Decide the callback URL scheme now:** Mac (and later RN) sign in via a
   browser flow that returns to `io.starterdev.clipkeep://auth` — the
   reverse-DNS of the bundle ID. It's registered in the Mac's Info.plist,
   in Cognito's per-platform app clients, and later in the Expo app's
   config; changing it later invalidates every registered callback (§4, §6).
7. **One Cognito app client per platform** (Mac / iOS / Android / Web), all
   **public clients (no client secret)** — a secret shipped inside an app
   binary is extractable and buys nothing. Per-platform clients allow
   per-platform token lifetimes, refresh rotation, and callback lists.
8. **SES production access request — needed before real users, not before
   building.** Cognito's built-in sender is capped at **50 emails/day per
   account**, hard limit, from `no-reply@verificationemail.com`
   ([AWS Cognito email settings](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-email.html)).
   Email one-time codes ride on that sender, so 50/day is the ceiling until
   the pool sends through his own SES identity. New SES accounts start in
   the sandbox (verified recipients only, 200/day); production access is a
   support request (typically ~24h, occasionally asks follow-up questions).
   Also: if he ever wants to email users who chose Apple **Hide My Email**,
   the sending domain must be registered under **Sign in with Apple for
   Email Communication** in the Apple portal, with SPF/DKIM passing —
   Apple's relay bounces mail from unregistered sources (§1).
9. **A privacy policy page on a public URL before any store submission —
   and honestly before real users.** Storing users' clipboard contents
   server-side is the most sensitive data class the app has ever held.
   Google OAuth branding, the Play Data Safety form, and App Store
   submission all require the URL; the policy must cover what's stored
   (clip contents), where, retention/deletion, and the account-deletion
   route (§7).
10. **Google Play developer account ($25) and Apple membership (item 1)**
    before *store* builds of the RN apps — not needed for development,
    sideloading, or TestFlight-less testing. Already known; listed for
    completeness.

**Not needed before building** (explicitly): no notarization/Developer ID
for the Mac web-flow sign-in (§4); no Google verification (§2); no custom
domain certificate money (ACM is free); no E2EE for v1 (conscious deferral,
§7); no push-notification infrastructure; no separate "devices service"
(§5); no IaC migration path worries if the stack starts as code (§7).

---

## 2. Changes to the plan

Anything the research says to do differently from the current design/research
docs, with the reason.

1. **All clients — including the Mac — sign in through Cognito's OAuth web
   flow, not native provider SDKs.** Cognito *user pools* cannot consume a
   native Sign in with Apple credential: AWS's own team has stated user-pool
   Apple support is Hosted-UI (web flow) only, and a native
   `ASAuthorization` token has no user-pool API to land in
   ([aws-sdk-ios issue #2633](https://github.com/aws-amplify/aws-sdk-ios/issues/2633);
   the workarounds in the wild are custom-auth Lambda stacks that validate
   Apple/Google JWTs themselves and mint Cognito tokens via
   `AdminInitiateAuth` — e.g. [nickjones.tech](https://nickjones.tech/aws-cognito-siwa-native/)).
   **Do not build the custom-auth route for v1** — it's a second auth
   system to secure and maintain. The web flow inside
   `ASWebAuthenticationSession` (Mac) / `expo-auth-session` (RN) is the
   system browser sheet users already trust, it needs **no entitlement and
   no special signing on the Mac**, and one flow serves Google, Apple, and
   email-code identically on every platform.
   *Design consequence:* the mocks' Apple/Google buttons stay exactly as
   drawn — but tapping one opens the system auth sheet rather than a native
   Apple ID sheet. On the Mac that's invisible in a static mock; nobody
   needs to redraw anything.
2. **Email one-time code is now a native Cognito feature — drop the
   custom-auth-Lambda plan if it was ever assumed.** Since Nov 2024,
   Cognito's **Essentials** plan (the default for new pools) includes
   passwordless first-factor sign-in with email/SMS one-time codes and
   passkeys; no Define/Create/Verify-challenge Lambda trio is needed
   ([AWS tier summaries](https://jayendrapatil.com/category/aws/cognito/);
   [Seamless Auth comparison, checked Oct 2026](https://docs.seamlessauth.com/compare/cognito/)).
   Essentials' free tier covers the first 10,000 monthly active users, so
   this costs $0 at ClipKeep's scale. Two corollaries: create the pool on
   **Essentials, not Lite** (Lite has no passwordless), and passkeys become
   a nearly-free future add-on on the same plan.
3. **Add a server-assigned sequence number to sync; stop trusting client
   clocks for ordering.** The current plan keys delta pulls and
   last-writer-wins on client-stamped `updatedAt`. Client clocks skew —
   a phone 30s behind or a Mac with a stale clock silently wins/loses
   conflicts, and a delta cursor on wall-clock time can skip changes
   ([offline-sync design write-up](https://medium.com/@msujithr/how-we-designed-offline-sync-for-any-data-model-0079bd4bea2f)).
   Fix, cheap at this scale: the server stamps every accepted write with a
   **per-user monotonic `rev`** (atomic counter) and its own
   `serverUpdatedAt`. Delta pull = "everything with `rev` > my watermark".
   Keep client `updatedAt` for display and as the LWW input, but resolve
   write conflicts with a **conditional write** (accept only if the
   incoming `updatedAt` ≥ stored, else return the stored version for the
   client to reconcile). Details in §5.
4. **Account linking must be designed, not defaulted — and Apple must never
   be auto-linked by email.** Cognito creates a *separate user per
   provider* by default, even for the same email. Plan the PreSignUp
   auto-link for Google ↔ email-code (both prove control of the same
   verified inbox), and make Apple link **only by provider `sub` or via an
   explicit "Connect Apple" action while signed in** — because Hide My
   Email returns a `@privaterelay.appleid.com` address that will never
   match the person's Google/email identity. AWS's own Apple-IdP doc says
   this outright: *"don't link accounts across identity providers by email
   when Apple is involved — link by the provider `sub` instead"*
   ([AWS — Add Sign in with Apple as a social IdP](https://docs.aws.amazon.com/hi_in/cognito/latest/developerguide/cognito-user-pools-social-idp-apple.html)).
   Full strategy and its takeover caveats in §3.
5. **Put the whole backend in us-east-1, not his CLI default us-east-2.**
   Custom-domain ACM certs must be us-east-1; SES identities for Cognito
   are restricted to a small region set (us-east-1 / us-west-2 / eu-west-1
   for cross-region configs); one region for pool + API + tables removes
   a class of cross-region surprises. The `starterdev` CLI profile's
   default region is not a commitment — set the region explicitly in the
   IaC stack.
6. **Account deletion is a v1 backend endpoint, not a later nicety — and
   Play will also require a public web deletion page.** Apple's Guideline
   5.1.1(v) applies to *App Store* apps (the RN iOS app; the
   direct-download Mac app is outside its scope — §4), and Google Play
   requires **both** an in-app path **and a web link** where deletion can
   be requested
   ([Play account-deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en)).
   One `DELETE /account` Lambda (wipes DynamoDB rows, S3 objects, the
   Cognito user, and revokes Apple tokens server-side) serves every
   client plus a simple web page. The designs already carry a Delete
   Account row — this makes it real from day one.
7. **Use API Gateway HTTP APIs, not REST APIs**, for the sync API: same
   Cognito JWT authorizer, ~¼ the per-request price ($1.00 vs $3.50 per
   million), fewer features ClipKeep doesn't need. (General AWS pricing
   knowledge; verify at build time — either is ≈$0 at this scale, so this
   is a default, not a fight.)
8. **Refresh-token rotation ON, with the 60-second retry grace period** —
   and design every client's refresh path to *persist the new refresh
   token before discarding the old one*. Rotation does **not** extend the
   session window: with 30-day validity, the user re-authenticates 30 days
   after first sign-in no matter how often tokens rotate
   ([AWS — refresh tokens](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-refresh-token.html)).
   Recommendation: set refresh validity to **90 days** on the Mac and RN
   clients (a clipboard tool that nags monthly will get sync turned off),
   keep access/ID tokens at the 1-hour default.

---

## 3. Build checklist

Ordered. AWS side first, then the Mac client. (No resources were created
during this research — this is the plan, not a log.)

### AWS side

- [ ] Start Apple Developer Program enrolment ($99/yr) — the long pole;
      everything Apple waits on it. (Femi's action.)
- [ ] Create the Google Cloud project; configure the consent screen
      (External, app name ClipKeep, support email, privacy-policy URL when
      it exists); add scopes `openid`, `userinfo.email`, `userinfo.profile`
      — and nothing else, ever, without re-reading §2.
- [ ] Scaffold the IaC project (CDK, TypeScript — §7) with the region
      pinned to us-east-1; one stack: pool, clients, domain, API, Lambdas,
      table, bucket.
- [ ] Create the user pool on the **Essentials** plan with the immutable
      choices made deliberately: email as sign-in alias, case-insensitive
      usernames, `email` + `name` as the only required attributes, self
      sign-up on, passwordless (email OTP) enabled, no SMS anything.
- [ ] Create four public app clients (mac / ios / android / web): auth code
      + PKCE, refresh rotation on (60s grace), refresh validity 90 days
      (web: 30), callbacks per §6.
- [ ] Configure the custom domain `auth.starterdev.io`: ACM cert in
      us-east-1 (DNS validation via Cloudflare), Cognito domain, Cloudflare
      CNAME (DNS-only, proxy OFF) to the alias target.
- [ ] Add the Google IdP to the pool: Web-application client ID/secret from
      Google, scopes `openid email profile`, attribute mapping
      `email→email`, `name→name`, `sub→username`. In Google's console, the
      authorized redirect URI is exactly
      `https://auth.starterdev.io/oauth2/idpresponse`.
- [ ] Write and attach the **PreSignUp linking Lambda** (§3 of the
      question sections): on `PreSignUp_ExternalProvider`, if a native or
      Google user exists with the same **verified** email and the provider
      is Google, `AdminLinkProviderForUser` and suppress the duplicate
      sign-up; if the provider is Apple, never link by email. Log every
      link decision to CloudWatch.
- [ ] (After Apple enrolment) Create the Apple identifiers: primary App ID
      (bundle `io.starterdev.clipkeep`, Sign in with Apple capability on),
      a Services ID as the Cognito client ID with Return URL exactly
      `https://auth.starterdev.io/oauth2/idpresponse`, and a Sign in with
      Apple key (`.p8` — download once, store in Secrets Manager/SSM, never
      in the repo). Add the Apple IdP to the pool with Services ID + Team
      ID + Key ID + private key (Cognito generates the client-secret JWT
      itself; max JWT life is 6 months and Cognito handles regeneration —
      but if the key is ever revoked/replaced, the IdP config must be
      updated or Apple sign-in breaks with `invalid_client`).
- [ ] SES: verify the sending domain (e.g. `starterdev.io`) in SES
      us-east-1 with DKIM + SPF; request production access; point the
      pool's email configuration at SES (DEVELOPER mode). Register the
      same domain in Apple's portal for email communication (relay mail).
- [ ] DynamoDB: one table, on-demand billing, **point-in-time recovery
      ON** (§5/§7). Keys per §5.
- [ ] S3 images bucket: versioning ON, default encryption, block public
      access; lifecycle rule expiring noncurrent versions after 30 days.
- [ ] API + Lambdas: `GET /sync/changes?since=<rev>`, `PUT /sync/clips/{id}`,
      `DELETE /sync/clips/{id}` (tombstone write), `POST /sync/images/sign`
      (presigned PUT/GET), `POST /devices/heartbeat`, `DELETE /account`.
      Cognito authorizer on everything; the caller's `sub` — never a
      client-supplied user id — scopes every query.
- [ ] CloudWatch: log retention 30 days on every Lambda log group; a
      billing alarm at a low threshold (e.g. $5) even though expected
      spend is $0 — the account has expiring credits and other tenants.
- [ ] Publish the privacy policy + account-deletion web page (one static
      page can host both) and wire their URLs into Google branding, Cognito
      managed-login footer if used, and the app Settings.

### Mac client

- [ ] Register the URL scheme `io.starterdev.clipkeep` in Info.plist
      (build.sh heredoc) — one line, do it in the same release as the
      Account tab so the scheme is never squatted inconsistently.
- [ ] Build the Account tab (Settings) + panel Sync view UI against a
      stubbed auth service (signed-out / signed-in / error states) — this
      can start **today**, before any AWS resource exists.
- [ ] Implement the Cognito client skeleton: build the authorize URL
      (custom domain, Mac app client, PKCE S256, `state`), present it in
      `ASWebAuthenticationSession` anchored to the Settings/panel window,
      exchange the code at `/oauth2/token`, parse the ID token for
      `sub`/email/name.
- [ ] Keychain token store: one item per token, accessibility
      `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — tokens must not
      roam via iCloud Keychain or migrate to a different Mac (§4).
- [ ] Refresh loop: on launch and on 401, refresh once (single-flight),
      persist rotated tokens atomically, on `NotAuthorizedException` fall
      back to signed-out state with a "Sign in again" row — never a modal.
- [ ] Sign-out semantics: **local by default** — revoke the refresh token
      (`/oauth2/revoke`) and clear the Keychain; Cognito's global sign-out
      stays a server-side option, not the button's behaviour (§4).
- [ ] Wire Delete Account to `DELETE /account`, then local sign-out +
      history-untouched messaging (deleting the account must not delete
      the local-only history without saying so — copy decision for the
      confirm sheet).
- [ ] Sync engine behind the existing transport interface: outbox table
      (in the history store), push-then-pull cycle on launch/foreground/
      mutation-debounce, `rev` watermark persisted in UserDefaults,
      tombstones applied before clip upserts, images via presigned URLs
      with the content-hash as the dedupe key.

---

## 4. Question 1 — Apple sign-in prerequisites

**(a) Natively in the macOS app.** Native Sign in with Apple
(`ASAuthorization`, macOS 10.15+, so the macOS 11 floor is fine) requires:
a paid Developer Program membership; an App ID for `io.starterdev.clipkeep`
with the **Sign in with Apple capability** enabled; the
`com.apple.developer.applesignin` entitlement in the app, which in turn
requires a provisioning profile carrying that capability — i.e. real
Developer ID signing, not ad-hoc
([sign_in_with_apple docs](https://pub.dev/packages/sign_in_with_apple);
[Kodeco tutorial](https://www.kodeco.com/4875322-sign-in-with-apple-using-swiftui)).
**And it still wouldn't work with Cognito user pools** — see Plan Change 1.
There is also a distribution trap in the wild: multiple sources report
notarization friction for Developer-ID apps carrying the SiWA entitlement
outside the Mac App Store; the sourcing there is weaker (tutorial sites,
not Apple docs), so treat it as "unverified, another reason not to go
native on the Mac" rather than a hard fact.

**(b) Through Cognito federation (the route every ClipKeep client will
actually use).** Four artifacts, all from the paid portal
([AWS — Apple IdP in Cognito](https://docs.aws.amazon.com/hi_in/cognito/latest/developerguide/cognito-user-pools-social-idp-apple.html)):
a primary **App ID** (SiWA capability on), a **Services ID** (becomes the
OAuth client ID), a **private key** (`.p8`, with its Key ID), and the
**Team ID**. The Services ID's Web Authentication configuration takes the
domain and the **Return URL**, which for Cognito is exactly
`https://<your Cognito domain>/oauth2/idpresponse`. Cognito is given the
private key and generates Apple's client-secret JWT itself (ES256, max
6-month life) — no manual secret rotation, but a revoked/replaced key must
be updated in the IdP config. Scopes requested: `email name`. Note Apple
returns the user's **name only on the first sign-in** — capture it then or
never. **Paid membership: yes, unconditionally** — the free account cannot
create the Services ID or the key.

**Can the Mac use native while others use the web flow against the same
pool?** No — not against a user pool. Native produces an Apple identity
token; user pools have no endpoint that accepts it (identity *pools* do,
but ClipKeep isn't using identity pools, and bolting one on means owning
user profiles in DynamoDB anyway). The custom-auth Lambda pattern exists
and works (Plan Change 1) but is deliberately deferred. Uniform web flow
everywhere is the smooth path; the user-visible difference on the Mac is
nil because `ASWebAuthenticationSession` presents Apple's own pages.

**Review/branding rules that affect the mocks.** App Store Guideline 4.8:
an app offering a third-party/social login for its primary account must
offer an equivalent option — SiWA is the standard way to satisfy it (this
binds the *iOS* app at review; the Mac web flow still presents Apple
correctly). Apple's HIG: display the SiWA button **prominently — no smaller
than other sign-in buttons, no scrolling to reach it; in a stacked layout,
place it above the others**
([HIG — Sign in with Apple](https://github.com/valentinllpz/apple-human-interface-guidelines/blob/HEAD/references/sign-in-with-apple.md)).
The current signed-out mock already stacks **Apple above Google at equal
size** — it is compliant as drawn; keep that order on every platform's
mock, including Android (not legally required there, but consistency is
free). Use Apple's official button artwork/colours (black button on light
backgrounds) and Google's official "G" — both mocks already do.

**Checklist**
- [ ] Enrol in the Developer Program before any Apple-dependent build task.
- [ ] Create App ID → Services ID → key, in that order; store the `.p8` in
      a password manager/Secrets Manager the moment it's downloaded (it's
      a one-time download).
- [ ] Group future App IDs (iOS app) under the same primary App ID so
      Apple's per-team user identifier (`sub`) is the same person across
      Mac/iOS — this is what makes Apple linking by `sub` work at all.
- [ ] Keep Apple first + equal-size in every sign-in mock.

## 5. Question 2 — Google sign-in prerequisites

Setup is the lightest of the three providers. In Google Cloud Console
(now under **Google Auth Platform**): create a project, set the audience
to **External**, fill branding (app name, support email, home/privacy
URLs, authorized domains), set **Data Access** scopes to exactly `openid`,
`https://www.googleapis.com/auth/userinfo.email`,
`https://www.googleapis.com/auth/userinfo.profile`, and create one
**Web application** OAuth client whose authorized redirect URI is the
Cognito domain's `https://auth.starterdev.io/oauth2/idpresponse`
([Google Auth Platform walkthrough](https://pewterkit.com/guides/google-oauth-consent-screen);
[AWS builder guide](https://builder.aws.com/content/3ItVAqKqSvgDE7tGapSRza1rTLr/unlock-seamless-logins-how-oauth-powers-aws-login-with-google)).

**Verification:** those three scopes are classified **non-sensitive**, so
there is **no Google verification review, no 100-user cap, and no
"unverified app" warning** for sign-in-only use — the cap/warning regime
applies to sensitive and restricted scopes
([Nylas Google guide](https://developer.nylas.com/docs/provider-guides/google/create-google-app/)).
This is a discipline constraint, not a one-time fact: the day anyone adds
a Google scope beyond identity (Drive, Gmail…), the project falls into
verification (and restricted scopes add a paid security assessment). The
Cognito federation itself only ever asks Google for identity scopes, so
the risk is someone reusing this Cloud project for another feature —
don't; keep the project single-purpose.

**Costs/timeline traps:** none for setup (free, minutes; redirect-URI
changes can take 5 minutes to a few hours to propagate — the classic
`redirect_uri_mismatch` debugging tax). Client type matters: it must be
**Web application** (Cognito is a server-side confidential client in this
flow and holds the secret) — not an iOS/Android/Desktop client. The client
**secret lives only in the Cognito IdP config / IaC secrets**, never in
any app binary.

**Checklist**
- [ ] One Web-application OAuth client; redirect URI exactly the Cognito
      `/oauth2/idpresponse` on the final custom domain (add the default
      `amazoncognito.com` domain variant too if testing before the custom
      domain lands — then remove it).
- [ ] Scopes frozen at the three identity scopes; project used for nothing
      else.
- [ ] Map attributes in Cognito: `email→email`, `name→name`, and confirm
      `email_verified` arrives true (the linking Lambda depends on it, §3
      of the questions — next section).

## 6. Question 3 — Cognito federation gotchas

**Separate users by default.** Each provider sign-in creates its own user
(`Google_<id>`, `SignInWithApple_<id>`, plus the native user from email
OTP), each with a different `sub` — and since ClipKeep's data will be keyed
by `sub`, an unlinked duplicate means a *second, empty clipboard history*.
Linking is therefore load-bearing, not polish
([account-linking guide](https://bobbyhadz.com/blog/aws-cognito-link-user-accounts);
[CDK + PreSignUp walkthrough](https://www.playingaws.com/tutorials/add-google-sign-in-to-cognito-with-account-linking/)).

**The working strategy** is a **PreSignUp Lambda** on
`PreSignUp_ExternalProvider`: look up users by email; if exactly one
existing user has that email **and the incoming provider email is
verified**, call `AdminLinkProviderForUser` (destination = existing user,
source = provider identity) and throw to suppress the duplicate sign-up,
so the person lands in their original account. Rules that make it safe:
- Only auto-link **Google** (verified Gmail/inbox control ≈ the same proof
  as the email OTP) and only when `email_verified` is true.
- **Never auto-link Apple by email.** Hide My Email yields a per-app relay
  address that matches nothing; even "Share My Email" gives an address
  whose verified-ness semantics differ (Apple's `email_verified` can
  arrive as the *string* `"true"` — parse defensively). Apple identities
  link (a) automatically by Apple `sub` on repeat sign-ins to the same
  user, and (b) across accounts only via an explicit **Connect Apple**
  action taken while signed in (a Settings row — worth adding to the
  Account tab design), where the signed-in session is the proof.
- **Takeover caveat, stated plainly:** auto-linking on email alone trusts
  the provider's verification. The dangerous direction is an attacker who
  first creates a *native* account with the victim's email — mitigated
  here because the native route is email-OTP (creating it proves inbox
  control) rather than an unverified password sign-up. Keep it that way:
  **never enable unverified native sign-up** in this pool.
- Linking requires the destination to be a native (or previously linked)
  user and can't merge two already-populated federated users cleanly —
  another reason to link at *first* federated sign-in (PreSignUp), not
  after the fact.

**Email one-time code.** Now native (Plan Change 2): on Essentials,
passwordless email OTP is a first factor — no custom challenge Lambdas.
The user it creates is a **native** Cognito user, i.e. exactly the kind
that federated identities link *into* — so no, it doesn't create a third
*unlinkable* identity; it's the natural home account the others attach to.
Costs: Cognito MAU pricing (free to 10,000 MAU on Essentials) + email
delivery — Cognito's built-in sender (50/day/account, from
`no-reply@verificationemail.com`) until the pool is switched to his SES
identity (SES ≈ $0.10 per 1,000 emails; sandbox starts at 200/day to
verified addresses only, production access lifts recipient restrictions).
Budget-wise: $0 for the foreseeable life of this app, with the 50/day
ceiling being the only real constraint to engineer around (it also caps
*testing* — a day of heavy auth testing can exhaust it; another reason to
move to SES early).

**Token lifetimes & refresh.** Defaults: ID/access tokens 1 hour (range
5 min–24 h); refresh token 30 days (range 60 min–10 years), per app
client. Rotation is opt-in per client; rotated tokens keep the *original*
expiry window (no sliding renewal)
([AWS — refresh tokens](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-refresh-token.html)).
For a menu-bar app: refresh lazily on 401 + proactively at launch; expect
a full re-sign-in when the refresh window lapses and design it as a quiet
state change ("Sync paused — sign in"), never a surprise dialog. For RN:
same flow via the token endpoint; `expo-secure-store` holds the refresh
token.

**Hosted UI vs direct OAuth endpoints.** Recommendation: use Cognito's
**managed login** pages (Essentials' branded hosted UI) as the surface
inside the browser sheet on every platform, rather than hand-building
provider buttons that deep-link `identity_provider=Google|SignInWithApple`
to skip it. Managed login is what makes email-OTP a form field instead of
a client-side challenge protocol, it renders all three providers
consistently, and its branding editor is adequate for a sign-in sheet.
The app still controls the entry (its own buttons open the sheet) — what
it gives up is pixel control of the sheet's interior, which the current
mocks never promised anyway. Either way the mechanics are identical:
authorize URL + PKCE S256 + `state`, code exchange at `/oauth2/token`,
tokens to the Keychain/SecureStore.

**Checklist**
- [ ] Pool on Essentials; passwordless email OTP on; SMS off everywhere.
- [ ] PreSignUp linking Lambda with the Google-only, verified-only,
      Apple-never-by-email rules; unit-test the relay-email case.
- [ ] "Connect Apple / Connect Google" rows added to the Account tab spec
      (explicit linking while signed in) — the recovery path for every
      auto-link miss.
- [ ] Refresh: rotation on, 60s grace, 90-day validity (native clients).
- [ ] Data keyed everywhere by Cognito `sub`, never by email.

## 7. Question 4 — Mac client integration

**ASWebAuthenticationSession + custom scheme, ad-hoc signed:** works.
`ASWebAuthenticationSession` (macOS 10.15+; the app's floor is 11) needs a
presentation-context window and a callback scheme registered in the app's
Info.plist `CFBundleURLTypes` — registration is a plist declaration, not
an entitlement, and requires **no Developer ID, no provisioning, and no
associated domains**. Associated domains / universal links would need a
Developer ID and an `apple-app-site-association` file; the custom scheme
avoids all of it, at the known theoretical cost that any app could
register the same scheme — mitigated by using the reverse-DNS scheme
(`io.starterdev.clipkeep`), PKCE (the code is useless without the
verifier, which never leaves the app), and `state` validation. His
existing build already hand-writes Info.plist in build.sh, so the scheme
is a few lines in the heredoc. One menu-bar nuance: the session anchors to
a window — present it from the Settings window (or a small dedicated
auth window if invoked from the panel), since the panel is a borderless
`NSPanel` that comes and goes; test the anchor behaviour early.

**Keychain specifics.** Store the three tokens as separate generic-password
items under a service name like `io.starterdev.clipkeep.auth`, with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: *ThisDeviceOnly* items
are excluded from iCloud Keychain sync and from encrypted backups'
migration to a new Mac — a refresh token must not silently roam to
another machine. No keychain access group (that's an App-Groups/Developer
ID feature); the ad-hoc app's items are keyed to the app's identity, with
one sharp edge he has already met in another form: **ad-hoc signing means
the code identity changes between builds** (the v2.16.5 TCC lesson), and
Keychain ACLs for non-signature-anchored apps can prompt or orphan items
across updates. Practical mitigations: keep token reads failure-tolerant
(a missing/unreadable item = signed-out state, not a crash), and expect a
possible one-time re-sign-in after updates until Developer ID signing
lands. Do not store tokens in UserDefaults or the history folder.

**Refresh rotation handling:** on refresh, Cognito returns a *new* refresh
token; write it to the Keychain **before** deleting the old item (or
update in place with `SecItemUpdate`) so a crash mid-refresh doesn't lose
the session; the 60s grace period covers retry races between the panel
and a background sync.

**Sign-out semantics.** The button = **local sign-out**: revoke the
refresh token at `/oauth2/revoke` (so it's dead server-side too), delete
the Keychain items, stop the sync engine, keep local history untouched.
**Global sign-out** (`GlobalSignOut`, invalidates the user on every
device) is a bigger hammer — expose it, if at all, as a separate
"Sign out everywhere" action in Settings, never as the default button.

**Account deletion scope.** Apple's 5.1.1(v) in-app deletion requirement
is an **App Store Review Guideline** — it binds apps submitted to the App
Store (and, since June 2022, requires deleting the account *and its data*
and revoking SiWA tokens via Apple's REST API)
([Apple — account deletion requirement](https://developer.apple.com/news/?id=12m75xbj)).
The Mac app distributed from GitHub is **outside App Review's reach** —
the requirement does not legally apply to it. It applies in full to the
future iOS app, and Play's version (in-app + web link) to the Android app.
Since one backend endpoint serves all clients and the designs already
include the row, build it once, now, for the Mac too — the marginal cost
is one confirm sheet. Server-side deletion must: delete the user's
DynamoDB items + S3 objects, `AdminDeleteUser`, and revoke the Apple
refresh token if an Apple identity is linked (the backend needs the
Apple token captured at link time to do this — one more reason the
linking Lambda should record provider metadata).

**Version constraints:** everything used here — AuthenticationServices,
`ASWebAuthenticationSession`, Keychain Services — is available at the
macOS 11 floor. No bumps needed.

**Checklist**
- [ ] URL scheme + auth-window anchoring spiked before the full Account
      tab is built (half-hour spike, retires the only Mac-side unknown).
- [ ] Keychain: ThisDeviceOnly, per-token items, tolerant reads.
- [ ] Sign-out = revoke + local clear; deletion = server endpoint + local
      clear; copy distinguishes the two.

## 8. Question 5 — Sync engine smoothness

**Ordering & cursors (the important one).** Replace the wall-clock delta
cursor with a **server-assigned per-user sequence**: a small counter item
per user in DynamoDB, incremented with an atomic `ADD` inside the write
path; every clip row and tombstone carries the resulting `rev`. Pull =
query the user's items with `rev > :watermark`, ordered by `rev`,
paginated (below). This makes delta pulls exact under any client clock
skew and gives tombstones a reliable position in the stream. Keep
per-clip LWW on `updatedAt` for *content* conflicts (clipboard edits are
rare and low-stakes), enforced with a conditional write; on condition
failure the API returns the current server version and the client takes
it (server-wins on true simultaneity is the honest tiebreak). Add the
device id as a final tiebreak for equal timestamps so all clients resolve
identically.

**DynamoDB shape.** One table, on-demand:
- Clips: `PK = USER#<sub>`, `SK = CLIP#<clipId>`; attributes = the sync
  schema fields + `rev`, `serverUpdatedAt`, `deleted` (tombstones are
  rows, not a separate table — they ride the same `rev` stream and expire
  via DynamoDB **TTL** at 30 days, matching the Mac's local tombstone
  retention).
- Devices: `SK = DEVICE#<deviceId>` rows in the same table (§ below).
- Counter: `SK = META#SYNC` with `rev` as a number attribute.
- Boards: `SK = BOARD#<name>` rows (boards are names today; rows let an
  empty board sync and give board deletes a tombstone too).
Queries are all single-partition — no GSIs needed in v1, which keeps it
inside the free tier's comfort zone (25 GB storage; on-demand requests at
this scale are pennies — a heavy user is thousands of small writes a
month).

**Pagination.** `GET /sync/changes` returns at most ~200 items or ~1 MB
per page with an opaque `nextCursor` (the last `rev` served); clients
loop until the cursor is absent, persisting the watermark **only after**
a page is fully applied. First sync = `since=0`, same code path.

**Images.** Flow: client computes the sha256 (already the content
address) → `POST /sync/images/sign { sha256, op: put }` → API checks
whether the object already exists (HEAD) → presigned PUT (15-min expiry)
straight to S3, bytes never transit Lambda/API Gateway (which would cap
payloads at 10 MB / 29s anyway). Downloads symmetric: presigned GET, or
the clip payload carries a short-lived GET URL minted during the changes
response. Content-addressing means cross-device dedupe is free and a
re-upload is a no-op. Keep the existing rule: file clips sync metadata
only in v1.

**Offline queue / retry.** The client outbox is the piece to get right:
every local mutation writes an outbox row (clipId + op) in the same local
transaction as the change itself; the sync runner drains it FIFO with
exponential backoff (1s → 5m cap), marks clips dirty until acked, and is
idempotent end-to-end (PUT of a full clip representation; tombstone PUT
likewise) so retries and overlapping runners (foreground + background
task) are harmless. Push-then-pull per cycle; pull applies tombstones
before upserts; a clip edited locally while a pull lands is resolved by
the same conditional-write/LWW rule, not by special-casing.

**Device list / last-seen.** Cognito does **not** track this for you (its
device remembering is an MFA feature, not a registry). The `DEVICE#`
rows above are the registry: each client, on sign-in and on each sync
cycle (throttled to ~hourly), heartbeats `{ deviceId, name, platform,
appVersion, lastSeenAt }` via `POST /devices/heartbeat`; the Account tab
and panel read the same rows the sync API returns in a `GET /devices`
(or piggybacked on the changes response). "This Mac / Galaxy S23+ /
ClipKeep Web" in the designs map 1:1. Stale devices (>90 days) can be
hidden; a "Remove device" action is a row delete (it does not — and
cannot — remotely wipe that device's local history; say so in the UI
copy if the action is offered).

**Cost at small scale.** Effectively $0: Lambda/API/DynamoDB/S3 all sit
inside free tiers or penny ranges at hundreds of users; the design's job
is to *stay* boring (no streams, no Global Tables, no VPC).

**Checklist**
- [ ] Add `rev` + `serverUpdatedAt` to the server-side clip record (the
      on-the-wire clip JSON gains them as server-stamped fields; the
      Mac's v2.17.0 model doesn't need a schema change to *send* its
      fields — the server stamps on write).
- [ ] Tombstones as TTL'd rows in the same table/stream.
- [ ] Outbox-first client design; watermark persisted per account.
- [ ] Device heartbeat endpoint + rows.

## 9. Question 6 — Cross-client consistency

**Expo / RN.** `expo-auth-session`'s `AuthRequest` against the Cognito
authorize endpoint (PKCE is on by default — don't disable it), presented
via `WebBrowser.openAuthSessionAsync` (which is
`ASWebAuthenticationSession` on iOS / Custom Tabs on Android), returning
to the app's scheme. Tokens into `expo-secure-store` (Keychain/Keystore
backed) — **never AsyncStorage/MMKV**, which are plaintext. Decide the
Expo `scheme` in `app.json` **now** and use the same string everywhere:
recommendation — register the full reverse-DNS scheme
`io.starterdev.clipkeep` as the auth callback on all native clients (Mac
Info.plist + Expo scheme + the Cognito app clients' callback lists), so
there is exactly one callback URL pattern to reason about:
`io.starterdev.clipkeep://auth`. (Expo's scheme field accepts this form;
deep links for other features can hang off the same scheme.) Refresh
handling mirrors the Mac: single-flight refresh, persist-rotated-token-
first, quiet signed-out fallback. Note the RN iOS app will *also* satisfy
Guideline 4.8 through this web flow — no `expo-apple-authentication`
native module is required, which keeps the native surface at the
already-planned list from the RN research.

**Web companion.** The Library web app is the odd client (hosted runtime,
its own store). Its smooth route is the plain OAuth code flow against the
same pool with its own web app client (this one *may* be confidential if
it ever gets a real backend; as a pure SPA it's another public client
with PKCE), tokens in memory + refresh in a secure, HttpOnly cookie only
if a small backend exists — flag as a Phase-3 decision. What must be
decided **now** so the web app isn't cornered: its callback URL
(`https://…/auth/callback` on whatever host it ends up on) can be added
to its app client at any time — app-client callback lists are *not*
immutable — so nothing blocks. The reverse is true for the pool-level
choices (§1 items 3–5), which is why those are the now-decisions.

**Decide-now list (the corners):** pool region (us-east-1); sign-in
aliases + case sensitivity; custom domain (`auth.starterdev.io`); the
callback scheme (`io.starterdev.clipkeep://auth`); per-platform app
clients; data keyed by `sub`. Everything else — token lifetimes, callback
URLs per client, SES sender, branding — is adjustable later without
migration.

**Checklist**
- [ ] One scheme string, written into: Mac Info.plist, Expo `app.json`,
      all Cognito app clients, and this document's successors.
- [ ] RN token storage = SecureStore only; add a lint-level rule against
      tokens in MMKV/AsyncStorage when the mobile repo exists.

## 10. Question 7 — Anything else

- **Privacy policy / terms.** Required by: Google OAuth branding (URL
  field), Play's Data Safety section, App Store Connect (privacy policy
  URL + in-app link), and basic honesty — the policy must say clip
  *contents* are stored on AWS when sync is on, that sensitive clips never
  leave the device, retention (tombstones 30 days), and how deletion
  works. Terms of service: a one-page acceptable-use doc suffices at this
  scale. Canadian angle, flagged not advised: PIPEDA applies to a
  Canadian operator storing personal data; data will sit in us-east-1
  (US) — PIPEDA doesn't prohibit cross-border storage for private-sector
  orgs but does require accountability/disclosure, which the policy
  covers. Not legal advice; if ClipKeep ever charges money, get a
  30-minute lawyer review of the policy.
- **Data export.** Build `GET /account/export` (a zip: clips JSON +
  images) into the v1 API list — it's a dozen lines next to the delete
  endpoint, it backs the policy's promises, and "export my data" is the
  request every sync product eventually gets. The Mac's local history is
  already user-owned files; the export is for the *server* copy.
- **SES sending domain.** Verify a dedicated subdomain-ish identity
  (`starterdev.io` domain identity with DKIM) in us-east-1; from-address
  like `no-reply@starterdev.io`. Register the same domain with Apple for
  relay mail (§1). Keep SES for auth mail only — no marketing sending on
  this identity, ever (protects deliverability and the Apple relay
  registration).
- **Logging.** CloudWatch defaults are fine; set 30-day retention
  explicitly (default is *never expire* — a slow cost leak). Hard rule
  for every Lambda: **never log clip contents, tokens, or authorization
  headers** — logs are the easiest place for clipboard data to leak.
  Structured logs with `sub` + `rev` + op are enough to debug sync.
- **Backups.** DynamoDB point-in-time recovery ON (continuous backups,
  ~$0.20/GB-month — cents at this size, and the table holds the only
  server copy of users' histories). S3 versioning ON for images. Cognito
  has **no user export/backup** — the pool is rebuildable from IaC, but
  user *accounts* aren't restorable; that's an accepted AWS-wide fact,
  worth one line in the runbook, not a project.
- **IaC choice for a solo dev: AWS CDK (TypeScript).** SAM is fine and
  simpler for pure Lambda+API, but this stack's fiddly parts are exactly
  Cognito pool/client/IdP wiring, SES config, and IAM grants between
  specific resources — CDK's L2 constructs and `grant*` helpers compress
  those, it's the same TypeScript as the Lambdas, and state lives in
  CloudFormation (no Terraform state file to guard). Terraform is the
  wrong tool here (state management overhead for one AWS account, no
  multi-cloud need on the table). Whichever is chosen: **console-created
  resources are how the immutable-setting mistakes in §1 happen** —
  the pool especially must be born in code.
- **Does NOT need deciding now:** E2EE (the sync format already separates
  routing metadata from payload; encryption can wrap payloads later
  without a schema break — but note the honest consequence: **v1 server
  storage is plaintext clips** under AWS encryption-at-rest, and the
  privacy policy + README wording must say "encrypted in transit and at
  rest", not "end-to-end encrypted", until E2EE actually ships); push
  notifications for sync nudges; multi-region anything; WebSockets/
  realtime (poll-on-foreground is right for clipboard data); a separate
  devices microservice; SMS anything (keep it off — SNS SMS brings its
  own sandbox/spend traps and no ClipKeep flow needs it).

**Checklist**
- [ ] Privacy policy + deletion page drafted before the first external
      tester signs in (not just before store submission).
- [ ] PITR + S3 versioning in the IaC from the first deploy.
- [ ] Log-retention + no-secrets-in-logs as review items on every Lambda.
- [ ] README/privacy wording audit: no E2EE claims until E2EE exists.

---

*Sources are cited inline at each load-bearing claim. Where docs were
ambiguous (notarization + SiWA entitlement friction; exact SES region
matrix for newer Cognito regions), the notes say so rather than
presenting a guess as a fact. Prices/tiers (Cognito Essentials free tier,
SES, ACM) were as published in sources checked Nov 22, 2026 — re-verify
at build time; none of the conclusions change within any plausible
pricing drift.*
