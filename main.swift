// ClipKeep — a small, private clipboard history manager for macOS.
// Menu bar app: remembers what you copy (text, images, files, colours),
// lets you search it — including the text inside images — file the
// keepers on pinboards, and paste anything back fast (click, ⌘1–⌘9,
// or a Paste Stack). History lives only on this Mac, in
// ~/Library/Application Support/ClipKeep. Items copied as
// concealed/transient (e.g. from password managers) are never recorded,
// and neither is anything copied while an excluded app is frontmost.

import Cocoa
import Carbon
import ApplicationServices
import Vision
import UniformTypeIdentifiers

// MARK: - Model

struct ClipItem: Codable {
    var id: String
    var kind: String          // "text", "image", "file" or "color"
    var text: String?         // text clips; hex string for colour clips
    var imageFile: String?    // PNG filename in the images folder (image clips)
    var createdAt: Double     // seconds since 1970
    var pinned: Bool
    // Added in v2 — all optional so v1 history files still decode.
    var filePath: String?     // file clips
    var sourceApp: String?    // app the clip was copied from
    var sourceBundleID: String?
    var ocrText: String?      // recognized text (image clips)
    var board: String?        // pinboard name, if filed
    var contentHash: String?  // image dedupe
    var linkTitle: String? = nil     // fetched page title (link clips)
    var linkImageFile: String? = nil // fetched preview image filename (link clips)
    var linkChecked: Bool? = nil     // a preview fetch has been attempted

    var preview: String {
        switch kind {
        case "image": return "Image"
        case "file": return filePath.map { ($0 as NSString).lastPathComponent } ?? "File"
        case "color": return text ?? "Colour"
        default:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "(empty)" : t
        }
    }

    var isKeeper: Bool { pinned || board != nil }
}

// MARK: - Store

final class ClipStore {
    let baseDir: URL
    let imagesDir: URL
    let fileURL: URL
    var items: [ClipItem] = []   // newest first

    private let defaults = UserDefaults.standard

    var historyLimit: Int {   // unpinned/unboarded cap; 0 = unlimited
        get { defaults.object(forKey: "historyLimit") as? Int ?? 200 }
        set { defaults.set(newValue, forKey: "historyLimit"); trim(); save() }
    }

    var boards: [String] {
        get { defaults.stringArray(forKey: "boards") ?? [] }
        set { defaults.set(newValue, forKey: "boards") }
    }

    var excludedApps: [String] {   // bundle identifiers
        get { defaults.stringArray(forKey: "excludedApps") ?? [] }
        set { defaults.set(newValue, forKey: "excludedApps") }
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = support.appendingPathComponent("ClipKeep", isDirectory: true)
        imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        fileURL = baseDir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = decoded
            return
        }
        // Lossy fallback: decode clip by clip so one malformed entry
        // can't silently blank the whole history (the strict decode
        // above fails atomically — every clip or none).
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let decoder = JSONDecoder()
            items = raw.compactMap { entry in
                guard let entryData = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
                return try? decoder.decode(ClipItem.self, from: entryData)
            }
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFile else { return nil }
        return imagesDir.appendingPathComponent(name)
    }

    private func deleteImageFile(of item: ClipItem) {
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
        if let name = item.linkImageFile { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name)) }
    }

    // Insert at top, de-duplicating identical unpinned, unboarded clips.
    func insert(_ item: ClipItem) {
        for old in items where !old.isKeeper && sameContent(old, item) {
            remove(old)
        }
        items.insert(item, at: 0)
        trim()
        save()
    }

    private func sameContent(_ a: ClipItem, _ b: ClipItem) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case "text", "color": return a.text != nil && a.text == b.text
        case "file": return a.filePath != nil && a.filePath == b.filePath
        case "image": return a.contentHash != nil && a.contentHash == b.contentHash
        default: return false
        }
    }

    func remove(_ item: ClipItem) {
        deleteImageFile(of: item)
        items.removeAll { $0.id == item.id }
    }

    func clearHistory() {
        for old in items where !old.isKeeper { deleteImageFile(of: old) }
        items.removeAll { !$0.isKeeper }
        save()
    }

    func trim() {
        let limit = historyLimit
        guard limit > 0 else { return }
        var seen = 0
        var kept: [ClipItem] = []
        for item in items {
            if item.isKeeper {
                kept.append(item)
            } else if seen < limit {
                seen += 1
                kept.append(item)
            } else {
                deleteImageFile(of: item)
            }
        }
        items = kept
    }
}

// Top-down document view for the panel's scroll view: with
// isFlipped, the clip list grows downward from the top like a
// normal feed instead of upward from the bottom.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// The card feed's stack view, flipped to match its document view.
// Unflipped, its .top alignment resolved to the VISUAL bottom for
// any arranged view shorter than the stack itself — cards parked
// at the bottom of the panel under a large empty area (Femi's
// Nov 17 Loom demo). Flipped, .top means the visual top.
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// Click target laid over a card: left-click pastes the clip,
// right-click presents the card's context menu. An NSButton
// overlay was used before, but buttons swallow right-clicks
// without ever presenting their menu — the card menu existed
// all along and simply never opened.
final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

// Cheap FNV-1a hash, used to dedupe identical images.
func fnvHash(_ data: Data) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in data {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    return String(hash, radix: 16)
}

func hexString(from color: NSColor) -> String {
    guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
    return String(format: "#%02X%02X%02X",
                  Int(round(c.redComponent * 255)),
                  Int(round(c.greenComponent * 255)),
                  Int(round(c.blueComponent * 255)))
}

