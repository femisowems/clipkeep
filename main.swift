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
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = decoded
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
    var stackBar: NSStackView!
    var stackLabel: NSTextField!
    var listStack: NSStackView!
    var scrollView: NSScrollView!
    var pauseButton: NSButton!
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

    let typeFilters = ["all", "text", "image", "file", "color"]

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "📋"
            button.action = #selector(togglePanel)
            button.target = self
        }

        buildPanel()
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
            store.insert(ClipItem(id: UUID().uuidString, kind: "text", text: text,
                                  imageFile: nil, createdAt: now, pinned: false, filePath: nil,
                                  sourceApp: sourceName, sourceBundleID: sourceBundle,
                                  ocrText: nil, board: nil, contentHash: nil))
            refreshList()
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

    func pasteBack(_ item: ClipItem) {
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
        panel.orderOut(nil)

        // If Accessibility is granted, press ⌘V in the app underneath
        // so the item lands where the cursor is. Otherwise it is on
        // the clipboard and a manual ⌘V does it.
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

    // MARK: Panel UI

    func buildPanel() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        panel.title = "ClipKeep"
        panel.appearance = NSAppearance(named: .aqua)   // Paste-style light look
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 440, height: 480)
        panel.contentMinSize = NSSize(width: 440, height: 440)
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

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1).cgColor
        panel.contentView = content

        searchField = NSSearchField()
        searchField.placeholderString = "Search history, apps, text inside images…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        typeControl = NSSegmentedControl(labels: ["All", "Text", "Images", "Files", "Colours"],
                                         trackingMode: .selectOne, target: self, action: #selector(filterChanged))
        typeControl.selectedSegment = 0
        typeControl.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(typeControl)

        boardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        boardPopup.target = self
        boardPopup.action = #selector(filterChanged)
        boardPopup.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(boardPopup)

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
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSView()
        clipView.addSubview(listStack)
        scrollView.documentView = clipView
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 12),
            listStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -12),
            listStack.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 12),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: clipView.bottomAnchor, constant: -12),
            clipView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        emptyLabel = NSTextField(labelWithString: "Nothing here yet — copy something and it will show up.")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        let clearButton = NSButton(title: "Clear history", target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(clearButton)

        pauseButton = NSButton(title: "Pause capture", target: self, action: #selector(togglePause))
        pauseButton.bezelStyle = .rounded
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pauseButton)

        let excludedButton = NSButton(title: "Excluded apps…", target: self, action: #selector(showExclusions))
        excludedButton.bezelStyle = .rounded
        excludedButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(excludedButton)

        let limitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (title, value) in [("Limit 200", 200), ("Limit 500", 500), ("Limit 1000", 1000), ("No limit", 0)] {
            let item = NSMenuItem(title: title, action: #selector(limitChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            limitPopup.menu?.addItem(item)
        }
        limitPopup.selectItem(at: [200, 500, 1000, 0].firstIndex(of: store.historyLimit) ?? 0)
        limitPopup.translatesAutoresizingMaskIntoConstraints = false
        limitPopup.identifier = NSUserInterfaceItemIdentifier("limitPopup")
        content.addSubview(limitPopup)

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitApp))
        quitButton.bezelStyle = .rounded
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(quitButton)

        let hint = NSTextField(labelWithString: "Click an item to paste it · ⌘1–9 quick-pastes · ⌘⇧V toggles this panel")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            typeControl.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            typeControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            boardPopup.centerYAnchor.constraint(equalTo: typeControl.centerYAnchor),
            boardPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            boardPopup.leadingAnchor.constraint(greaterThanOrEqualTo: typeControl.trailingAnchor, constant: 8),

            stackBar.topAnchor.constraint(equalTo: typeControl.bottomAnchor, constant: 8),
            stackBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            stackBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: stackBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            // Floors so the content's fitting size can never collapse
            // the window: in 2.0.x the old rows' fitting width was
            // ~60pt and AppKit's constraint-based window sizing shrank
            // the panel to a strip on the first layout pass.
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            hint.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -6),

            clearButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            clearButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            pauseButton.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 8),
            pauseButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            excludedButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 8),
            excludedButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            limitPopup.leadingAnchor.constraint(equalTo: excludedButton.trailingAnchor, constant: 8),
            limitPopup.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            quitButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            quitButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])

        refreshList()
        restorePanelFrame()
    }

    // MARK: Panel frame persistence (manual, validated)

    private let panelFrameKey = "ClipKeepPanelFrameV3"

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
        panel.setFrame(NSRect(x: 0, y: 0, width: 520, height: 680), display: false)
        panel.center()
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

    // The clips currently visible, in display order (pinned first in
    // the unfiltered view). Quick-paste numbers follow this order.
    func visibleItems() -> [ClipItem] {
        let q = (searchField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = typeFilters[max(0, typeControl?.selectedSegment ?? 0)]
        let board = boardFilter
        var result = store.items.filter { item in
            if type != "all" && item.kind != type { return false }
            if let board {
                if board == "__pinned" {
                    if !item.pinned { return false }
                } else if item.board != board { return false }
            }
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
        // Drop stack entries whose clips are gone.
        stackIDs = stackIDs.filter { id in store.items.contains { $0.id == id } }
        stackBar.isHidden = stackIDs.isEmpty
        if !stackIDs.isEmpty {
            stackLabel.stringValue = "Paste Stack: \(stackIDs.count) queued — ⌃⌥⌘V pastes the next one"
        }

        for view in listStack.arrangedSubviews { listStack.removeArrangedSubview(view); view.removeFromSuperview() }

        let items = visibleItems()
        emptyLabel.isHidden = !items.isEmpty

        if boardFilter == nil {
            let pinned = items.filter { $0.pinned }
            let rest = items.filter { !$0.pinned }
            var index = 0
            if !pinned.isEmpty {
                listStack.addArrangedSubview(sectionLabel("Pinned"))
                for item in pinned { addRow(item, index: index); index += 1 }
            }
            if !rest.isEmpty {
                if !pinned.isEmpty { listStack.addArrangedSubview(sectionLabel("History")) }
                for item in rest { addRow(item, index: index); index += 1 }
            }
        } else {
            for (index, item) in items.enumerated() { addRow(item, index: index) }
        }
    }

    func addRow(_ item: ClipItem, index: Int) {
        let row = rowView(for: item, index: index)
        listStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
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
            iv.heightAnchor.constraint(equalToConstant: 130).isActive = true
            body.addArrangedSubview(iv)
            fullWidth(iv)
            if let ocr = item.ocrText, !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let ocrLabel = NSTextField(wrappingLabelWithString: ocr)
                ocrLabel.font = NSFont.systemFont(ofSize: 11)
                ocrLabel.textColor = .secondaryLabelColor
                ocrLabel.maximumNumberOfLines = 2
                ocrLabel.lineBreakMode = .byTruncatingTail
                body.addArrangedSubview(ocrLabel)
                fullWidth(ocrLabel)
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
            let label = NSTextField(wrappingLabelWithString: item.preview)
            label.font = NSFont.systemFont(ofSize: 13)
            label.textColor = .labelColor
            label.maximumNumberOfLines = 5
            label.lineBreakMode = .byTruncatingTail
            body.addArrangedSubview(label)
            fullWidth(label)
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
        let click = NSButton()
        click.isBordered = false
        click.title = ""
        click.target = self
        click.action = #selector(itemClicked(_:))
        click.identifier = NSUserInterfaceItemIdentifier(item.id)
        click.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(click)

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
        guard let found = item(for: sender),
              let idx = store.items.firstIndex(where: { $0.id == found.id }) else { return }
        store.items[idx].pinned.toggle()
        store.items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.createdAt > b.createdAt
        }
        store.save()
        refreshList()
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
        pauseButton.title = capturePaused ? "Resume capture" : "Pause capture"
        statusItem.button?.title = capturePaused ? "📋⏸" : "📋"
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
