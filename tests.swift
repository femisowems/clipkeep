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

        print("—")
        if failedChecks == 0 {
            print("ALL \(totalChecks) CHECKS PASSED")
        } else {
            print("\(failedChecks) of \(totalChecks) CHECKS FAILED")
        }
        exit(failedChecks == 0 ? 0 : 1)
    }
}