func colorFromHex(_ hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                   green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = AppController()

    let store = ClipStore()
    var statusItem: NSStatusItem!
    var panel: NSWindow!
    var searchField: NSSearchField!
    var typeControl: NSSegmentedControl!
    var boardPopup: NSPopUpButton!
    var appPopup: NSPopUpButton!
    var recencyPopup: NSPopUpButton!
    var stackBar: NSStackView!
    var stackLabel: NSTextField!
    var listStack: NSStackView!
    var scrollView: NSScrollView!
    var emptyLabel: NSTextField!
    var exclusionsWindow: NSWindow?
    var exclusionsStack: NSStackView?

    var timer: Timer?
    var lastChangeCount = 0
    var selfWriteChangeCount = -1
    var capturePaused = false
    var hotKeyRef: EventHotKeyRef?
    var stackHotKeyRef: EventHotKeyRef?
    var stackIDs: [String] = []   // Paste Stack queue, first = next out
    var keyMonitor: Any?

    // Segment order matches typeControl's labels. "link" is not a
    // stored kind — link clips are text clips whose text is a URL;
    // the Text segment excludes them so the two stay separate.
    let typeFilters = ["all", "text", "link", "image", "file", "color"]

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "📋"
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        buildPanel()
        checkForUpdate()
        registerHotKeys()
        installKeyMonitor()

        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
    }

    // MARK: Clipboard watching

    func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard !capturePaused else { return }
        guard pb.changeCount != selfWriteChangeCount else { return }

        // Respect password managers and other apps that mark copies
        // as concealed or transient — never record those.
        let types = pb.types ?? []
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let autoGen = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        if types.contains(concealed) || types.contains(transient) || types.contains(autoGen) { return }

        // Where did this copy come from? (The frontmost app when the
        // change is seen — also what the exclusion list keys on.)
        let front = NSWorkspace.shared.frontmostApplication
        let sourceName = front?.localizedName
        let sourceBundle = front?.bundleIdentifier
        if let b = sourceBundle, store.excludedApps.contains(b) { return }

        let now = Date().timeIntervalSince1970

        // Files (copied in Finder) first — a file copy can also carry
        // a text filename, and the file is what the user means.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first {
            if store.items.first?.kind == "file" && store.items.first?.filePath == first.path { return }
            store.insert(ClipItem(id: UUID().uuidString, kind: "file", text: nil, imageFile: nil,
                                  createdAt: now, pinned: false, filePath: first.path,
                                  sourceApp: sourceName, sourceBundleID: sourceBundle,
                                  ocrText: nil, board: nil, contentHash: nil))
            refreshList()
            return
        }

        // Images — saved as PNG, then OCR'd so their text is searchable.
        if let image = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let hash = fnvHash(png)
            if store.items.first?.kind == "image" && store.items.first?.contentHash == hash { return }
            let name = UUID().uuidString + ".png"
            let url = store.imagesDir.appendingPathComponent(name)
            if (try? png.write(to: url)) != nil {
                let id = UUID().uuidString
                store.insert(ClipItem(id: id, kind: "image", text: nil, imageFile: name,
                                      createdAt: now, pinned: false, filePath: nil,
                                      sourceApp: sourceName, sourceBundleID: sourceBundle,
                                      ocrText: nil, board: nil, contentHash: hash))
                refreshList()
                recognizeText(in: png) { [weak self] text in
                    guard let self, let text,
                          let idx = self.store.items.firstIndex(where: { $0.id == id }) else { return }
                    self.store.items[idx].ocrText = text
                    self.store.save()
                    self.refreshList()
                }
            }
            return
        }

        // Colours.
        if let item = pb.pasteboardItems?.first,
           let data = item.data(forType: .color),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            let hex = hexString(from: color)
            if store.items.first?.kind == "color" && store.items.first?.text == hex { return }
            store.insert(ClipItem(id: UUID().uuidString, kind: "color", text: hex, imageFile: nil,
                                  createdAt: now, pinned: false, filePath: nil,
                                  sourceApp: sourceName, sourceBundleID: sourceBundle,
                                  ocrText: nil, board: nil, contentHash: nil))
            refreshList()
            return
        }

        // Plain text.
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if store.items.first?.kind == "text" && store.items.first?.text == text { return }
            let newItem = ClipItem(id: UUID().uuidString, kind: "text", text: text,
                                   imageFile: nil, createdAt: now, pinned: false, filePath: nil,
                                   sourceApp: sourceName, sourceBundleID: sourceBundle,
                                   ocrText: nil, board: nil, contentHash: nil)
            store.insert(newItem)
            refreshList()
            enrichLinkIfNeeded(newItem)
        }
    }

    // On-device text recognition for image clips (Vision). Runs the
    // request off the main thread; the completion lands back on main.
    func recognizeText(in pngData: Data, completion: @escaping (String?) -> Void) {
        let request = VNRecognizeTextRequest { req, _ in
            let text = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            let value = (text?.isEmpty == false) ? text : nil
            DispatchQueue.main.async { completion(value) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(data: pngData, options: [:])
        DispatchQueue.global(qos: .utility).async {
            try? handler.perform([request])
        }
    }

    // MARK: Paste back + Paste Stack

    func writeToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case "text":
            if let text = item.text { pb.setString(text, forType: .string) }
        case "image":
            if let url = store.imageURL(for: item), let img = NSImage(contentsOf: url) {
                pb.writeObjects([img])
            }
        case "file":
            if let path = item.filePath {
                pb.writeObjects([NSURL(fileURLWithPath: path)])
            }
        case "color":
            if let hex = item.text {
                if let color = colorFromHex(hex) { pb.writeObjects([color]) }
                pb.setString(hex, forType: .string)
            }
        default:
            break
        }
        selfWriteChangeCount = pb.changeCount
    }

    // Copy without pasting: the clip goes on the clipboard and the
    // panel stays open. The poller ignores the change because
    // writeToPasteboard records it as our own write.
    func copyBack(_ item: ClipItem) {
        writeToPasteboard(item)
    }

    // Copy plain text only (an image clip's OCR text); the panel
    // stays open, like copyBack.
    func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        selfWriteChangeCount = pb.changeCount
    }

    func pasteBack(_ item: ClipItem) {
        writeToPasteboard(item)
        panel.orderOut(nil)
        simulatePaste()
    }

    // Paste plain text (an image clip's OCR text) the same way:
    // clipboard, panel away, ⌘V into the app underneath.
    func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        selfWriteChangeCount = pb.changeCount
        panel.orderOut(nil)
        simulatePaste()
    }

    // If Accessibility is granted, press ⌘V in the app underneath
    // so the paste lands where the cursor is. Otherwise the content
    // is on the clipboard and a manual ⌘V does it.
    func simulatePaste() {
        if AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                let src = CGEventSource(stateID: .combinedSessionState)
                let vKey: CGKeyCode = 9 // kVK_ANSI_V
                let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
                down?.flags = .maskCommand
                down?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
                up?.flags = .maskCommand
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    func pasteNextFromStack() {
        while let firstID = stackIDs.first {
            stackIDs.removeFirst()
            if let item = store.items.first(where: { $0.id == firstID }) {
                pasteBack(item)
                refreshList()
                return
            }
        }
        refreshList()
    }

    // MARK: Link previews

    var linkFetchesInFlight: Set<String> = []

    // Fetch a link clip's page title and preview image once, in the
    // background, and file them on the item. Runs when a link is
    // copied, and lazily when an unchecked link card is rendered.
    func enrichLinkIfNeeded(_ item: ClipItem) {
        guard isLinkItem(item), item.linkChecked != true,
              !linkFetchesInFlight.contains(item.id),
              let raw = item.text,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        linkFetchesInFlight.insert(item.id)
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            var title: String?
            var imageURL: URL?
            if let data, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                title = self.metaContent(html, keys: ["og:title", "twitter:title"]) ?? self.pageTitle(html)
                if let ref = self.metaContent(html, keys: ["og:image", "twitter:image"]) {
                    imageURL = URL(string: ref, relativeTo: url)?.absoluteURL
                }
            }
            guard let imageURL else {
                self.finishLinkFetch(id: item.id, title: title, imageFile: nil)
                return
            }
            var imgRequest = URLRequest(url: imageURL)
            imgRequest.timeoutInterval = 8
            URLSession.shared.dataTask(with: imgRequest) { [weak self] imgData, _, _ in
                guard let self else { return }
                var imageFile: String?
                if let imgData, imgData.count <= 3_000_000, NSImage(data: imgData) != nil {
                    let name = "link-\(item.id).png"
                    try? imgData.write(to: self.store.imagesDir.appendingPathComponent(name))
                    imageFile = name
                }
                self.finishLinkFetch(id: item.id, title: title, imageFile: imageFile)
            }.resume()
        }.resume()
    }

    private func finishLinkFetch(id: String, title: String?, imageFile: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.linkFetchesInFlight.remove(id)
            guard let idx = self.store.items.firstIndex(where: { $0.id == id }) else { return }
            self.store.items[idx].linkChecked = true
            if let title, !title.isEmpty { self.store.items[idx].linkTitle = title }
            if let imageFile { self.store.items[idx].linkImageFile = imageFile }
            self.store.save()
            self.refreshList()
        }
    }

    private func metaContent(_ html: String, keys: [String]) -> String? {
        for key in keys {
            let patterns = [
                "<meta[^>]+(?:property|name)\\s*=\\s*[\"']\(key)[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"']",
                "<meta[^>]+content\\s*=\\s*[\"']([^\"']+)[\"'][^>]+(?:property|name)\\s*=\\s*[\"']\(key)[\"']"
            ]
            for pattern in patterns {
                if let value = firstCapture(html, pattern: pattern) { return decodeHTMLEntities(value) }
            }
        }
        return nil
    }

    private func pageTitle(_ html: String) -> String? {
        guard let value = firstCapture(html, pattern: "<title[^>]*>([^<]+)</title>") else { return nil }
        return decodeHTMLEntities(value)
    }

    private func firstCapture(_ string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string) else { return nil }
        let value = String(string[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    // MARK: Update checker

    // The keepsake repo is private, so the app cannot read its
    // releases anonymously. A tiny public gist carries the latest
    // version instead; it is bumped as part of each release.
    static let updateFeedURL = "https://gist.githubusercontent.com/femisowems/114759138a0c643983d577960363096a/raw/clipkeep-version.json"
    var availableUpdate: (version: String, url: String)?

    func checkForUpdate() {
        guard let feed = URL(string: AppController.updateFeedURL) else { return }
        var request = URLRequest(url: feed)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latest = obj["latest"] as? String,
                  let url = obj["url"] as? String else { return }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            guard latest.compare(current, options: .numeric) == .orderedDescending else { return }
            DispatchQueue.main.async {
                self.availableUpdate = (latest, url)
                self.refreshList()
            }
        }.resume()
    }

    func updateBanner(version: String) -> NSView {
        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor(red: 0.890, green: 0.945, blue: 1.0, alpha: 1).cgColor
        banner.layer?.cornerRadius = 10
        banner.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "ClipKeep \(version) is available")
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor(red: 0.05, green: 0.30, blue: 0.65, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)
        let download = NSButton(title: "Download", target: self, action: #selector(updateDownloadClicked))
        download.bezelStyle = .rounded
        download.controlSize = .small
        download.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(download)
        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(updateDismissClicked))
        dismiss.bezelStyle = .inline
        dismiss.isBordered = false
        dismiss.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(dismiss)
        NSLayoutConstraint.activate([
            banner.heightAnchor.constraint(equalToConstant: 36),
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            dismiss.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
            dismiss.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            download.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -8),
            download.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: download.leadingAnchor, constant: -8)
        ])
        return banner
    }

    @objc func updateDownloadClicked() {
        if let upd = availableUpdate, let url = URL(string: upd.url) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func updateDismissClicked() {
        if let upd = availableUpdate {
            UserDefaults.standard.set(upd.version, forKey: "dismissedUpdateVersion")
        }
        refreshList()
    }

    // MARK: Preview / edit

    var previewWindow: NSWindow?
    var previewItemID: String?
    var previewTextView: NSTextView?

    @objc func previewClicked(_ sender: NSButton) {
        guard let item = item(for: sender) else { return }
        openPreview(for: item)
    }

    func openPreview(for item: ClipItem) {
        if previewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 420, height: 320)
            previewWindow = window
        }
        guard let window = previewWindow else { return }
        previewItemID = item.id
        window.title = "\(typeLabel(for: item)) — \(relativeTimeString(item.createdAt))"
        window.contentView = previewContent(for: item)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func previewContent(for item: ClipItem) -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14)
        ])
        func fullWidth(_ v: NSView) { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        switch item.kind {
        case "image":
            if let url = store.imageURL(for: item), let img = NSImage(contentsOf: url) {
                let iv = NSImageView(image: img)
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.heightAnchor.constraint(equalToConstant: 300).isActive = true
                stack.addArrangedSubview(iv)
                fullWidth(iv)
            }
            if let ocr = item.ocrText, !ocr.isEmpty {
                // Full OCR text: selectable, in its own scroll view
                // so a long result can't push the buttons off the
                // window. Copy Text / Paste as Text are in the
                // button row below.
                let scroll = NSScrollView()
                scroll.hasVerticalScroller = true
                scroll.borderType = .bezelBorder
                scroll.translatesAutoresizingMaskIntoConstraints = false
                scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
                let textView = NSTextView()
                textView.string = ocr
                textView.font = NSFont.systemFont(ofSize: 12)
                textView.isEditable = false
                textView.isSelectable = true
                textView.isRichText = false
                textView.minSize = NSSize(width: 0, height: 0)
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textView.isVerticallyResizable = true
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.textContainer?.widthTracksTextView = true
                scroll.documentView = textView
                stack.addArrangedSubview(scroll)
                fullWidth(scroll)
                let note = NSTextField(labelWithString: "Text found in this image — select it here, or use Copy Text / Paste as Text below.")
                note.font = NSFont.systemFont(ofSize: 11)
                note.textColor = .secondaryLabelColor
                stack.addArrangedSubview(note)
            }
        case "file":
            if let path = item.filePath {
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 64, height: 64)
                stack.addArrangedSubview(NSImageView(image: icon))
                let name = NSTextField(labelWithString: item.preview)
                name.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
                stack.addArrangedSubview(name)
                let pathLabel = NSTextField(wrappingLabelWithString: path)
                pathLabel.isSelectable = true
                pathLabel.font = NSFont.systemFont(ofSize: 12)
                pathLabel.textColor = .secondaryLabelColor
                stack.addArrangedSubview(pathLabel)
                fullWidth(pathLabel)
            }
        case "color":
            if let hex = item.text, let color = colorFromHex(hex) {
                let swatch = NSView()
                swatch.wantsLayer = true
                swatch.layer?.backgroundColor = color.cgColor
                swatch.layer?.cornerRadius = 10
                swatch.layer?.borderWidth = 1
                swatch.layer?.borderColor = NSColor.separatorColor.cgColor
                swatch.translatesAutoresizingMaskIntoConstraints = false
                swatch.heightAnchor.constraint(equalToConstant: 160).isActive = true
                stack.addArrangedSubview(swatch)
                fullWidth(swatch)
                let hexLabel = NSTextField(labelWithString: hex.uppercased())
                hexLabel.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
                hexLabel.isSelectable = true
                stack.addArrangedSubview(hexLabel)
            }
        default:
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
            let textView = NSTextView()
            textView.string = item.text ?? ""
            textView.font = NSFont.systemFont(ofSize: 13)
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            scroll.documentView = textView
            previewTextView = textView
            stack.addArrangedSubview(scroll)
            fullWidth(scroll)
            let note = NSTextField(labelWithString: "Edit the text and Save, or Paste it as-is.")
            note.font = NSFont.systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let paste = NSButton(title: "Paste", target: self, action: #selector(previewPasteClicked))
        paste.bezelStyle = .rounded
        buttons.addArrangedSubview(paste)
        let copy = NSButton(title: "Copy", target: self, action: #selector(previewCopyClicked))
        copy.bezelStyle = .rounded
        buttons.addArrangedSubview(copy)
        if item.kind == "file" {
            let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(previewRevealClicked))
            reveal.bezelStyle = .rounded
            buttons.addArrangedSubview(reveal)
        }
        if item.kind == "image", let ocr = item.ocrText, !ocr.isEmpty {
            let copyTextBtn = NSButton(title: "Copy Text", target: self, action: #selector(previewCopyTextClicked))
            copyTextBtn.bezelStyle = .rounded
            buttons.addArrangedSubview(copyTextBtn)
            let pasteTextBtn = NSButton(title: "Paste as Text", target: self, action: #selector(previewPasteTextClicked))
            pasteTextBtn.bezelStyle = .rounded
            buttons.addArrangedSubview(pasteTextBtn)
        }
        if item.kind == "text" {
            let save = NSButton(title: "Save changes", target: self, action: #selector(previewSaveClicked))
            save.bezelStyle = .rounded
            buttons.addArrangedSubview(save)
        }
        stack.addArrangedSubview(buttons)
        return content
    }

    private func previewItem() -> ClipItem? {
        guard let id = previewItemID else { return nil }
        return store.items.first { $0.id == id }
    }

    @objc func previewPasteClicked() {
        guard let item = previewItem() else { return }
        previewWindow?.orderOut(nil)
        pasteBack(item)
    }

    @objc func previewCopyClicked() {
        guard let item = previewItem() else { return }
        copyBack(item)
    }

    @objc func previewCopyTextClicked() {
        guard let item = previewItem(), let ocr = item.ocrText else { return }
        copyText(ocr)
    }

    @objc func previewPasteTextClicked() {
        guard let item = previewItem(), let ocr = item.ocrText else { return }
        previewWindow?.orderOut(nil)
        pasteText(ocr)
    }

    @objc func previewRevealClicked() {
        guard let item = previewItem(), let path = item.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func previewSaveClicked() {
        guard let id = previewItemID, let textView = previewTextView,
              let idx = store.items.firstIndex(where: { $0.id == id }) else { return }
        let newText = textView.string
        guard newText != store.items[idx].text else { previewWindow?.orderOut(nil); return }
        let wasLink = isLinkItem(store.items[idx])
        store.items[idx].text = newText
        if wasLink {
            // The URL may have changed — drop the fetched preview
            // and fetch the new page afresh.
            if let name = store.items[idx].linkImageFile {
                try? FileManager.default.removeItem(at: store.imagesDir.appendingPathComponent(name))
            }
            store.items[idx].linkTitle = nil
            store.items[idx].linkImageFile = nil
            store.items[idx].linkChecked = nil
        }
        store.save()
        refreshList()
        if let updated = store.items.first(where: { $0.id == id }) { enrichLinkIfNeeded(updated) }
        previewWindow?.orderOut(nil)
    }

    // MARK: Card context menu

    func cardMenu(for item: ClipItem) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.identifier = NSUserInterfaceItemIdentifier(item.id)
            menu.addItem(mi)
        }
        add("Paste", #selector(menuPaste(_:)))
        add("Copy", #selector(menuCopy(_:)))
        if item.kind == "image", let ocr = item.ocrText,
           !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("Copy Text", #selector(menuCopyText(_:)))
            add("Paste as Text", #selector(menuPasteText(_:)))
        }
        add("Preview / Edit…", #selector(menuPreview(_:)))
        menu.addItem(NSMenuItem.separator())
        add(item.pinned ? "Unpin" : "Pin", #selector(menuPin(_:)))
        let boardItem = NSMenuItem(title: "Move to Board", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let none = NSMenuItem(title: "No board", action: #selector(boardChosen(_:)), keyEquivalent: "")
        none.target = self
        none.identifier = NSUserInterfaceItemIdentifier(item.id)
        none.representedObject = nil as String?
        sub.addItem(none)
        for name in store.boards {
            let mi = NSMenuItem(title: name, action: #selector(boardChosen(_:)), keyEquivalent: "")
            mi.target = self
            mi.identifier = NSUserInterfaceItemIdentifier(item.id)
            mi.representedObject = name
            sub.addItem(mi)
        }
        sub.addItem(NSMenuItem.separator())
        let newB = NSMenuItem(title: "New board…", action: #selector(newBoardChosen(_:)), keyEquivalent: "")
        newB.target = self
        newB.identifier = NSUserInterfaceItemIdentifier(item.id)
        sub.addItem(newB)
        boardItem.submenu = sub
        menu.addItem(boardItem)
        add("Add to Paste Stack", #selector(menuStack(_:)))
        menu.addItem(NSMenuItem.separator())
        add("Delete", #selector(menuDelete(_:)))
        return menu
    }

    @objc func menuPaste(_ sender: NSMenuItem) { if let i = item(for: sender) { pasteBack(i) } }
    @objc func menuCopy(_ sender: NSMenuItem) { if let i = item(for: sender) { copyBack(i) } }
    @objc func menuCopyText(_ sender: NSMenuItem) { if let i = item(for: sender), let ocr = i.ocrText { copyText(ocr) } }
    @objc func menuPasteText(_ sender: NSMenuItem) { if let i = item(for: sender), let ocr = i.ocrText { pasteText(ocr) } }
    @objc func menuPreview(_ sender: NSMenuItem) { if let i = item(for: sender) { openPreview(for: i) } }
    @objc func menuPin(_ sender: NSMenuItem) { if let i = item(for: sender) { togglePin(id: i.id) } }
    @objc func menuStack(_ sender: NSMenuItem) {
        if let f = item(for: sender), !stackIDs.contains(f.id) { stackIDs.append(f.id) }
        refreshList()
    }
    @objc func menuDelete(_ sender: NSMenuItem) {
        if let f = item(for: sender) { store.remove(f); store.save() }
        refreshList()
    }

    func togglePin(id: String) {
        guard let idx = store.items.firstIndex(where: { $0.id == id }) else { return }
        store.items[idx].pinned.toggle()
        store.items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.createdAt > b.createdAt
        }
        store.save()
        refreshList()
    }

    // MARK: Panel UI

    func buildPanel() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 520),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        panel.title = "ClipKeep"
        panel.appearance = NSAppearance(named: .aqua)   // Paste-style light look
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 700, height: 400)
        panel.contentMinSize = NSSize(width: 700, height: 380)
        panel.delegate = self
        // Frame persistence is manual and validated — see
        // restorePanelFrame() below. NSWindow's frame autosave is
        // deliberately not used: it writes whatever the frame happens
        // to be, unchecked, and a degenerate frame saved by an early
        // build (a ~60pt-wide, full-height strip) came back verbatim
        // on every launch and squeezed the whole panel into it.
        // restorePanelFrame() is called at the end of buildPanel —
        // the validated frame must be the last word, applied after
        // the content view and its constraints exist.

        // Frosted vibrancy background (v2.3.1, Femi's pick from the
        // mock: Warm Tint). An NSVisualEffectView replaces the flat
        // light-grey layer: the desktop blurs through the panel,
        // and a translucent cream overlay gives it Paste's warmth.
        // The tint is added first, so every control sits above it.
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = content

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(red: 0.98, green: 0.945, blue: 0.87, alpha: 0.45).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tint.topAnchor.constraint(equalTo: content.topAnchor),
            tint.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        searchField = NSSearchField()
        searchField.placeholderString = "Search history, apps, text inside images…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        typeControl = NSSegmentedControl(labels: ["All", "Text", "Links", "Images", "Files", "Colours"],
                                         trackingMode: .selectOne, target: self, action: #selector(filterChanged))
        typeControl.selectedSegment = 0
        typeControl.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(typeControl)

        boardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        boardPopup.target = self
        boardPopup.action = #selector(filterChanged)
        boardPopup.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(boardPopup)

        appPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        appPopup.controlSize = .small
        appPopup.target = self
        appPopup.action = #selector(filterChanged)
        appPopup.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(appPopup)

        recencyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        recencyPopup.controlSize = .small
        for (title, days) in [("All time", 0), ("Today", -1), ("Last 7 days", 7), ("Last 30 days", 30)] {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.representedObject = days
            recencyPopup.menu?.addItem(mi)
        }
        recencyPopup.target = self
        recencyPopup.action = #selector(filterChanged)
        recencyPopup.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(recencyPopup)

        // Second filter row: board / source app / recency.
        let filterBar = NSStackView(views: [boardPopup, appPopup, recencyPopup])
        filterBar.orientation = .horizontal
        filterBar.spacing = 8
        filterBar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(filterBar)

        // Paste Stack bar (visible only while the stack has items).
        stackLabel = NSTextField(labelWithString: "")
        stackLabel.font = NSFont.systemFont(ofSize: 12)
        let pasteNextButton = NSButton(title: "Paste next", target: self, action: #selector(pasteNextClicked))
        pasteNextButton.bezelStyle = .rounded
        pasteNextButton.controlSize = .small
        let clearStackButton = NSButton(title: "Clear stack", target: self, action: #selector(clearStackClicked))
        clearStackButton.bezelStyle = .rounded
        clearStackButton.controlSize = .small
        stackBar = NSStackView(views: [stackLabel, pasteNextButton, clearStackButton])
        stackBar.orientation = .horizontal
        stackBar.spacing = 8
        stackBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stackBar)

        scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        // Flipped to match the document view — see FlippedStackView.
        listStack = FlippedStackView()
        listStack.orientation = .horizontal
        listStack.alignment = .top
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = FlippedView()
        // This opt-out was missing in every build up to 2.2.1: the
        // document view kept its autoresizing constraints and
        // fought the Auto Layout ones, and AppKit broke a
        // different constraint on each launch — the list came out
        // as a ~60pt strip, zero-height (empty panel), or
        // squished into a corner, while capture worked throughout.
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(listStack)
        scrollView.documentView = clipView
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 12),
            listStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -12),
            listStack.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 12),
            // Equality, not ≤: the document view's height must be
            // driven by the stack's content height. With ≤ the
            // solver was free to collapse the document view to zero
            // height, and every row was clipped away — the panel
            // looked empty while the history on disk was full.
            listStack.bottomAnchor.constraint(equalTo: clipView.bottomAnchor, constant: -12),
            // Horizontal feed: the document view's WIDTH is driven
            // by the cards laid out along it. Its HEIGHT comes from
            // the tallest card, via the stack's top+bottom pins
            // above — deliberately NOT pinned to the viewport. With
            // the viewport pin, a tall panel left the card row
            // sitting low under a large empty area (still visible
            // in Femi's Nov 17 size Loom after v2.3.1). A flipped
            // document view shorter than the viewport anchors to
            // the top, so the cards hug the top and the frosted
            // background shows beneath them.
            clipView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor)
        ])

        emptyLabel = NSTextField(labelWithString: "Nothing here yet — copy something and it will show up.")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        // Paste-style overflow menu: everything that used to live
        // in a footer button row (pause, history limit, excluded
        // apps, clear, quit — plus the version) sits behind one
        // "•••" button beside the search field, leaving the panel
        // to the cards.
        let overflowButton = NSButton(title: "•••", target: self, action: #selector(showOverflowMenu(_:)))
        overflowButton.bezelStyle = .rounded
        overflowButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overflowButton)

        NSLayoutConstraint.activate([
            // The safe area starts below the title bar; anchoring to
            // content.topAnchor put the search field underneath it
            // (the panel uses .fullSizeContentView), where it was
            // hidden except for its focus ring.
            searchField.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -8),

            overflowButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            overflowButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            overflowButton.widthAnchor.constraint(equalToConstant: 44),

            typeControl.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            typeControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            typeControl.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),

            filterBar.topAnchor.constraint(equalTo: typeControl.bottomAnchor, constant: 8),
            filterBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),

            stackBar.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 8),
            stackBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            stackBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: stackBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            // Floors so the content's fitting size can never collapse
            // the window: in 2.0.x the old rows' fitting width was
            // ~60pt and AppKit's constraint-based window sizing shrank
            // the panel to a strip on the first layout pass.
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -48)
        ])

        refreshList()
        restorePanelFrame()
    }

    // MARK: Panel frame persistence (manual, validated)

    // V5: Femi's Nov 17 Loom pick — the default is a bottom-anchored
    // strip, full screen width and about half the screen height,
    // not a window that opens nearly full-screen. New key so the
    // stretched V4 frame saved earlier is retired.
    private let panelFrameKey = "ClipKeepPanelFrameV5"

    private func panelFrameIsUsable(_ f: NSRect) -> Bool {
        guard f.width >= panel.minSize.width, f.height >= panel.minSize.height else { return false }
        return NSScreen.screens.contains { $0.visibleFrame.intersects(f) }
    }

    private func restorePanelFrame() {
        if let saved = UserDefaults.standard.string(forKey: panelFrameKey) {
            let f = NSRectFromString(saved)
            if panelFrameIsUsable(f) {
                panel.setFrame(f, display: false)
                return
            }
        }
        // Default: full visible width, 520 tall, sitting on the
        // bottom of the main screen's visible frame (above the
        // Dock) — the size Femi settled on in his Nov 17 Loom.
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: 520), display: false)
        } else {
            panel.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 520), display: false)
            panel.center()
        }
    }

    private func savePanelFrame() {
        // Only a frame that would pass restore validation is ever
        // written, so a bad size cannot be saved in the first place.
        guard panelFrameIsUsable(panel.frame) else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: panelFrameKey)
    }

    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === panel else { return }
        // Never call setFrame from here. A setFrame triggers a layout
        // pass; the layout pass can resize the window again, and that
        // resize -> setFrame -> layout loop is exactly what made
        // AppKit throw and abort on launch in 2.1.0. Frame correction
        // happens in togglePanel instead, before the panel is shown.
        savePanelFrame()
    }

    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === panel else { return }
        savePanelFrame()
    }

    // Paste behaviour: the panel is a guest. When it loses key
    // status — the user clicked another app, or activated one from
    // the Dock — it steps aside instead of floating over that app's
    // windows (the Nov 17 "can't open anything else" demo). It
    // stays open when one of our own auxiliary windows (Preview,
    // Excluded Apps) takes key, or while a modal alert is up:
    // those are part of using the panel, not leaving it.
    func windowDidResignKey(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === panel, panel.isVisible else { return }
        if NSApp.modalWindow != nil { return }
        if let key = NSApp.keyWindow, (key === previewWindow || key === exclusionsWindow) { return }
        panel.orderOut(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshList()
    }

    @objc func filterChanged() {
        refreshList()
    }

    @objc func limitChosen(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Int {
            store.historyLimit = value
        }
        refreshList()
    }

    // MARK: Filtering + list rendering

    // nil = all boards, "__pinned" = the pinned group, else a board name.
    var boardFilter: String? {
        guard let item = boardPopup?.selectedItem else { return nil }
        return item.representedObject as? String
    }

    var appFilter: String? {
        guard let item = appPopup?.selectedItem else { return nil }
        return item.representedObject as? String
    }

    // nil = all time; -1 in the popup means "today" (start of day).
    var recencyCutoff: Double? {
        guard let days = recencyPopup?.selectedItem?.representedObject as? Int, days != 0 else { return nil }
        if days < 0 { return Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 }
        return Date().timeIntervalSince1970 - Double(days) * 86400
    }

    func rebuildBoardPopup() {
        guard boardPopup != nil else { return }
        let current = boardFilter
        boardPopup.removeAllItems()
        let allItem = NSMenuItem(title: "All boards", action: nil, keyEquivalent: "")
        allItem.representedObject = nil as String?
        boardPopup.menu?.addItem(allItem)
        let pinnedItem = NSMenuItem(title: "📌 Pinned", action: nil, keyEquivalent: "")
        pinnedItem.representedObject = "__pinned"
        boardPopup.menu?.addItem(pinnedItem)
        var names = store.boards
        for item in store.items {
            if let b = item.board, !names.contains(b) { names.append(b) }
        }
        for name in names {
            let menuItem = NSMenuItem(title: "🗂 " + name, action: nil, keyEquivalent: "")
            menuItem.representedObject = name
            boardPopup.menu?.addItem(menuItem)
        }
        if let current {
            if let idx = boardPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
                boardPopup.selectItem(at: idx)
            }
        }
    }

    func rebuildAppPopup() {
        guard appPopup != nil else { return }
        let current = appFilter
        appPopup.removeAllItems()
        let allItem = NSMenuItem(title: "All apps", action: nil, keyEquivalent: "")
        allItem.representedObject = nil as String?
        appPopup.menu?.addItem(allItem)
        let apps = Set(store.items.compactMap { $0.sourceApp }).sorted()
        for name in apps {
            let mi = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            mi.representedObject = name
            appPopup.menu?.addItem(mi)
        }
        if let current,
           let idx = appPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            appPopup.selectItem(at: idx)
        }
    }

    // The clips currently visible, in display order (pinned first in
    // the unfiltered view). Quick-paste numbers follow this order.
    func visibleItems() -> [ClipItem] {
        let q = (searchField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = typeFilters[max(0, typeControl?.selectedSegment ?? 0)]
        let board = boardFilter
        var result = store.items.filter { item in
            if type == "link" {
                if !isLinkItem(item) { return false }
            } else if type == "text" {
                if item.kind != "text" || isLinkItem(item) { return false }
            } else if type != "all" && item.kind != type { return false }
            if let board {
                if board == "__pinned" {
                    if !item.pinned { return false }
                } else if item.board != board { return false }
            }
            if let app = appFilter, item.sourceApp != app { return false }
            if let cutoff = recencyCutoff, item.createdAt < cutoff { return false }
            if !q.isEmpty {
                let haystacks = [item.text, item.ocrText, item.sourceApp, item.filePath]
                if !haystacks.contains(where: { ($0 ?? "").lowercased().contains(q) }) { return false }
            }
            return true
        }
        if board == nil {
            let pinned = result.filter { $0.pinned }
            let rest = result.filter { !$0.pinned }
            result = pinned + rest
        }
        return result
    }

    func refreshList() {
        guard listStack != nil else { return }
        rebuildBoardPopup()
        rebuildAppPopup()
        // Drop stack entries whose clips are gone.
        stackIDs = stackIDs.filter { id in store.items.contains { $0.id == id } }
        stackBar.isHidden = stackIDs.isEmpty
        if !stackIDs.isEmpty {
            stackLabel.stringValue = "Paste Stack: \(stackIDs.count) queued — ⌃⌥⌘V pastes the next one"
        }

        for view in listStack.arrangedSubviews { listStack.removeArrangedSubview(view); view.removeFromSuperview() }

        if let upd = availableUpdate, UserDefaults.standard.string(forKey: "dismissedUpdateVersion") != upd.version {
            let banner = updateBanner(version: upd.version)
            listStack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalToConstant: 300).isActive = true
            // No height pin to the stack: the banner has its own
            // 36pt height and top-aligns like the cards.
        }

        let items = visibleItems()
        emptyLabel.isHidden = !items.isEmpty
        if items.isEmpty {
            // Say WHY the list is empty. The old single message
            // ("copy something…") also appeared when filters were
            // hiding a full history, which read as lost data.
            emptyLabel.stringValue = store.items.isEmpty
                ? "Nothing here yet — copy something and it will show up."
                : "Nothing matches the current search or filters.\n\(store.items.count) clip\(store.items.count == 1 ? "" : "s") in history — clear the search or widen the filters to see them."
        }

        if boardFilter == nil {
            // Horizontal feed: no section headers — pinned clips
            // still come first and carry a 📌 on their card.
            let pinned = items.filter { $0.pinned }
            let rest = items.filter { !$0.pinned }
            var index = 0
            for item in pinned { addRow(item, index: index); index += 1 }
            for item in rest { addRow(item, index: index); index += 1 }
        } else {
            for (index, item) in items.enumerated() { addRow(item, index: index) }
        }
    }

    func addRow(_ item: ClipItem, index: Int) {
        let row = rowView(for: item, index: index)
        listStack.addArrangedSubview(row)
        // Fixed-width cards in the horizontal feed. Height is the
        // card's own natural height — the old heightAnchor pin to
        // the stack stretched cards to full panel height and left
        // them mostly blank inside (the other mood in the demo).
        row.widthAnchor.constraint(equalToConstant: 300).isActive = true
        // The current clip (⌘1) gets Paste's blue selection outline.
        if index == 0 {
            row.layer?.borderColor = NSColor.controlAccentColor.cgColor
            row.layer?.borderWidth = 2.5
        }
    }

    func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    func timeString(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    // MARK: Paste-style cards

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    func relativeTimeString(_ ts: Double) -> String {
        AppController.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }

    func isLinkItem(_ item: ClipItem) -> Bool {
        guard item.kind == "text", let raw = item.text else { return false }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), !t.contains("\n"),
              let url = URL(string: t), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return false }
        return true
    }

    func bandColor(for item: ClipItem) -> NSColor {
        if item.kind == "color", let hex = item.text, let c = colorFromHex(hex) { return c }
        if isLinkItem(item) { return NSColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1) }
        switch item.kind {
        case "file":
            return NSColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1)
        case "image":
            return NSColor(red: 0.686, green: 0.322, blue: 0.871, alpha: 1)
        default:
            // Text cards take their colour from the source app, like Paste's.
            let palette: [NSColor] = [
                NSColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1),
                NSColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1),
                NSColor(red: 1.0, green: 0.231, blue: 0.188, alpha: 1),
                NSColor(red: 0.196, green: 0.678, blue: 0.902, alpha: 1),
                NSColor(red: 0.345, green: 0.337, blue: 0.839, alpha: 1),
                NSColor(red: 1.0, green: 0.176, blue: 0.333, alpha: 1),
                NSColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1),
                NSColor(red: 0.686, green: 0.322, blue: 0.871, alpha: 1)
            ]
            let key = item.sourceBundleID ?? item.sourceApp ?? ""
            if key.isEmpty { return palette[0] }
            let sum = key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return palette[sum % palette.count]
        }
    }

    func onBandTextColor(for band: NSColor) -> NSColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (band.usingColorSpace(.sRGB) ?? band).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.72 ? NSColor(white: 0.16, alpha: 1) : .white
    }

    func typeLabel(for item: ClipItem) -> String {
        if isLinkItem(item) { return "Link" }
        switch item.kind {
        case "image": return "Image"
        case "file": return "File"
        case "color": return "Colour"
        default: return "Text"
        }
    }

    func sourceAppIcon(for item: ClipItem) -> NSImage? {
        guard let bundleID = item.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }

    func footerText(for item: ClipItem) -> String {
        if isLinkItem(item), let raw = item.text,
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let host = url.host {
            return host
        }
        switch item.kind {
        case "image":
            if let url = store.imageURL(for: item), let img = NSImage(contentsOf: url),
               let rep = img.representations.first {
                return "PNG · \(rep.pixelsWide) × \(rep.pixelsHigh)"
            }
            return "Image"
        case "file":
            if let path = item.filePath,
               let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? NSNumber {
                return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
            }
            return item.preview
        case "color":
            return (item.text ?? "").uppercased()
        default:
            let n = (item.text ?? "").count
            return n == 1 ? "1 character" : "\(n) characters"
        }
    }

    func cardFooterButton(_ title: String, action: Selector, id: String, tip: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.isBordered = false
        b.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    func rowView(for item: ClipItem, index: Int) -> NSView {
        let band = bandColor(for: item)
        let onBand = onBandTextColor(for: band)

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(red: 0.89, green: 0.89, blue: 0.91, alpha: 1).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.08
        card.layer?.shadowRadius = 6
        card.layer?.shadowOffset = NSSize(width: 0, height: -2)
        card.translatesAutoresizingMaskIntoConstraints = false

        // Header band: type + relative time on the left, source-app badge right.
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = band.cgColor
        header.layer?.cornerRadius = 14
        header.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)

        let typeText = NSTextField(labelWithString: typeLabel(for: item))
        typeText.font = NSFont.systemFont(ofSize: 12.5, weight: .bold)
        typeText.textColor = onBand
        typeText.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(typeText)

        let timeText = NSTextField(labelWithString: relativeTimeString(item.createdAt))
        timeText.font = NSFont.systemFont(ofSize: 10.5)
        timeText.textColor = onBand.withAlphaComponent(0.85)
        timeText.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(timeText)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 46),
            typeText.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            typeText.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
            timeText.leadingAnchor.constraint(equalTo: typeText.leadingAnchor),
            timeText.topAnchor.constraint(equalTo: typeText.bottomAnchor, constant: 1)
        ])

        var lastInHeader: NSLayoutXAxisAnchor = typeText.trailingAnchor
        if index < 9 {
            let badge = NSTextField(labelWithString: "⌘\(index + 1)")
            badge.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
            badge.textColor = onBand.withAlphaComponent(0.8)
            badge.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: lastInHeader, constant: 7),
                badge.centerYAnchor.constraint(equalTo: typeText.centerYAnchor)
            ])
            lastInHeader = badge.trailingAnchor
        }
        if item.pinned {
            let pinMark = NSTextField(labelWithString: "📌")
            pinMark.font = NSFont.systemFont(ofSize: 9)
            pinMark.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(pinMark)
            NSLayoutConstraint.activate([
                pinMark.leadingAnchor.constraint(equalTo: lastInHeader, constant: 6),
                pinMark.centerYAnchor.constraint(equalTo: typeText.centerYAnchor)
            ])
        }
        var appBadgeLeading: NSLayoutXAxisAnchor? = nil
        if let icon = sourceAppIcon(for: item) {
            let badgeBox = NSView()
            badgeBox.wantsLayer = true
            badgeBox.layer?.backgroundColor = NSColor.white.cgColor
            badgeBox.layer?.cornerRadius = 8
            badgeBox.layer?.shadowColor = NSColor.black.cgColor
            badgeBox.layer?.shadowOpacity = 0.15
            badgeBox.layer?.shadowRadius = 3
            badgeBox.layer?.shadowOffset = NSSize(width: 0, height: -1)
            badgeBox.translatesAutoresizingMaskIntoConstraints = false
            let iv = NSImageView(image: icon)
            iv.translatesAutoresizingMaskIntoConstraints = false
            badgeBox.addSubview(iv)
            header.addSubview(badgeBox)
            appBadgeLeading = badgeBox.leadingAnchor
            NSLayoutConstraint.activate([
                badgeBox.widthAnchor.constraint(equalToConstant: 32),
                badgeBox.heightAnchor.constraint(equalToConstant: 32),
                badgeBox.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
                badgeBox.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 24),
                iv.heightAnchor.constraint(equalToConstant: 24),
                iv.centerXAnchor.constraint(equalTo: badgeBox.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: badgeBox.centerYAnchor)
            ])
        }

        // Body: the clip itself, Paste-style.
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)

        func fullWidth(_ v: NSView) {
            v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        switch item.kind {
        case "image":
            let iv = NSImageView()
            if let url = store.imageURL(for: item), let img = NSImage(contentsOf: url) {
                iv.image = img
            }
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 8
            iv.layer?.masksToBounds = true
            iv.layer?.backgroundColor = NSColor(white: 0.95, alpha: 1).cgColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.heightAnchor.constraint(equalToConstant: 150).isActive = true
            body.addArrangedSubview(iv)
            fullWidth(iv)
            // OCR text no longer prints on the card — the wrapping
            // label grew to the full text and swamped it. The card
            // shows a "Contains text" chip + one-line teaser; the
            // full text lives in Preview. No text → dimensions.
            let ocrText = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !ocrText.isEmpty {
                let metaRow = NSStackView()
                metaRow.orientation = .horizontal
                metaRow.alignment = .centerY
                metaRow.spacing = 6
                let chip = NSView()
                chip.wantsLayer = true
                chip.layer?.backgroundColor = NSColor(white: 0.92, alpha: 1).cgColor
                chip.layer?.cornerRadius = 6
                chip.translatesAutoresizingMaskIntoConstraints = false
                let chipLabel = NSTextField(labelWithString: "Contains text")
                chipLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
                chipLabel.textColor = .secondaryLabelColor
                chipLabel.translatesAutoresizingMaskIntoConstraints = false
                chip.addSubview(chipLabel)
                NSLayoutConstraint.activate([
                    chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
                    chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
                    chipLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2),
                    chipLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2)
                ])
                metaRow.addArrangedSubview(chip)
                let teaser = NSTextField(labelWithString: String(ocrText.split(separator: "\n").first ?? ""))
                teaser.font = NSFont.systemFont(ofSize: 11)
                teaser.textColor = .secondaryLabelColor
                teaser.lineBreakMode = .byTruncatingTail
                teaser.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                metaRow.addArrangedSubview(teaser)
                body.addArrangedSubview(metaRow)
                fullWidth(metaRow)
            } else if let img = iv.image, let rep = img.representations.first {
                let dims = NSTextField(labelWithString: "\(rep.pixelsWide) × \(rep.pixelsHigh)")
                dims.font = NSFont.systemFont(ofSize: 11)
                dims.textColor = .secondaryLabelColor
                body.addArrangedSubview(dims)
            }
        case "file":
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            if let path = item.filePath {
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 34, height: 34)
                row.addArrangedSubview(NSImageView(image: icon))
            }
            let texts = NSStackView()
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 1
            let name = NSTextField(labelWithString: item.preview)
            name.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            texts.addArrangedSubview(name)
            if let path = item.filePath {
                let p = NSTextField(labelWithString: (path as NSString).deletingLastPathComponent)
                p.font = NSFont.systemFont(ofSize: 11)
                p.textColor = .secondaryLabelColor
                p.lineBreakMode = .byTruncatingMiddle
                texts.addArrangedSubview(p)
                p.widthAnchor.constraint(lessThanOrEqualTo: texts.widthAnchor).isActive = true
            }
            row.addArrangedSubview(texts)
            body.addArrangedSubview(row)
            fullWidth(row)
        case "color":
            if let hex = item.text, let color = colorFromHex(hex) {
                let swatch = NSView()
                swatch.wantsLayer = true
                swatch.layer?.backgroundColor = color.cgColor
                swatch.layer?.cornerRadius = 8
                swatch.layer?.borderWidth = 1
                swatch.layer?.borderColor = NSColor.separatorColor.cgColor
                swatch.translatesAutoresizingMaskIntoConstraints = false
                swatch.heightAnchor.constraint(equalToConstant: 54).isActive = true
                body.addArrangedSubview(swatch)
                fullWidth(swatch)
            }
        default:
            if isLinkItem(item) {
                enrichLinkIfNeeded(item)
                if let name = item.linkImageFile {
                    let iv = NSImageView()
                    iv.image = NSImage(contentsOf: store.imagesDir.appendingPathComponent(name))
                    iv.imageScaling = .scaleProportionallyUpOrDown
                    iv.wantsLayer = true
                    iv.layer?.cornerRadius = 8
                    iv.layer?.masksToBounds = true
                    iv.layer?.backgroundColor = NSColor(white: 0.95, alpha: 1).cgColor
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    iv.heightAnchor.constraint(equalToConstant: 120).isActive = true
                    body.addArrangedSubview(iv)
                    fullWidth(iv)
                }
                if let title = item.linkTitle, !title.isEmpty {
                    let t = NSTextField(wrappingLabelWithString: title)
                    t.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
                    t.textColor = .labelColor
                    t.maximumNumberOfLines = 2
                    t.lineBreakMode = .byTruncatingTail
                    body.addArrangedSubview(t)
                    fullWidth(t)
                }
                let u = NSTextField(labelWithString: item.preview)
                u.font = NSFont.systemFont(ofSize: 11.5)
                u.textColor = .secondaryLabelColor
                u.lineBreakMode = .byTruncatingMiddle
                body.addArrangedSubview(u)
                fullWidth(u)
            } else {
                let label = NSTextField(wrappingLabelWithString: item.preview)
                label.font = NSFont.systemFont(ofSize: 13)
                label.textColor = .labelColor
                label.maximumNumberOfLines = 5
                label.lineBreakMode = .byTruncatingTail
                body.addArrangedSubview(label)
                fullWidth(label)
            }
        }

        // Footer: actions left and right, Paste-style metadata centred.
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(footer)

        let pin = cardFooterButton(item.pinned ? "Unpin" : "Pin", action: #selector(pinClicked(_:)), id: item.id, tip: item.pinned ? "Unpin" : "Pin")
        footer.addSubview(pin)

        let boardButton = NSPopUpButton(frame: .zero, pullsDown: true)
        boardButton.isBordered = false
        boardButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        boardButton.contentTintColor = .secondaryLabelColor
        boardButton.toolTip = "Move to a pinboard"
        boardButton.identifier = NSUserInterfaceItemIdentifier(item.id)
        boardButton.translatesAutoresizingMaskIntoConstraints = false
        let headerItem = NSMenuItem(title: item.board.map { "🗂 \($0)" } ?? "🗂 Board", action: nil, keyEquivalent: "")
        boardButton.menu?.addItem(headerItem)
        let noneItem = NSMenuItem(title: "No board", action: #selector(boardChosen(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.identifier = NSUserInterfaceItemIdentifier(item.id)
        noneItem.representedObject = nil as String?
        boardButton.menu?.addItem(noneItem)
        for name in store.boards {
            let menuItem = NSMenuItem(title: name, action: #selector(boardChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.identifier = NSUserInterfaceItemIdentifier(item.id)
            menuItem.representedObject = name
            boardButton.menu?.addItem(menuItem)
        }
        let newItem = NSMenuItem(title: "New board…", action: #selector(newBoardChosen(_:)), keyEquivalent: "")
        newItem.target = self
        newItem.identifier = NSUserInterfaceItemIdentifier(item.id)
        boardButton.menu?.addItem(newItem)
        footer.addSubview(boardButton)

        let stack = cardFooterButton("+ Stack", action: #selector(stackClicked(_:)), id: item.id, tip: "Add to the Paste Stack")
        footer.addSubview(stack)
        let del = cardFooterButton("Delete", action: #selector(deleteClicked(_:)), id: item.id, tip: "Delete this clip")
        footer.addSubview(del)

        let meta = NSTextField(labelWithString: footerText(for: item))
        meta.font = NSFont.systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.alignment = .center
        meta.lineBreakMode = .byTruncatingTail
        meta.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(meta)

        // Invisible click target over header + body: click a card to paste it.
        let click = ClickView()
        click.identifier = NSUserInterfaceItemIdentifier(item.id)
        click.onClick = { [weak self] in self?.pasteBack(item) }
        click.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(click)

        // Preview / edit button in the header — added after the click
        // overlay so the overlay does not swallow its clicks.
        let previewBtn = NSButton()
        previewBtn.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview")
        previewBtn.bezelStyle = .inline
        previewBtn.isBordered = false
        previewBtn.contentTintColor = onBand
        previewBtn.toolTip = "Preview / Edit"
        previewBtn.target = self
        previewBtn.action = #selector(previewClicked(_:))
        previewBtn.identifier = NSUserInterfaceItemIdentifier(item.id)
        previewBtn.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(previewBtn)

        let menu = cardMenu(for: item)
        card.menu = menu
        click.menu = menu
        footer.menu = menu

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            footer.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),

            click.topAnchor.constraint(equalTo: card.topAnchor),
            click.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            click.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            click.bottomAnchor.constraint(equalTo: footer.topAnchor),

            previewBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            previewBtn.trailingAnchor.constraint(equalTo: appBadgeLeading ?? header.trailingAnchor, constant: appBadgeLeading == nil ? -12 : -6),
            previewBtn.widthAnchor.constraint(equalToConstant: 20),
            previewBtn.heightAnchor.constraint(equalToConstant: 20),

            pin.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            pin.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            boardButton.leadingAnchor.constraint(equalTo: pin.trailingAnchor, constant: 8),
            boardButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            del.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            del.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            meta.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            meta.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            meta.leadingAnchor.constraint(greaterThanOrEqualTo: boardButton.trailingAnchor, constant: 8),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -8)
        ])

        return card
    }

    // MARK: Actions

    func item(for sender: NSButton) -> ClipItem? {
        guard let id = sender.identifier?.rawValue else { return nil }
        return store.items.first { $0.id == id }
    }

    func item(for menuItem: NSMenuItem) -> ClipItem? {
        guard let id = menuItem.identifier?.rawValue else { return nil }
        return store.items.first { $0.id == id }
    }

    @objc func itemClicked(_ sender: NSButton) {
        guard let item = item(for: sender) else { return }
        pasteBack(item)
    }

    @objc func pinClicked(_ sender: NSButton) {
        guard let found = item(for: sender) else { return }
        togglePin(id: found.id)
    }

    @objc func boardChosen(_ sender: NSMenuItem) {
        guard let found = item(for: sender),
              let idx = store.items.firstIndex(where: { $0.id == found.id }) else { return }
        store.items[idx].board = sender.representedObject as? String
        store.save()
        refreshList()
    }

    @objc func newBoardChosen(_ sender: NSMenuItem) {
        guard let found = item(for: sender) else { return }
        let alert = NSAlert()
        alert.messageText = "New pinboard"
        alert.informativeText = "Name the board — the clip will be filed on it, and boarded clips never expire."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "e.g. Snippets"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        panel.makeKeyAndOrderFront(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !store.boards.contains(name) {
            store.boards = store.boards + [name]
        }
        if let idx = store.items.firstIndex(where: { $0.id == found.id }) {
            store.items[idx].board = name
            store.save()
        }
        refreshList()
    }

    @objc func stackClicked(_ sender: NSButton) {
        guard let found = item(for: sender) else { return }
        if !stackIDs.contains(found.id) {
            stackIDs.append(found.id)
        }
        refreshList()
    }

    @objc func pasteNextClicked() {
        pasteNextFromStack()
    }

    @objc func clearStackClicked() {
        stackIDs.removeAll()
        refreshList()
    }

    @objc func deleteClicked(_ sender: NSButton) {
        guard let found = item(for: sender) else { return }
        store.remove(found)
        store.save()
        refreshList()
    }

    @objc func clearHistory() {
        store.clearHistory()
        refreshList()
    }

    @objc func togglePause() {
        capturePaused.toggle()
        statusItem.button?.title = capturePaused ? "📋⏸" : "📋"
    }

    // The panel's "•••" menu (built fresh on every click, so the
    // Pause/Resume label and the limit checkmark are always right).
    @objc func showOverflowMenu(_ sender: NSButton) {
        guard let event = NSApp.currentEvent else { return }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if !version.isEmpty {
            let header = NSMenuItem(title: "ClipKeep v\(version)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }
        add(capturePaused ? "Resume Capture" : "Pause Capture", #selector(togglePause))
        add("Check for Updates…", #selector(checkForUpdateClicked))
        menu.addItem(.separator())
        let limitItem = NSMenuItem(title: "History Limit", action: nil, keyEquivalent: "")
        let limitMenu = NSMenu()
        for (title, value) in [("200 clips", 200), ("500 clips", 500), ("1000 clips", 1000), ("No limit", 0)] {
            let mi = NSMenuItem(title: title, action: #selector(limitChosen(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = value
            mi.state = store.historyLimit == value ? .on : .off
            limitMenu.addItem(mi)
        }
        limitItem.submenu = limitMenu
        menu.addItem(limitItem)
        add("Excluded Apps…", #selector(showExclusions))
        add("Clear History", #selector(clearHistory))
        menu.addItem(.separator())
        add("Quit ClipKeep", #selector(quitApp))
        NSMenu.popUpContextMenu(menu, with: event, for: sender)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: Excluded apps

    @objc func showExclusions() {
        if exclusionsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Excluded apps — copies from these are never recorded"
            window.isReleasedWhenClosed = false
            let content = NSView()
            window.contentView = content

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let clipView = NSView()
            clipView.addSubview(stack)
            scroll.documentView = clipView
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: clipView.bottomAnchor, constant: -8),
                clipView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            ])
            content.addSubview(scroll)

            let addButton = NSButton(title: "Add app…", target: self, action: #selector(addExcludedApp))
            addButton.bezelStyle = .rounded
            addButton.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(addButton)

            let note = NSTextField(labelWithString: "Password managers are already skipped automatically (concealed copies).")
            note.font = NSFont.systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(note)

            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
                scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),
                addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
                note.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 10),
                note.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
                note.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10)
            ])

            exclusionsWindow = window
            exclusionsStack = stack
        }
        refreshExclusionsList()
        exclusionsWindow?.center()
        exclusionsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func appName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    func refreshExclusionsList() {
        guard let stack = exclusionsStack else { return }
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        if store.excludedApps.isEmpty {
            let label = NSTextField(labelWithString: "No apps excluded yet.")
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
        }
        for bundleID in store.excludedApps {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let label = NSTextField(labelWithString: appName(forBundleID: bundleID))
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeExcludedApp(_:)))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.identifier = NSUserInterfaceItemIdentifier(bundleID)
            row.addArrangedSubview(label)
            row.addArrangedSubview(remove)
            stack.addArrangedSubview(row)
        }
    }

    @objc func addExcludedApp() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [UTType.applicationBundle]
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.canChooseFiles = true
        open.prompt = "Exclude"
        guard open.runModal() == .OK else { return }
        var excluded = store.excludedApps
        for url in open.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier, !excluded.contains(bundleID) {
                excluded.append(bundleID)
            }
        }
        store.excludedApps = excluded
        refreshExclusionsList()
    }

    @objc func removeExcludedApp(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        store.excludedApps = store.excludedApps.filter { $0 != bundleID }
        refreshExclusionsList()
    }

    // MARK: Panel toggle + hotkeys

    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    // Right-click menu for the menu-bar icon: quit the app, pause
    // or resume capture, or check for updates — without opening
    // the panel first.
    func showStatusMenu() {
        guard let button = statusItem.button, let event = NSApp.currentEvent else { return }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        add("Open ClipKeep", #selector(openPanel))
        add(capturePaused ? "Resume Capture" : "Pause Capture", #selector(togglePause))
        add("Check for Updates…", #selector(checkForUpdateClicked))
        menu.addItem(.separator())
        add("Quit ClipKeep", #selector(quitApp))
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc func openPanel() {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            togglePanel()
        }
    }

    @objc func checkForUpdateClicked() {
        checkForUpdate()
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            refreshList()
            if !panelFrameIsUsable(panel.frame) { restorePanelFrame() }
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeFirstResponder(searchField)
        }
    }

    // ⌘1–⌘9 quick-paste while the panel is open: pastes the nth
    // visible clip, matching the number badges on the rows.
    func installKeyMonitor() {
        let digitCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow,
                  event.modifierFlags.contains(.command),
                  let n = digitCodes[event.keyCode] else { return event }
            let items = self.visibleItems()
            guard items.count >= n else { return event }
            self.pasteBack(items[n - 1])
            return nil
        }
    }

    func registerHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            if let ev = event {
                _ = GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            }
            if hkID.id == 2 {
                AppController.shared.pasteNextFromStack()
            } else {
                AppController.shared.togglePanel()
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let panelHotKey = EventHotKeyID(signature: OSType(0x434B5054), id: 1) // 'CKPT'
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey),
                            panelHotKey, GetApplicationEventTarget(), 0, &hotKeyRef)

        let stackHotKey = EventHotKeyID(signature: OSType(0x434B5053), id: 2) // 'CKPS'
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey | controlKey),
                            stackHotKey, GetApplicationEventTarget(), 0, &stackHotKeyRef)
    }
}

// MARK: - Main

let delegate = AppController.shared
let app = NSApplication.shared
app.delegate = delegate
app.run()
