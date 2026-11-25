// ClipKeep logic tests (v2.14.0).
//
// Built only by run-tests.sh, which CI runs before the app
// build: bash run-tests.sh (it strips the app entry from
// main.swift into a copy, then compiles it with this file).
// The flag compiles out main.swift's app entry point, so the
// @main below is the test runner's entry. The checks cover
// the pure logic — text helpers, colour parsing, hashing,
// the ClipItem model and ClipStore behaviour — the parts a
// compile-only CI could not see break. Any failure exits 1
// and fails the CI run.
import Foundation
import AppKit

var totalChecks = 0
var failedChecks = 0

func check(_ name: String, _ condition: Bool) {
    totalChecks += 1
    if condition {
        print("PASS: \(name)")
    } else {
        failedChecks += 1
        print("FAIL: \(name)")
    }
}

func checkEqual<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    if actual != expected {
        print("  expected: \(expected)")
        print("  actual:   \(actual)")
    }
    check(name, actual == expected)
}

// Theme legibility helpers (Nov 18, 2026) — composite a
// possibly translucent foreground over its background, then
// take the WCAG contrast ratio. This is the math that would
// have caught the Warm Tint footer bug (a white tint on
// white cards) before it shipped.
func contrastRatio(_ fg: NSColor, over bg: NSColor) -> Double {
    func srgb(_ c: NSColor) -> (r: Double, g: Double, b: Double, a: Double) {
        let c = c.usingColorSpace(.sRGB) ?? c
        return (Double(c.redComponent), Double(c.greenComponent),
                Double(c.blueComponent), Double(c.alphaComponent))
    }
    func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    let f = srgb(fg), b = srgb(bg)
    let fgL = luminance(f.r * f.a + b.r * (1 - f.a),
                        f.g * f.a + b.g * (1 - f.a),
                        f.b * f.a + b.b * (1 - f.a))
    let bgL = luminance(b.r, b.g, b.b)
    let (hi, lo) = fgL >= bgL ? (fgL, bgL) : (bgL, fgL)
    return (hi + 0.05) / (lo + 0.05)
}

@main
struct ClipKeepTests {
    static func main() {
        // cleanLinkTitle — entity decoding + whitespace collapse.
        checkEqual("title: numeric entity decoded",
                   cleanLinkTitle("OMI Medical inc &#8211; Programs"),
                   "OMI Medical inc – Programs")
        checkEqual("title: hex entity decoded",
                   cleanLinkTitle("It&#x2019;s here"), "It’s here")
        checkEqual("title: named entities decoded",
                   cleanLinkTitle("Fish &amp; Chips &rsquo;round &mdash; &copy; 2026"),
                   "Fish & Chips ’round — © 2026")
        checkEqual("title: whitespace collapsed",
                   cleanLinkTitle("  A title\n  with   gaps "),
                   "A title with gaps")
        checkEqual("title: plain title untouched",
                   cleanLinkTitle("Just a title"), "Just a title")
        checkEqual("title: bogus entity left alone",
                   cleanLinkTitle("a &#xZZ; b"), "a &#xZZ; b")

        // prettyJSON — pretty-print with sorted keys; nil when
        // the text is not a JSON object/array or would not change.
        let pretty = prettyJSON("{\"b\":1,\"a\":2}")
        check("json: compact object pretty-prints", pretty != nil)
        if let pretty {
            check("json: keys sorted",
                  pretty.range(of: "\"a\"")!.lowerBound < pretty.range(of: "\"b\"")!.lowerBound)
        }
        check("json: invalid text returns nil", prettyJSON("not json") == nil)

        // extractURLs.
        let found = extractURLs("Read https://example.com/a?b=1 and https://swift.org today")
        checkEqual("urls: both found", found.count, 2)
        check("urls: first is the example link", found.first == "https://example.com/a?b=1")
        check("urls: none in plain text", extractURLs("no links at all").isEmpty)

        // trimmedText — lines trimmed, blank runs collapse to one.
        checkEqual("trim: lines trimmed, blank runs collapsed",
                   trimmedText("  hello  \n\n\n\n world \n"), "hello\n\nworld")
        checkEqual("trim: plain text untouched", trimmedText("one line"), "one line")

        // Colour parsing — the whole string must be the colour.
        checkEqual("colour: #RRGGBB round-trips",
                   colorFromLiteral("#FF8000").map { hexString(from: $0) }, "#FF8000")
        checkEqual("colour: #RGB expands",
                   colorFromLiteral("#F80").map { hexString(from: $0) }, "#FF8800")
        checkEqual("colour: rgb() parses",
                   colorFromLiteral("rgb(0, 128, 255)").map { hexString(from: $0) }, "#0080FF")
        checkEqual("colour: hsl() parses",
                   colorFromLiteral("hsl(120, 100%, 25%)").map { hexString(from: $0) }, "#008000")
        check("colour: translucent hex rejected", colorFromLiteral("#FF800080") == nil)
        check("colour: translucent rgba rejected", colorFromLiteral("rgba(255, 0, 0, 0.5)") == nil)
        check("colour: a sentence stays text", colorFromLiteral("the colour #FF8000 is nice") == nil)
        checkEqual("colour: rgbString format",
                   rgbString(from: colorFromHex("#0080FF")!), "rgb(0, 128, 255)")

        // fnvHash — image dedupe depends on its stability.
        checkEqual("hash: stable for same data", fnvHash(Data("abc".utf8)), fnvHash(Data("abc".utf8)))
        check("hash: differs by content", fnvHash(Data("abc".utf8)) != fnvHash(Data("abd".utf8)))

        // ClipItem — Codable round trip + derived properties.
        let item = ClipItem(id: "t1", kind: "text", text: "hello", imageFile: nil,
                            createdAt: 123.5, pinned: true, filePath: nil,
                            sourceApp: "Safari", sourceBundleID: "com.apple.Safari",
                            ocrText: nil, board: "B", contentHash: nil)
        let encoded = try! JSONEncoder().encode(item)
        let decoded = try! JSONDecoder().decode(ClipItem.self, from: encoded)
        check("codable: fields survive the round trip",
              decoded.id == "t1" && decoded.kind == "text" && decoded.text == "hello"
                  && decoded.pinned && decoded.board == "B" && decoded.createdAt == 123.5)
        checkEqual("item: preview is the text", item.preview, "hello")
        check("item: pinned counts as a keeper", item.isKeeper)

        // ClipStore — insert order, dedupe rules, persistence,
        // trim. Runs against the CI runner's Application
        // Support folder, which starts empty.
        UserDefaults.standard.set(200, forKey: "historyLimit")
        let store = ClipStore()
        func textItem(_ id: String, _ text: String, pinned: Bool = false) -> ClipItem {
            ClipItem(id: id, kind: "text", text: text, imageFile: nil, createdAt: 1,
                     pinned: pinned, filePath: nil, sourceApp: nil, sourceBundleID: nil,
                     ocrText: nil, board: nil, contentHash: nil)
        }
        store.insert(textItem("a", "first"))
        store.insert(textItem("b", "second"))
        checkEqual("store: newest lands first", store.items.first?.id, "b")
        store.insert(textItem("c", "first"))
        checkEqual("store: duplicate text deduped",
                   store.items.filter { $0.text == "first" }.count, 1)
        checkEqual("store: the deduped copy lands on top", store.items.first?.id, "c")
        store.insert(textItem("pin", "first", pinned: true))
        checkEqual("store: pinned insert replaces the unpinned duplicate",
                   store.items.filter { $0.text == "first" }.count, 1)
        check("store: the survivor is the pinned copy",
              store.items.first { $0.text == "first" }?.pinned == true)
        store.insert(textItem("d", "first"))
        checkEqual("store: a pinned copy survives a later duplicate",
                   store.items.filter { $0.text == "first" }.count, 2)

        store.saveNow()
        let reloaded = ClipStore()
        checkEqual("store: save/load round trip",
                   reloaded.items.map { $0.id }, store.items.map { $0.id })

        store.historyLimit = 1
        checkEqual("store: trim keeps keepers plus the limit", store.items.count, 2)
        check("store: the oldest unpinned clip is dropped",
              !store.items.contains { $0.id == "b" })
        UserDefaults.standard.set(200, forKey: "historyLimit")

        // Sync-ready model (v2.17.0) — origin stamps, updatedAt,
        // tombstones, the v2 file envelope and v1 migration.
        check("sync: inserted clips carry an origin stamp",
              store.items.allSatisfy { $0.originPlatform == "mac" && $0.originDevice != nil })
        check("sync: untouched clips have updatedAt == createdAt",
              store.items.allSatisfy { $0.effectiveUpdatedAt == $0.createdAt })
        check("sync: the trimmed clip left a tombstone",
              store.tombstones.contains { $0.id == "b" })
        check("sync: the tombstone is stamped with the deletion time",
              (store.tombstones.first { $0.id == "b" }?.effectiveUpdatedAt ?? 0) > 1_000_000_000)
        store.saveNow()
        let reloadedSync = ClipStore()
        checkEqual("sync: tombstones survive the v2 save/load round trip",
                   reloadedSync.tombstones.map { $0.id }, store.tombstones.map { $0.id })

        // v1 migration: a bare-array file (no envelope, none of
        // the new fields) decodes as clips with no tombstones,
        // and the missing updatedAt falls back to createdAt.
        let legacyJSON = """
        [{"id":"old1","kind":"text","text":"from v1","imageFile":null,"createdAt":42,"pinned":false}]
        """
        let legacy = ClipStore.decodeHistory(from: Data(legacyJSON.utf8))
        checkEqual("sync: v1 file migrates its clips", legacy.clips.count, 1)
        check("sync: v1 file has no tombstones", legacy.tombstones.isEmpty)
        check("sync: migrated clip's updatedAt falls back to createdAt",
              legacy.clips.first?.effectiveUpdatedAt == 42)

        // Tombstone retention: 31 days old is purged, 1 day kept.
        let purgeNow = 1_700_000_000.0
        let staleStone = textItem("stale", "x").tombstoned(at: purgeNow - 31 * 24 * 60 * 60)
        let freshStone = textItem("fresh", "y").tombstoned(at: purgeNow - 24 * 60 * 60)
        checkEqual("sync: purge drops tombstones past 30 days",
                   ClipStore.purgedTombstones([staleStone, freshStone], now: purgeNow).map { $0.id },
                   ["fresh"])
        check("sync: tombstoned() stamps the deletion time and keeps the id",
              staleStone.effectiveUpdatedAt == purgeNow - 31 * 24 * 60 * 60 && staleStone.id == "stale")

        // Auth core (v2.18.0) — SHA-256, PKCE, the authorize
        // URL, JWT claims, session expiry, base64url. The
        // vectors are the published ones (FIPS 180-4 example,
        // RFC 7636 Appendix B), so a broken digest or encoder
        // fails here instead of at a real sign-in.
        checkEqual("auth: sha256 of abc matches the FIPS vector",
                   sha256Hex(Data("abc".utf8)),
                   "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        checkEqual("auth: RFC 7636 appendix B challenge",
                   pkceChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                   "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let googleURL = AuthConfig.authorizeURL(provider: .google, state: "state-123", challenge: "chal-456")
        check("auth: google authorize URL is built", googleURL != nil)
        if let googleURL {
            let query = URLComponents(url: googleURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func param(_ name: String) -> String? { query.first { $0.name == name }?.value }
            checkEqual("auth: authorize URL carries the Google IdP", param("identity_provider"), "Google")
            checkEqual("auth: authorize URL uses S256", param("code_challenge_method"), "S256")
            checkEqual("auth: authorize URL carries the redirect URI", param("redirect_uri"), "io.starterdev.clipkeep://auth")
            checkEqual("auth: authorize URL carries the state", param("state"), "state-123")
            check("auth: authorize URL has no login hint by default", param("login_hint") == nil)
        }
        // login_hint (v2.18.1): an address typed into the
        // app's email field pre-fills the hosted UI. The hint
        // is strictly percent-encoded in the raw URL — a raw
        // "+" would read as a space to form-style parsers —
        // and an absent or empty hint adds no parameter.
        let hintURL = AuthConfig.authorizeURL(provider: .email, state: "state-123", challenge: "chal-456",
                                              loginHint: "femi+test@example.com")
        check("auth: hinted authorize URL is built", hintURL != nil)
        if let hintURL {
            let hintQuery = URLComponents(url: hintURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            checkEqual("auth: authorize URL carries the login hint",
                       hintQuery.first { $0.name == "login_hint" }?.value, "femi+test@example.com")
            check("auth: login hint is percent-encoded in the raw URL",
                  hintURL.absoluteString.contains("login_hint=femi%2Btest%40example.com"))
        }
        let emptyHintURL = AuthConfig.authorizeURL(provider: .email, state: "state-123", challenge: "chal-456",
                                                   loginHint: "")
        check("auth: empty login hint adds no parameter",
              !(emptyHintURL?.absoluteString.contains("login_hint") ?? true))
        // A hand-built unsigned JWT: header.payload.signature
        // with base64url segments throughout.
        func b64url(_ s: String) -> String { base64URLEncode(Data(s.utf8)) }
        let token = b64url("{\"alg\":\"none\",\"typ\":\"JWT\"}")
            + "." + b64url("{\"sub\":\"user-1\",\"email\":\"femi@example.com\",\"name\":\"Femi Test\"}")
            + "." + b64url("sig")
        let identity = identityFromIDToken(token)
        check("auth: JWT payload decodes to an identity", identity != nil)
        checkEqual("auth: JWT sub extracted", identity?.subject, "user-1")
        checkEqual("auth: JWT email extracted", identity?.email, "femi@example.com")
        checkEqual("auth: JWT name extracted", identity?.name, "Femi Test")

        let session = AuthSession(idToken: token, accessToken: "a", refreshToken: "r",
                                  expiresAt: 2_000, identity: identity!)
        check("auth: session valid before expiry", !session.isExpired(at: 1_999))
        check("auth: session expired at expiry", session.isExpired(at: 2_000))
        check("auth: session needs refresh inside the skew window", session.needsRefresh(at: 1_800))
        check("auth: session fresh outside the skew window", !session.needsRefresh(at: 1_000))

        // Bytes whose standard base64 spelling uses +, / and =.
        let tricky = Data([0xfb, 0xff, 0xfe, 0x00, 0x01])
        let encodedB64 = base64URLEncode(tricky)
        check("auth: base64url avoids +, / and =",
              !encodedB64.contains("+") && !encodedB64.contains("/") && !encodedB64.contains("="))
        checkEqual("auth: base64url round-trips", base64URLDecode(encodedB64), tricky)

        // Retention window (v2.19.0) — the keep-for period
        // beside the count cap. Default 0 = forever, so
        // behaviour is unchanged until a user opts in.
        checkEqual("retention: default is keep forever", ClipStore().retentionDays, 0)
        let retNow = 1_700_000_000.0
        func agedClip(_ id: String, ageDays: Double, pinned: Bool = false, board: String? = nil) -> ClipItem {
            ClipItem(id: id, kind: "text", text: id, imageFile: nil,
                     createdAt: retNow - ageDays * 24 * 60 * 60, pinned: pinned,
                     filePath: nil, sourceApp: nil, sourceBundleID: nil,
                     ocrText: nil, board: board, contentHash: nil)
        }
        check("retention: a 31-day-old clip is past a 30-day window",
              ClipStore.isPastRetention(agedClip("r-old", ageDays: 31), retentionDays: 30, now: retNow))
        check("retention: a 1-day-old clip is inside a 30-day window",
              !ClipStore.isPastRetention(agedClip("r-new", ageDays: 1), retentionDays: 30, now: retNow))
        check("retention: forever (0) never expires a clip",
              !ClipStore.isPastRetention(agedClip("r-old", ageDays: 31), retentionDays: 0, now: retNow))
        check("retention: pinned clips are exempt",
              !ClipStore.isPastRetention(agedClip("r-pin", ageDays: 31, pinned: true), retentionDays: 30, now: retNow))
        check("retention: boarded clips are exempt",
              !ClipStore.isPastRetention(agedClip("r-board", ageDays: 31, board: "B"), retentionDays: 30, now: retNow))

        // End to end through the store: opting into 30 days
        // prunes a 40-day-old unpinned clip on insert (with a
        // tombstone, like any trim), keeps a fresh clip, and
        // keeps an equally old pinned one. Runs last against
        // this store — opting in also sweeps its ancient
        // (createdAt = 1) unpinned test clips.
        let realNow = Date().timeIntervalSince1970
        func liveClip(_ id: String, ageDays: Double, pinned: Bool = false) -> ClipItem {
            ClipItem(id: id, kind: "text", text: id, imageFile: nil,
                     createdAt: realNow - ageDays * 24 * 60 * 60, pinned: pinned,
                     filePath: nil, sourceApp: nil, sourceBundleID: nil,
                     ocrText: nil, board: nil, contentHash: nil)
        }
        store.retentionDays = 30
        store.insert(liveClip("aged-old", ageDays: 40))
        check("retention: a 40-day-old clip is pruned at a 30-day setting",
              !store.items.contains { $0.id == "aged-old" })
        check("retention: the pruned clip left a tombstone",
              store.tombstones.contains { $0.id == "aged-old" })
        store.insert(liveClip("aged-new", ageDays: 2))
        check("retention: a 2-day-old clip survives",
              store.items.contains { $0.id == "aged-new" })
        store.insert(liveClip("aged-pin", ageDays: 40, pinned: true))
        check("retention: a 40-day-old pinned clip survives",
              store.items.contains { $0.id == "aged-pin" })
        store.retentionDays = 0
        UserDefaults.standard.removeObject(forKey: "retentionDays")

        // Theme legibility (Nov 18, 2026) — every theme's
        // footer icon tint, accent and on-accent must stay
        // readable against the surfaces they sit on (WCAG
        // non-text floor, 3:1). Guards the bug class behind
        // the Warm Tint invisible footer icons: a tint that
        // matches its card now fails CI instead of shipping.
        for theme in panelThemes {
            check("theme \(theme.name): icon tint vs card >= 3:1",
                  contrastRatio(theme.iconTint, over: theme.cardBG) >= 3.0)
            check("theme \(theme.name): accent vs card >= 3:1",
                  contrastRatio(theme.accent, over: theme.cardBG) >= 3.0)
            check("theme \(theme.name): on-accent vs accent >= 3:1",
                  contrastRatio(theme.onAccent, over: theme.accent) >= 3.0)
        }

        print("—")
        if failedChecks == 0 {
            print("ALL \(totalChecks) CHECKS PASSED")
        } else {
            print("\(failedChecks) of \(totalChecks) CHECKS FAILED")
        }
        exit(failedChecks == 0 ? 0 : 1)
    }
}
