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
import ImageIO
import CoreImage
import AuthenticationServices
import Security

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
    // Added in v2.17 (sync-ready) — optional so older files decode.
    var updatedAt: Double? = nil      // last change; nil = createdAt
    var originDevice: String? = nil   // device that created the clip
    var originPlatform: String? = nil // "mac" for clips born here
    // Added for the sync engine — optional for the same reason.
    // A pulled image clip's bytes arrive lazily: until they do,
    // these carry the cloud identity of the image (its SHA-256
    // and object key) so the card can ask for them on display.
    var remoteImageSHA256: String? = nil
    var remoteImageKey: String? = nil
    // A pulled file clip's name: the bytes stay on the device
    // that copied the file (v1 syncs file metadata only), so
    // there is no local path — but the card can still name it.
    var remoteFileName: String? = nil

    var effectiveUpdatedAt: Double { updatedAt ?? createdAt }

    // A tombstone copy: the same clip, stamped with its deletion
    // time. Synced devices use tombstones to learn a clip is gone
    // instead of resurrecting it from their own copy.
    func tombstoned(at time: Double) -> ClipItem {
        var copy = self
        copy.updatedAt = time
        return copy
    }

    var preview: String {
        switch kind {
        case "image": return "Image"
        case "file": return filePath.map { ($0 as NSString).lastPathComponent } ?? remoteFileName ?? "File"
        case "color": return text ?? "Colour"
        default:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "(empty)" : t
        }
    }

    var isKeeper: Bool { pinned || board != nil }
}

// On-disk history format, v2 (v2.17.0): an envelope carrying a
// schema version, the live clips and the tombstones. v1 files
// were a bare [ClipItem] array — decodeHistory still reads them.
struct HistoryFile: Codable {
    var schemaVersion: Int
    var clips: [ClipItem]
    var tombstones: [ClipItem]
}

// MARK: - Store

final class ClipStore {
    let baseDir: URL
    let imagesDir: URL
    let fileURL: URL
    var items: [ClipItem] = []   // newest first
    // Deleted clips, kept 30 days so sync can propagate the
    // deletion to every device before the record is dropped.
    var tombstones: [ClipItem] = []

    static let currentSchemaVersion = 2
    static let tombstoneRetention: Double = 30 * 24 * 60 * 60

    private let defaults = UserDefaults.standard

    var historyLimit: Int {   // unpinned/unboarded cap; 0 = unlimited
        get { defaults.object(forKey: "historyLimit") as? Int ?? 200 }
        set { defaults.set(newValue, forKey: "historyLimit"); trim(); save() }
    }

    // Keep-for period in days (v2.19.0): unpinned/unboarded
    // clips older than this roll off, whichever limit — count
    // or age — reaches them first. 0 = keep forever, the
    // default, so nothing changes until a user opts in.
    var retentionDays: Int {
        get { defaults.object(forKey: "retentionDays") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "retentionDays"); trim(); save() }
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
        // Age sweep (v2.19.0): time passes while the app is
        // closed, so clips can cross the retention window with
        // no capture to trigger a trim — prune once at launch.
        let loadedCount = items.count
        trim()
        if items.count != loadedCount { save() }
    }

    // Stable per-install device identity, stamped onto new clips
    // so sync can tell which device a clip came from.
    var deviceID: String {
        if let id = defaults.string(forKey: "ClipKeepDeviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "ClipKeepDeviceID")
        return id
    }

    // Decode either on-disk format: the v2 envelope, or a v1
    // bare [ClipItem] array (strict decode first, then the lossy
    // per-entry fallback so one malformed clip can't silently
    // blank the whole history — the strict decode fails
    // atomically, every clip or none).
    static func decodeHistory(from data: Data) -> (clips: [ClipItem], tombstones: [ClipItem]) {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(HistoryFile.self, from: data) {
            return (file.clips, file.tombstones)
        }
        if let decoded = try? decoder.decode([ClipItem].self, from: data) {
            return (decoded, [])
        }
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let clips = raw.compactMap { entry -> ClipItem? in
                guard let entryData = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
                return try? decoder.decode(ClipItem.self, from: entryData)
            }
            return (clips, [])
        }
        return ([], [])
    }

    // Tombstones older than the retention window are dropped for
    // good — by then every synced device has had its chance to
    // learn of the deletion.
    static func purgedTombstones(_ list: [ClipItem], now: Double) -> [ClipItem] {
        list.filter { now - $0.effectiveUpdatedAt < tombstoneRetention }
    }

    // The keep-for test (v2.19.0): a clip is past its retention
    // period once its creation date sits more than retentionDays
    // behind now. Keepers — pinned or boarded — never expire,
    // and a period of 0 keeps everything forever.
    static func isPastRetention(_ item: ClipItem, retentionDays: Int, now: Double) -> Bool {
        guard retentionDays > 0, !item.isKeeper else { return false }
        return now - item.createdAt > Double(retentionDays) * 24 * 60 * 60
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoded = Self.decodeHistory(from: data)
        items = decoded.clips
        tombstones = Self.purgedTombstones(decoded.tombstones, now: Date().timeIntervalSince1970)
    }

    // Saving used to encode the ENTIRE history and write it on
    // the caller's (main) thread on every change — every copy,
    // pin and delete paid it (lag fix, v2.12.0). Now save()
    // snapshots the items (a cheap value-type copy), and the
    // encode + write happen on a serial queue a beat later,
    // coalescing bursts into one write. saveNow() is the
    // synchronous flush, called on termination so a quit inside
    // the debounce window loses nothing.
    private let saveQueue = DispatchQueue(label: "io.starterdev.clipkeep.save")
    private var pendingSnapshot: HistoryFile?
    private var flushScheduled = false

    func save() {
        let snapshot = HistoryFile(schemaVersion: Self.currentSchemaVersion, clips: items, tombstones: tombstones)
        saveQueue.async { [weak self] in
            guard let self else { return }
            self.pendingSnapshot = snapshot
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.saveQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, let snap = self.pendingSnapshot else { return }
                self.flushScheduled = false
                self.pendingSnapshot = nil
                if let data = try? JSONEncoder().encode(snap) {
                    try? data.write(to: self.fileURL, options: .atomic)
                }
            }
        }
    }

    func saveNow() {
        let file = HistoryFile(schemaVersion: Self.currentSchemaVersion, clips: items, tombstones: tombstones)
        if let data = try? JSONEncoder().encode(file) {
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
        var item = item
        // Sync-ready stamps: when the clip last changed, and the
        // device it was born on. Captures enter here, so this is
        // the one choke point every new clip passes through.
        if item.updatedAt == nil { item.updatedAt = item.createdAt }
        if item.originDevice == nil { item.originDevice = deviceID }
        if item.originPlatform == nil { item.originPlatform = "mac" }
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

    // Record a deletion for sync before the clip leaves the live
    // list. The tombstone carries the deletion time; the local
    // image file still goes away now (each device keeps its own).
    func recordTombstone(_ item: ClipItem, at time: Double = Date().timeIntervalSince1970) {
        tombstones.removeAll { $0.id == item.id }
        tombstones.insert(item.tombstoned(at: time), at: 0)
    }

    // Stamp a live clip as changed (pin, board, edit) so sync's
    // last-writer-wins ordering sees the update.
    func touch(id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].updatedAt = Date().timeIntervalSince1970
        }
    }

    func remove(_ item: ClipItem) {
        recordTombstone(item)
        deleteImageFile(of: item)
        items.removeAll { $0.id == item.id }
    }

    // A deletion learned from sync: the tombstone keeps the
    // origin device's deletion time rather than stamping now,
    // so last-writer-wins compares the same instant on every
    // device. The clip leaves the live list and its local
    // image file goes away, exactly as for a local delete.
    // The caller passes the incoming clip itself — its
    // updatedAt already IS the deletion time.
    func applyRemoteDeletion(_ tombstone: ClipItem) {
        tombstones.removeAll { $0.id == tombstone.id }
        tombstones.insert(tombstone, at: 0)
        if let local = items.first(where: { $0.id == tombstone.id }) {
            deleteImageFile(of: local)
        }
        items.removeAll { $0.id == tombstone.id }
    }

    func clearHistory() {
        for old in items where !old.isKeeper {
            recordTombstone(old)
            deleteImageFile(of: old)
        }
        items.removeAll { !$0.isKeeper }
        save()
    }

    // One-off purge (v2.19.0): remove every clip past the
    // current keep-for period, right now, through the same
    // tombstone + image-delete path as the automatic trim.
    // Returns how many clips went; 0 when the period is
    // Forever (nothing can be past it).
    @discardableResult
    func purgePastRetention() -> Int {
        guard retentionDays > 0 else { return 0 }
        let now = Date().timeIntervalSince1970
        var removed = 0
        var kept: [ClipItem] = []
        for item in items {
            if Self.isPastRetention(item, retentionDays: retentionDays, now: now) {
                recordTombstone(item)
                deleteImageFile(of: item)
                removed += 1
            } else {
                kept.append(item)
            }
        }
        if removed > 0 { items = kept; save() }
        return removed
    }

    // On-disk footprint of the history store (v2.19.0): the
    // history file plus every file in the images folder.
    var diskUsageBytes: Int64 {
        var total: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber {
            total += size.int64Value
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    // Prune the live list: keepers always stay; every other
    // clip rolls off when EITHER the count cap or the keep-for
    // period (v2.19.0) reaches it. Removals go through the
    // same tombstone + image-delete path as any other trim,
    // so sync learns of them exactly like a manual delete.
    func trim() {
        let limit = historyLimit
        let days = retentionDays
        guard limit > 0 || days > 0 else { return }
        let now = Date().timeIntervalSince1970
        var seen = 0
        var kept: [ClipItem] = []
        for item in items {
            if item.isKeeper {
                kept.append(item)
            } else if Self.isPastRetention(item, retentionDays: days, now: now) {
                recordTombstone(item)
                deleteImageFile(of: item)
            } else if limit == 0 || seen < limit {
                seen += 1
                kept.append(item)
            } else {
                recordTombstone(item)
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

// Click target laid over a card: left-clicks report their
// click count (single click selects the card, double-click
// pastes it — v2.13.0, restored in v2.16.3 after v2.14.0's
// double-click-copies interlude), right-click presents the
// card's context menu. An NSButton overlay was used before, but
// buttons swallow right-clicks without ever presenting
// their menu — the card menu existed all along and simply
// never opened.
final class ClickView: NSView {
    var onClick: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func rightMouseDown(with event: NSEvent) {
        if let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

// A view that never takes clicks — overlays (the scroll fade)
// sit above content without swallowing its events.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: Panel themes (v2.5.0)
//
// Four switchable panel themes, mocked Nov 17 and picked by
// Femi (A Warm Tint, B Midnight, E Ember, F Lagoon — Matcha,
// Bloom, and the greys didn't make the cut). A theme drives the
// panel tint, the accent, the card surface, and every button
// wash; the choice persists in UserDefaults "ClipKeepTheme".
struct PanelTheme {
    let id: String
    let name: String
    let dark: Bool
    let tint: NSColor
    let accent: NSColor
    let onAccent: NSColor
    let cardBG: NSColor
    let cardBorder: NSColor
    let iconTint: NSColor
    let trackBG: NSColor
    let fieldBG: NSColor
    let fieldHoverBG: NSColor
    let fieldBorder: NSColor
    let hoverWash: NSColor
    let pressedWash: NSColor
    let badgeBG: NSColor
}

let panelThemes: [PanelTheme] = [
    PanelTheme(id: "warm", name: "Warm Tint", dark: false,
               tint: NSColor(red: 0.98, green: 0.945, blue: 0.87, alpha: 0.45),
               accent: NSColor(red: 0, green: 0.478, blue: 1, alpha: 1),
               onAccent: .white,
               cardBG: .white,
               cardBorder: NSColor(red: 0.89, green: 0.89, blue: 0.91, alpha: 1),
               iconTint: NSColor.black.withAlphaComponent(0.78),
               trackBG: NSColor(white: 0, alpha: 0.06),
               fieldBG: NSColor(white: 1, alpha: 0.55),
               fieldHoverBG: NSColor(white: 1, alpha: 0.82),
               fieldBorder: NSColor(white: 0, alpha: 0.10),
               hoverWash: NSColor(white: 0, alpha: 0.06),
               pressedWash: NSColor(white: 0, alpha: 0.12),
               badgeBG: NSColor(white: 0, alpha: 0.10)),
    PanelTheme(id: "midnight", name: "Midnight", dark: true,
               tint: NSColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 0.60),
               accent: NSColor(red: 0.49, green: 0.48, blue: 1, alpha: 1),
               onAccent: .white,
               cardBG: NSColor(red: 0.137, green: 0.173, blue: 0.239, alpha: 1),
               cardBorder: NSColor(white: 1, alpha: 0.10),
               iconTint: NSColor.white.withAlphaComponent(0.85),
               trackBG: NSColor(white: 1, alpha: 0.10),
               fieldBG: NSColor(white: 1, alpha: 0.09),
               fieldHoverBG: NSColor(white: 1, alpha: 0.16),
               fieldBorder: NSColor(white: 1, alpha: 0.13),
               hoverWash: NSColor(white: 1, alpha: 0.10),
               pressedWash: NSColor(white: 1, alpha: 0.16),
               badgeBG: NSColor(white: 1, alpha: 0.14)),
    PanelTheme(id: "ember", name: "Ember", dark: true,
               tint: NSColor(red: 0.13, green: 0.08, blue: 0.05, alpha: 0.60),
               accent: NSColor(red: 1, green: 0.624, blue: 0.263, alpha: 1),
               onAccent: NSColor(red: 0.14, green: 0.07, blue: 0.02, alpha: 1),
               cardBG: NSColor(red: 0.227, green: 0.165, blue: 0.125, alpha: 1),
               cardBorder: NSColor(white: 1, alpha: 0.10),
               iconTint: NSColor.white.withAlphaComponent(0.85),
               trackBG: NSColor(white: 1, alpha: 0.10),
               fieldBG: NSColor(white: 1, alpha: 0.08),
               fieldHoverBG: NSColor(white: 1, alpha: 0.15),
               fieldBorder: NSColor(white: 1, alpha: 0.13),
               hoverWash: NSColor(white: 1, alpha: 0.10),
               pressedWash: NSColor(white: 1, alpha: 0.16),
               badgeBG: NSColor(white: 1, alpha: 0.14)),
    PanelTheme(id: "lagoon", name: "Lagoon", dark: true,
               tint: NSColor(red: 0.02, green: 0.13, blue: 0.13, alpha: 0.60),
               accent: NSColor(red: 0.176, green: 0.831, blue: 0.749, alpha: 1),
               onAccent: NSColor(red: 0.02, green: 0.19, blue: 0.16, alpha: 1),
               cardBG: NSColor(red: 0.067, green: 0.251, blue: 0.247, alpha: 1),
               cardBorder: NSColor(white: 1, alpha: 0.10),
               iconTint: NSColor.white.withAlphaComponent(0.85),
               trackBG: NSColor(white: 1, alpha: 0.10),
               fieldBG: NSColor(white: 1, alpha: 0.08),
               fieldHoverBG: NSColor(white: 1, alpha: 0.15),
               fieldBorder: NSColor(white: 1, alpha: 0.13),
               hoverWash: NSColor(white: 1, alpha: 0.10),
               pressedWash: NSColor(white: 1, alpha: 0.16),
               badgeBG: NSColor(white: 1, alpha: 0.14))
]

// MARK: Button overhaul (v2.4.0)
//
// One button system across the panel, replacing the stock
// controls Femi circled in his Nov 17 Loom ("Improve the buttons
// entirely!!"): pill tabs with icons + counts and a sliding
// selection, every dropdown in the same toolbar chrome, icon
// actions on cards, and real hover / pressed / focus states.

// A borderless NSButton whose layer paints its own background
// for the resting / hover / pressed states. Subclasses and
// callers set the palette; tracking areas drive the hover.
class HoverButton: NSButton {
    var normalBG: NSColor = .clear { didSet { refreshChrome() } }
    var hoverBG: NSColor = NSColor(white: 0, alpha: 0.06) { didSet { refreshChrome() } }
    var pressedBG: NSColor = NSColor(white: 0, alpha: 0.12) { didSet { refreshChrome() } }
    var baseTint: NSColor? { didSet { refreshChrome() } }
    var hoverTint: NSColor?
    var chromeCornerRadius: CGFloat = 7 { didSet { refreshChrome() } }
    var chromeBorderColor: NSColor? { didSet { refreshChrome() } }
    // The border width rides in the chrome state (v2.18.1):
    // the avatar's 2pt open-state ring used to be forced on
    // the layer after refreshChrome ran, and every hover or
    // press refresh quietly reset it to 1 — the ring visibly
    // thinned under the pointer. Default 1 = the behaviour
    // every other HoverButton already has.
    var chromeBorderWidth: CGFloat = 1 { didSet { refreshChrome() } }
    // Read-only chrome state + a refresh hook (v2.19.2): the
    // avatar paints its face on its own disc subview, in step
    // with the button's hover/press refreshes.
    var isHoveringNow: Bool { hovering }
    var isPressingNow: Bool { pressing }
    var onChromeRefresh: (() -> Void)?
    private var hovering = false
    private var pressing = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        bezelStyle = .inline
        refreshChrome()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refreshChrome() }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshChrome() }
    override func mouseDown(with event: NSEvent) {
        pressing = true; refreshChrome()
        super.mouseDown(with: event)
        pressing = false; refreshChrome()
    }
    func refreshChrome() {
        layer?.backgroundColor = (pressing ? pressedBG : hovering ? hoverBG : normalBG).cgColor
        layer?.cornerRadius = chromeCornerRadius
        if let chromeBorderColor {
            layer?.borderWidth = chromeBorderWidth
            layer?.borderColor = chromeBorderColor.cgColor
        } else {
            layer?.borderWidth = 0
        }
        if hovering, let hoverTint {
            contentTintColor = hoverTint
        } else if let baseTint {
            contentTintColor = baseTint
        }
        onChromeRefresh?()
    }
}

// Hit-test-transparent face subviews (v2.19.2): the avatar's
// disc, glyph and initial ride on top of the button but must
// never intercept a click — every press belongs to the button.
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Stack view that never intercepts clicks — used inside pill
// tab buttons so every click lands on the button itself.
final class PassthroughStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// One tab in the pill row: SF Symbol icon + title + count
// badge. The selection fill lives on the track's sliding
// indicator; the pill only recolours its content and paints
// its own hover wash.
final class PillTabButton: HoverButton {
    let typeValue: String
    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let badgeView = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private(set) var isCurrent = false

    init(type: String, title: String, symbol: String) {
        typeValue = type
        super.init(frame: .zero)
        // NSButton's built-in title defaults to "Button" and the
        // cell draws it behind the custom icon/label subviews —
        // the ghosted double-print on every pill (Nov 17). The
        // pill's own label subview is the only text it should show.
        self.title = ""
        translatesAutoresizingMaskIntoConstraints = false
        chromeCornerRadius = 13
        hoverBG = NSColor(white: 0, alpha: 0.07)

        let stack = PassthroughStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            iconView.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        stack.addArrangedSubview(titleLabel)

        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 7
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(badgeLabel)
        stack.addArrangedSubview(badgeView)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -5),
            badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -1)
        ])
        setCurrent(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCount(_ n: Int) { badgeLabel.stringValue = "\(n)" }

    // Theme-driven colours (Warm Tint values until a theme is
    // applied): the selected pill's content colour, the resting
    // badge wash, and the hover wash for unselected pills.
    private var selectedFG: NSColor = .white
    private var badgeBGUnselected: NSColor = NSColor(white: 0, alpha: 0.10)
    private var hoverWashUnselected: NSColor = NSColor(white: 0, alpha: 0.07)

    func applyTheme(_ theme: PanelTheme) {
        selectedFG = theme.onAccent
        badgeBGUnselected = theme.badgeBG
        hoverWashUnselected = theme.hoverWash
        setCurrent(isCurrent)
    }

    func setCurrent(_ on: Bool) {
        isCurrent = on
        let fg: NSColor = on ? selectedFG : .labelColor
        titleLabel.textColor = fg
        iconView.contentTintColor = fg
        badgeLabel.textColor = on ? selectedFG : .secondaryLabelColor
        badgeView.layer?.backgroundColor = (on ? selectedFG.withAlphaComponent(0.30)
                                              : badgeBGUnselected).cgColor
        hoverBG = on ? .clear : hoverWashUnselected
    }
}

// The pill tab row: a rounded track holding the pills, with an
// accent indicator that slides under the selected pill.
final class PillTabsView: NSView {
    var onChange: (() -> Void)?
    private(set) var selectedType = "all"
    private let indicator = NSView()
    private let stack = NSStackView()
    private var pills: [PillTabButton] = []
    private var indicatorRetryScheduled = false

    init(types: [(type: String, title: String, symbol: String)]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.06).cgColor
        layer?.cornerRadius = 16

        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.systemBlue.cgColor
        indicator.layer?.cornerRadius = 13
        indicator.layer?.shadowColor = NSColor.systemBlue.cgColor
        indicator.layer?.shadowOpacity = 0.35
        indicator.layer?.shadowRadius = 4
        indicator.layer?.shadowOffset = NSSize(width: 0, height: -1)
        addSubview(indicator)

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(equalToConstant: 32)
        ])
        for entry in types {
            let pill = PillTabButton(type: entry.type, title: entry.title, symbol: entry.symbol)
            pill.target = self
            pill.action = #selector(pillClicked(_:))
            pills.append(pill)
            stack.addArrangedSubview(pill)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pillClicked(_ sender: PillTabButton) {
        guard sender.typeValue != selectedType else { return }
        select(type: sender.typeValue, animate: true)
        onChange?()
    }

    func select(type: String, animate: Bool) {
        guard pills.contains(where: { $0.typeValue == type }) else { return }
        selectedType = type
        for pill in pills { pill.setCurrent(pill.typeValue == type) }
        positionIndicator(animated: animate)
    }

    func setCounts(_ counts: [String: Int]) {
        for pill in pills { pill.setCount(counts[pill.typeValue] ?? 0) }
    }

    func applyTheme(_ theme: PanelTheme) {
        layer?.backgroundColor = theme.trackBG.cgColor
        indicator.layer?.backgroundColor = theme.accent.cgColor
        indicator.layer?.shadowColor = theme.accent.cgColor
        for pill in pills { pill.applyTheme(theme) }
    }

    override func layout() {
        super.layout()
        // The pills are arranged by the stack, whose frames only
        // settle once the stack's own layout has run — on the
        // first pass this view's layout() runs before that, so
        // the indicator read zero frames and never appeared at
        // launch: the remembered tab showed its selected-state
        // text (dark on-accent on the dark themes) on the bare
        // track, with no accent fill behind it (Femi's Nov 18
        // screenshot — the Files tab near-black on load). The
        // panel's frame is fixed, so no later layout pass ever
        // repaired it; only clicking a tab did. Force the
        // stack's subtree to lay out before measuring.
        stack.layoutSubtreeIfNeeded()
        positionIndicator(animated: false)
    }

    private func positionIndicator(animated: Bool) {
        guard let pill = pills.first(where: { $0.typeValue == selectedType }) else { return }
        let frame = pill.convert(pill.bounds, to: self)
        guard frame.width > 0 else {
            // Called before the first layout (buildPanel selects
            // the remembered tab while the row still has no
            // frames): retry once on the next runloop, when the
            // stack has arranged the pills.
            if !indicatorRetryScheduled {
                indicatorRetryScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.indicatorRetryScheduled = false
                    self.stack.layoutSubtreeIfNeeded()
                    self.positionIndicator(animated: false)
                }
            }
            return
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                indicator.animator().frame = frame
            }
        } else {
            indicator.frame = frame
        }
    }
}

// The toolbar chrome shared by every filter dropdown: a
// rounded, bordered ghost button the borderless popup sits
// inside, so boards / apps / recency / sort all read as one
// system of identical buttons.
final class ToolbarShell: NSView {
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private var fieldBG: NSColor = NSColor(white: 1, alpha: 0.55)
    private var fieldHoverBG: NSColor = NSColor(white: 1, alpha: 0.82)

    init(popup: NSPopUpButton) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0, alpha: 0.10).cgColor
        applyHover()
        popup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popup)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            popup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyHover() }
    func applyTheme(_ theme: PanelTheme) {
        fieldBG = theme.fieldBG
        fieldHoverBG = theme.fieldHoverBG
        layer?.borderColor = theme.fieldBorder.cgColor
        applyHover()
    }
    private func applyHover() {
        layer?.backgroundColor = (hovering ? fieldHoverBG : fieldBG).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = hovering ? 0.12 : 0
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)
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

// A colour written out as text: the WHOLE string must be the
// literal, so a sentence mentioning a colour stays text. Accepts
// #RGB, #RRGGBB, #RRGGBBFF, rgb(r, g, b), rgba(r, g, b, 1),
// hsl(h, s%, l%) and hsla(h, s%, l%, 1) — a translucent colour
// stays text, because colour clips store an opaque hex and
// would misrepresent it.
func colorFromLiteral(_ raw: String) -> NSColor? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") {
        let digits = String(s.dropFirst())
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        if digits.count == 3 {
            return colorFromHex("#" + digits.map { "\($0)\($0)" }.joined())
        }
        if digits.count == 8 {
            // #RRGGBBAA — only fully opaque (AA = FF) counts.
            guard digits.suffix(2).uppercased() == "FF" else { return nil }
            return colorFromHex("#" + String(digits.prefix(6)))
        }
        return digits.count == 6 ? colorFromHex(s) : nil
    }
    let lower = s.lowercased()
    let isHSLA = lower.hasPrefix("hsla(")
    if isHSLA || lower.hasPrefix("hsl(") {
        guard s.hasSuffix(")") else { return nil }
        let inner = s.dropFirst(isHSLA ? 5 : 4).dropLast()
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4,
              let hDeg = Double(parts[0]) else { return nil }
        func percent(_ p: String) -> Double? {
            guard p.hasSuffix("%"), let v = Double(p.dropLast()), (0...100).contains(v) else { return nil }
            return v / 100
        }
        guard let sat = percent(parts[1]), let light = percent(parts[2]) else { return nil }
        if parts.count == 4 {
            let a = parts[3]
            if a.hasSuffix("%") { guard Double(a.dropLast()) == 100 else { return nil } }
            else { guard Double(a) == 1 else { return nil } }
        }
        // HSL → RGB (textbook sector formula, all in Double).
        let sector = ((hDeg.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)) / 60
        let c = (1 - abs(2 * light - 1)) * sat
        let x = c * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = light - c / 2
        var r = 0.0, g = 0.0, b = 0.0
        switch sector {
        case 0..<1: r = c; g = x
        case 1..<2: r = x; g = c
        case 2..<3: g = c; b = x
        case 3..<4: g = x; b = c
        case 4..<5: r = x; b = c
        default: r = c; b = x
        }
        return NSColor(srgbRed: CGFloat(r + m), green: CGFloat(g + m), blue: CGFloat(b + m), alpha: 1)
    }
    let isRGBA = lower.hasPrefix("rgba(")
    guard isRGBA || lower.hasPrefix("rgb("), s.hasSuffix(")") else { return nil }
    let inner = s.dropFirst(isRGBA ? 5 : 4).dropLast()
    let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 3 || parts.count == 4 else { return nil }
    var rgb: [CGFloat] = []
    for p in parts.prefix(3) {
        guard let v = Int(p), (0...255).contains(v) else { return nil }
        rgb.append(CGFloat(v) / 255)
    }
    if parts.count == 4 {
        guard let a = Double(parts[3]), a == 1 else { return nil }
    }
    return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
}

func rgbString(from color: NSColor) -> String {
    guard let c = color.usingColorSpace(.sRGB) else { return "rgb(0, 0, 0)" }
    return "rgb(\(Int(round(c.redComponent * 255))), \(Int(round(c.greenComponent * 255))), \(Int(round(c.blueComponent * 255))))"
}

func hslString(from color: NSColor) -> String {
    guard let c = color.usingColorSpace(.sRGB) else { return "hsl(0, 0%, 0%)" }
    let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
    let maxV = max(r, g, b), minV = min(r, g, b)
    let l = (maxV + minV) / 2
    var h = 0.0, s = 0.0
    if maxV != minV {
        let d = maxV - minV
        s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxV == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h *= 60
    }
    return "hsl(\(Int(round(h))), \(Int(round(s * 100)))%, \(Int(round(l * 100)))%)"
}

// MARK: - Text helpers (pure — covered by tests.swift)
//
// Free functions, not AppController methods, so the CI
// test runner can call them without standing up the app.
// Keep them free of app state.

// Fetched page titles arrive raw: HTML entities undecoded
// ("&#8211;" printed literally on a card, Nov 18) and with
// whatever newlines the page's <head> had. Decode the common
// named entities plus any numeric ones, then collapse all
// whitespace runs to single spaces.
func cleanLinkTitle(_ raw: String) -> String {
    var s = raw
    let named: [(String, String)] = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
        ("&apos;", "'"), ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—"),
        ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&ldquo;", "“"), ("&rdquo;", "”"),
        ("&hellip;", "…"), ("&copy;", "©"), ("&middot;", "·")
    ]
    for (entity, replacement) in named {
        s = s.replacingOccurrences(of: entity, with: replacement)
    }
    var out = ""
    var rest = Substring(s)
    while let start = rest.range(of: "&#") {
        out += rest[..<start.lowerBound]
        let tail = rest[start.upperBound...]
        if let end = tail.firstIndex(of: ";"), tail.distance(from: tail.startIndex, to: end) <= 8 {
            let code = tail[..<end]
            let value: Int? = code.hasPrefix("x") || code.hasPrefix("X")
                ? Int(code.dropFirst(), radix: 16)
                : Int(code)
            if let value, let scalar = Unicode.Scalar(value) {
                out += String(Character(scalar))
                rest = tail[tail.index(after: end)...]
                continue
            }
        }
        out += "&#"
        rest = tail
    }
    out += rest
    return out.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func extractURLs(_ text: String) -> [String] {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return detector.matches(in: text, range: range).compactMap { $0.url?.absoluteString }
}

func prettyJSON(_ text: String) -> String? {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          JSONSerialization.isValidJSONObject(obj),
          let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: pretty, encoding: .utf8),
          s != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return s
}

// Trim each line, drop the ragged ends, and collapse runs of
// blank lines to one — the "clean this paste up" transform.
func trimmedText(_ text: String) -> String {
    var out: [String] = []
    var lastBlank = false
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            if lastBlank { continue }
            lastBlank = true
        } else {
            lastBlank = false
        }
        out.append(line)
    }
    return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Auth (v2.18.0)
//
// The Cognito client skeleton for ClipKeep Cloud. Every
// client — the Mac included — signs in through Cognito's
// OAuth web flow (authorization code + PKCE) in
// ASWebAuthenticationSession against the hosted UI on
// auth.starterdev.com: user pools cannot consume a native
// Apple/Google credential, so there is deliberately no
// native provider SDK here (RESEARCH-NOTES §2). Tokens live
// in ONE Keychain item so a rotated refresh token can never
// be half-written.
//
// AuthConfig.clientID carries the deployed pool's Mac
// app client (v2.19.0), so sign-in is live. Should it
// ever be empty, the sign-in UI stays fully visible
// (per the approved mocks) and signIn() reports "not
// configured" instead of starting a flow — the app
// ships honest, and ClipKeep stays fully local for
// anyone who never signs in.

enum AuthConfig {
    static let hostedDomain = "auth.starterdev.com"
    static let clientID = "t9qo46sedoq0k52i68uf4pl9v"   // the Mac app client (pool us-east-1_JvBBixLP9)
    // Apple sign-in returns when the Apple Developer
    // enrolment and a Cognito Apple IdP exist (removed
    // Nov 25, 2026 — it relied on a paid enrolment).
    static let callbackScheme = "io.starterdev.clipkeep"
    static let redirectURI = "io.starterdev.clipkeep://auth"

    static var isConfigured: Bool { !clientID.isEmpty }
    static var authorizeEndpoint: String { "https://\(hostedDomain)/oauth2/authorize" }
    static var tokenEndpoint: String { "https://\(hostedDomain)/oauth2/token" }
    static var revokeEndpoint: String { "https://\(hostedDomain)/oauth2/revoke" }
    // The Cognito IDP API endpoint for the native email
    // code flow (v2.19.3) — a regional host, not the
    // custom domain. The pool lives in us-east-1, so the
    // region is a literal here.
    static let idpEndpoint = "https://cognito-idp.us-east-1.amazonaws.com/"

    // The authorize URL for one provider. Google
    // deep-links its hosted-UI identity provider; email
    // opens the plain hosted UI, whose passwordless email
    // one-time code is a native Cognito (Essentials) first
    // factor — no custom challenge Lambdas.
    static func authorizeURL(provider: AuthProvider, state: String, challenge: String,
                             loginHint: String? = nil) -> URL? {
        var components = URLComponents(string: authorizeEndpoint)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        if let idp = provider.identityProviderParameter {
            query.append(URLQueryItem(name: "identity_provider", value: idp))
        }
        components?.queryItems = query
        guard var url = components?.url else { return nil }
        // login_hint (v2.18.1): the address typed into the
        // app's own email field rides along so the hosted UI
        // pre-fills it instead of asking a second time. It is
        // appended with formEscape rather than as a query
        // item: URLComponents leaves "+" (and "@") raw in
        // query values, and a raw + reads as a space to
        // form-style query parsers — exactly the character
        // email aliases use.
        if let loginHint, !loginHint.isEmpty,
           let hinted = URL(string: url.absoluteString + "&login_hint=\(formEscape(loginHint))") {
            url = hinted
        }
        return url
    }
}

enum AuthProvider {
    case google, email

    // The hosted UI's identity_provider value; nil = the
    // plain hosted UI (email code lives there).
    var identityProviderParameter: String? {
        switch self {
        case .google: return "Google"
        case .email: return nil
        }
    }
}

// MARK: base64url + SHA-256 (pure — covered by tests.swift)
//
// RFC 4648 §5 base64url without padding, and a from-scratch
// SHA-256 (FIPS 180-4). The single-file swiftc build has no
// bridging header for CommonCrypto, and CryptoKit would be
// a second framework for one digest; PKCE needs exactly one
// hash — SHA-256 of the verifier — so the implementation is
// small, fixed, and pinned by test vectors in tests.swift.

func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64URLDecode(_ string: String) -> Data? {
    var s = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}

func sha256(_ data: Data) -> Data {
    // Round constants: the first 32 bits of the fractional
    // parts of the cube roots of the first 64 primes.
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                       0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

    // Padding: message || 0x80 || zeros || the 64-bit
    // big-endian bit length, out to a multiple of 64 bytes.
    var message = [UInt8](data)
    let bitLength = UInt64(message.count) &* 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
        message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
    }

    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    var w = [UInt32](repeating: 0, count: 64)
    for blockStart in stride(from: 0, to: message.count, by: 64) {
        for i in 0..<16 {
            let j = blockStart + i * 4
            w[i] = (UInt32(message[j]) << 24) | (UInt32(message[j + 1]) << 16)
                 | (UInt32(message[j + 2]) << 8) | UInt32(message[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
        h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
    var digest = Data()
    for word in h {
        digest.append(UInt8((word >> 24) & 0xff))
        digest.append(UInt8((word >> 16) & 0xff))
        digest.append(UInt8((word >> 8) & 0xff))
        digest.append(UInt8(word & 0xff))
    }
    return digest
}

func sha256Hex(_ data: Data) -> String {
    sha256(data).map { String(format: "%02x", $0) }.joined()
}

// PKCE (RFC 7636): the verifier never leaves the app — only
// its SHA-256 rides in the authorize URL, and the token
// exchange proves possession. 32 random bytes → 43 chars.
func makePKCEVerifier() -> String {
    let bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) }
    return base64URLEncode(Data(bytes))
}

func pkceChallenge(for verifier: String) -> String {
    base64URLEncode(sha256(Data(verifier.utf8)))
}

func formEscape(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

struct AuthIdentity: Codable, Equatable {
    var name: String
    var email: String
    var subject: String   // the Cognito sub — sync data is keyed by this, never by email
}

// One stored session = one Keychain item (see AuthKeychain),
// so a rotated refresh token can never be half-written.
struct AuthSession: Codable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double   // access-token expiry, seconds since 1970
    var identity: AuthIdentity

    func isExpired(at now: Double) -> Bool { now >= expiresAt }
    // Refresh a little early rather than mid-request.
    func needsRefresh(at now: Double) -> Bool { now >= expiresAt - 300 }
}

// The ID token arrives over TLS straight from the token
// endpoint, so the client decodes its claims without
// verifying the signature — verification is the sync API's
// job (the pool's JWKS, on every request).
func decodeJWTPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count == 3, let data = base64URLDecode(String(parts[1])),
          let object = try? JSONSerialization.jsonObject(with: data),
          let claims = object as? [String: Any] else { return nil }
    return claims
}

func identityFromIDToken(_ token: String) -> AuthIdentity? {
    guard let claims = decodeJWTPayload(token),
          let subject = claims["sub"] as? String else { return nil }
    return AuthIdentity(name: claims["name"] as? String ?? "",
                        email: claims["email"] as? String ?? "",
                        subject: subject)
}

// MARK: Native email code flow (v2.19.3) — pure helpers
//
// The hosted-UI email path never reliably reached its
// code page, so the email code flow runs natively against
// the Cognito IDP API instead (the Mac client allows
// USER_AUTH): InitiateAuth asks for an EMAIL_OTP
// challenge, RespondToAuthChallenge answers it. A fresh
// address gets the same challenge — the account is
// created when the challenge completes — so nothing in
// the UI distinguishes sign-up from sign-in. These
// builders and the error copy are pure and pinned by
// tests.swift.

func initiateAuthBody(clientID: String, email: String) -> [String: Any] {
    [
        "ClientId": clientID,
        "AuthFlow": "USER_AUTH",
        "AuthParameters": [
            "USERNAME": email,
            "PREFERRED_CHALLENGE": "EMAIL_OTP"
        ]
    ]
}

func respondToAuthChallengeBody(clientID: String, email: String,
                                code: String, session: String) -> [String: Any] {
    [
        "ClientId": clientID,
        "ChallengeName": "EMAIL_OTP",
        "Session": session,
        "ChallengeResponses": [
            "USERNAME": email,
            "EMAIL_OTP_CODE": code
        ]
    ]
}

// Cognito's error names arrive in __type, sometimes
// carrying a namespace prefix ("...#CodeMismatchException")
// — match on the trailing name. The copy never echoes
// Cognito's own message: it is written for engineers, not
// for the person holding the code email.
func otpErrorMessage(cognitoType: String?, message: String?) -> String {
    let type = cognitoType?.split(separator: "#").last.map(String.init) ?? cognitoType
    switch type {
    case "CodeMismatchException":
        return "That code didn't match. Check it and try again."
    case "ExpiredCodeException":
        return "That code has expired. Send a new one and try again."
    case "NotAuthorizedException":
        return "This sign-in can't be completed that way."
    case "LimitExceededException", "TooManyRequestsException":
        return "Too many attempts. Wait a few minutes and try again."
    default:
        return "Something went wrong talking to ClipKeep Cloud. Check your connection and try again."
    }
}

/// The sign-in code a clipboard string carries, if it carries
/// one (v2.19.4): ignoring spaces and hyphens, the whole string
/// must be exactly six ASCII digits — "123456", " 123 456\n"
/// and "123-456" all read as the same code, while a sentence
/// containing a code, or a number of any other length, is not
/// a code. Strict on purpose: this feeds an automatic
/// sign-in attempt, so it may only fire on text that is
/// unmistakably a copied code.
func otpCodeFromClipboard(_ text: String?) -> String? {
    guard let text else { return nil }
    let stripped = text.filter { $0 != " " && $0 != "-" && $0 != "\t" && $0 != "\n" && $0 != "\r" }
    guard stripped.count == 6,
          stripped.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 })
    else { return nil }
    return stripped
}

// Tokens in ONE generic-password item, marked
// ThisDeviceOnly: they must not roam via iCloud Keychain or
// migrate to another Mac (RESEARCH-NOTES §4). Reads are
// failure-tolerant — a missing or unreadable item simply
// means "signed out", which matters because ad-hoc signing
// changes the app's code identity between builds and can
// orphan Keychain items across updates (the v2.16.5 TCC
// lesson, in Keychain form).
enum AuthKeychain {
    static let service = "io.starterdev.clipkeep.auth"
    static let account = "session"

    static func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func load() -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class AuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(AuthIdentity)
        case error(String)
    }

    // The native email code flow's progress (v2.19.3),
    // tracked apart from State: a code round trip is not a
    // sign-in state, and the surfaces render it inside the
    // signed-out card rather than as a global change.
    enum OTPPhase: Equatable {
        case idle
        case sending
        case awaitingCode(email: String, destination: String)
        case confirming
    }

    private(set) var state: State = .signedOut {
        didSet { onStateChange?() }
    }
    private(set) var session: AuthSession?

    private(set) var otpPhase: OTPPhase = .idle {
        didSet { onStateChange?() }
    }
    // The code card's error line. Set before the phase
    // change that accompanies it wherever both move, so
    // the refresh it fires already shows the final pair.
    var otpError: String? {
        didSet { onStateChange?() }
    }
    private var otpSession: String?

    // Wired by AppController: refresh the panel + Settings on
    // every transition, show the "not live yet" alert, and
    // the delete-unavailable note.
    var onStateChange: (() -> Void)?
    var onNotConfigured: (() -> Void)?
    var onDeleteUnavailable: (() -> Void)?
    // The window the system auth sheet anchors to — the
    // Settings window or the panel, whichever invoked it.
    weak var anchorWindow: NSWindow?

    private var webSession: ASWebAuthenticationSession?
    private var pendingVerifier: String?
    private var pendingState: String?

    override init() {
        let stored = AuthKeychain.load()
        session = stored
        super.init()
        if let stored {
            state = .signedIn(stored.identity)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorWindow ?? NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    private func restoreState() {
        if let current = session {
            state = .signedIn(current.identity)
        } else {
            state = .signedOut
        }
    }

    func signIn(provider: AuthProvider, loginHint: String? = nil) {
        guard AuthConfig.isConfigured else {
            onNotConfigured?()
            return
        }
        guard webSession == nil else { return }
        let verifier = makePKCEVerifier()
        let nonce = UUID().uuidString
        pendingVerifier = verifier
        pendingState = nonce
        guard let url = AuthConfig.authorizeURL(provider: provider, state: nonce,
                                                challenge: pkceChallenge(for: verifier),
                                                loginHint: loginHint) else {
            state = .error("Couldn't build the sign-in address.")
            return
        }
        state = .signingIn
        let web = ASWebAuthenticationSession(url: url, callbackURLScheme: AuthConfig.callbackScheme) { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                self?.finishSignIn(callbackURL: callbackURL, error: error)
            }
        }
        web.presentationContextProvider = self
        web.prefersEphemeralWebBrowserSession = false
        webSession = web
        if !web.start() {
            webSession = nil
            state = .error("Couldn't open the sign-in sheet.")
        }
    }

    // Cancels an in-flight web sign-in (v2.19.3): the
    // sheet closes and the state restores to whatever it
    // was. The completion the cancel triggers lands on
    // the same restore, so the two can't fight.
    func cancelWebSignIn() {
        guard let web = webSession else { return }
        webSession = nil
        pendingVerifier = nil
        pendingState = nil
        web.cancel()
        restoreState()
    }

    private func finishSignIn(callbackURL: URL?, error: Error?) {
        webSession = nil
        if let error {
            // The completion's errors are all in the
            // ASWebAuthenticationSession domain; a cancelled
            // sheet (code 1) is the common one and is not an
            // error state — the user just changed their mind.
            if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                restoreState()
            } else {
                state = .error(error.localizedDescription)
            }
            return
        }
        guard let callbackURL,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            state = .error("Sign-in didn't return to ClipKeep.")
            return
        }
        if let message = items.first(where: { $0.name == "error_description" })?.value
            ?? items.first(where: { $0.name == "error" })?.value {
            state = .error(message)
            return
        }
        guard items.first(where: { $0.name == "state" })?.value == pendingState,
              let code = items.first(where: { $0.name == "code" })?.value,
              let verifier = pendingVerifier else {
            state = .error("Sign-in returned an unexpected response.")
            return
        }
        pendingState = nil
        pendingVerifier = nil
        exchangeCode(code, verifier: verifier)
    }

    private func exchangeCode(_ code: String, verifier: String) {
        performTokenRequest(form: [
            "grant_type": "authorization_code",
            "client_id": AuthConfig.clientID,
            "code": code,
            "redirect_uri": AuthConfig.redirectURI,
            "code_verifier": verifier
        ]) { [weak self] newSession in
            if let newSession {
                self?.state = .signedIn(newSession.identity)
            } else {
                self?.state = .error("Sign-in couldn't be completed.")
            }
        }
    }

    // Refresh once when the access token is at/past the skew
    // window. Rotation rule (RESEARCH-NOTES §2): when the
    // response carries a NEW refresh token it always replaces
    // the stored one, and the merged session is written to
    // the Keychain before the state changes — a crash
    // mid-refresh can't lose the session. A refused refresh
    // means the session is over: fall back to signed-out
    // quietly, a state change and never a modal.
    func refreshIfNeeded() {
        guard AuthConfig.isConfigured, let current = session,
              current.needsRefresh(at: Date().timeIntervalSince1970),
              !current.refreshToken.isEmpty else { return }
        validIDToken(forceRefresh: true) { _ in }
    }

    // A usable ID token, for the sync engine's API calls:
    // the stored token while it is fresh, a refreshed one
    // otherwise — or forced, after the API answered 401.
    // The completion runs on the main queue. A refused
    // refresh ends the session exactly as refreshIfNeeded
    // always has (Keychain cleared, signed out quietly,
    // never a modal); any other failure also completes nil,
    // and the caller decides whether it was expiry or
    // weather.
    func validIDToken(forceRefresh: Bool, completion: @escaping (String?) -> Void) {
        guard let current = session else { completion(nil); return }
        if !forceRefresh, !current.needsRefresh(at: Date().timeIntervalSince1970) {
            completion(current.idToken)
            return
        }
        guard AuthConfig.isConfigured, !current.refreshToken.isEmpty else {
            completion(nil)
            return
        }
        performTokenRequest(form: [
            "grant_type": "refresh_token",
            "client_id": AuthConfig.clientID,
            "refresh_token": current.refreshToken
        ]) { [weak self] newSession in
            if let newSession {
                completion(newSession.idToken)
            } else {
                self?.session = nil
                AuthKeychain.clear()
                self?.state = .signedOut
                completion(nil)
            }
        }
    }

    // One token-endpoint round trip, shared by the code
    // exchange and refresh. The completion runs on the main
    // queue, with the Keychain already updated.
    private func performTokenRequest(form: [String: String], completion: @escaping (AuthSession?) -> Void) {
        guard let url = URL(string: AuthConfig.tokenEndpoint) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            var tokens: (idToken: String, accessToken: String, refreshToken: String?, expiresIn: Double)?
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data),
               let json = object as? [String: Any],
               let idToken = json["id_token"] as? String,
               let accessToken = json["access_token"] as? String {
                tokens = (idToken, accessToken, json["refresh_token"] as? String,
                          (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
            }
            DispatchQueue.main.async {
                var result: AuthSession?
                if let tokens {
                    result = self?.adoptSession(idToken: tokens.idToken,
                                                accessToken: tokens.accessToken,
                                                refreshToken: tokens.refreshToken,
                                                expiresIn: tokens.expiresIn)
                }
                completion(result)
            }
        }.resume()
    }

    // Adopts a fresh token set from either sign-in path
    // (the OAuth token endpoint above, the email code
    // flow below): builds the session, stores it, writes
    // the Keychain BEFORE the state changes — a crash
    // mid-write can't lose the session — clears any email
    // code round trip still in flight, and lands on
    // signed-in. Returns nil when the ID token doesn't
    // decode. Call on the main queue.
    @discardableResult
    private func adoptSession(idToken: String, accessToken: String,
                              refreshToken: String?, expiresIn: Double) -> AuthSession? {
        guard let identity = identityFromIDToken(idToken) else { return nil }
        // Rotation: a new refresh token in the response
        // always wins; only when the response omits one
        // does the stored token carry over. (The email
        // code flow's response always carries one.)
        let refresh = refreshToken ?? session?.refreshToken ?? ""
        let newSession = AuthSession(idToken: idToken, accessToken: accessToken,
                                     refreshToken: refresh,
                                     expiresAt: Date().timeIntervalSince1970 + expiresIn,
                                     identity: identity)
        session = newSession
        AuthKeychain.save(newSession)
        if otpPhase != .idle || otpError != nil || otpSession != nil {
            otpSession = nil
            otpError = nil
            otpPhase = .idle
        }
        state = .signedIn(identity)
        return newSession
    }

    // MARK: Native email code flow (v2.19.3)

    // Asks Cognito to email a one-time code. Also the
    // Resend path: calling again with the same address
    // starts a fresh challenge with a fresh session.
    func startEmailOTP(email: String) {
        switch otpPhase {
        case .idle, .awaitingCode: break
        case .sending, .confirming: return
        }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.contains("@") else {
            otpError = "Enter your email address first."
            return
        }
        guard AuthConfig.isConfigured else {
            onNotConfigured?()
            return
        }
        otpError = nil
        otpPhase = .sending
        performIDPRequest(target: "AWSCognitoIdentityProviderService.InitiateAuth",
                          body: initiateAuthBody(clientID: AuthConfig.clientID, email: address)) { [weak self] json, errorType, _ in
            guard let self, self.otpPhase == .sending else { return }
            if let json, let result = json["AuthenticationResult"] as? [String: Any] {
                // No challenge was needed — rare, but the
                // tokens are the whole point either way.
                if self.completeOTPSignIn(result) { return }
                self.otpError = otpErrorMessage(cognitoType: nil, message: nil)
                self.otpPhase = .idle
                return
            }
            if let json, (json["ChallengeName"] as? String) == "EMAIL_OTP",
               let session = json["Session"] as? String {
                let parameters = json["ChallengeParameters"] as? [String: Any]
                let destination = parameters?["CODE_DELIVERY_DESTINATION"] as? String ?? address
                self.otpSession = session
                self.otpPhase = .awaitingCode(email: address, destination: destination)
                return
            }
            self.otpError = otpErrorMessage(cognitoType: errorType, message: nil)
            self.otpPhase = .idle
        }
    }

    func confirmEmailOTP(code: String) {
        guard case .awaitingCode(let email, let destination) = otpPhase,
              let sentSession = otpSession else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            otpError = "Enter the code from the email first."
            return
        }
        otpError = nil
        otpPhase = .confirming
        performIDPRequest(target: "AWSCognitoIdentityProviderService.RespondToAuthChallenge",
                          body: respondToAuthChallengeBody(clientID: AuthConfig.clientID,
                                                           email: email, code: trimmed,
                                                           session: sentSession)) { [weak self] json, errorType, _ in
            guard let self else { return }
            // A cancel (or a newer flow) while the answer
            // was in flight wins: the late response is not
            // adopted.
            guard self.otpPhase == .confirming, self.otpSession == sentSession else { return }
            if let json, let result = json["AuthenticationResult"] as? [String: Any],
               self.completeOTPSignIn(result) {
                return
            }
            // Back to code entry with the reason showing.
            // The stored session usually survives a wrong
            // or expired code; if Cognito killed it, the
            // next answer fails too and Resend starts over.
            self.otpError = otpErrorMessage(cognitoType: errorType, message: nil)
            self.otpPhase = .awaitingCode(email: email, destination: destination)
        }
    }

    func cancelEmailOTP() {
        otpSession = nil
        otpError = nil
        otpPhase = .idle
    }

    // The AuthenticationResult half of either IDP call.
    // Its keys are CamelCase, unlike the OAuth token
    // endpoint's snake_case.
    private func completeOTPSignIn(_ tokenJSON: [String: Any]) -> Bool {
        guard let idToken = tokenJSON["IdToken"] as? String,
              let accessToken = tokenJSON["AccessToken"] as? String else { return false }
        let expiresIn = (tokenJSON["ExpiresIn"] as? NSNumber)?.doubleValue ?? 3600
        return adoptSession(idToken: idToken, accessToken: accessToken,
                            refreshToken: tokenJSON["RefreshToken"] as? String,
                            expiresIn: expiresIn) != nil
    }

    // One Cognito IDP API round trip. The completion runs
    // on the main queue with the parsed payload and, for
    // an error payload, its __type and message (the UI
    // copy comes from otpErrorMessage, never from
    // Cognito's own wording).
    private func performIDPRequest(target: String, body: [String: Any],
                                   completion: @escaping ([String: Any]?, String?, String?) -> Void) {
        guard let url = URL(string: AuthConfig.idpEndpoint),
              let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { completion(nil, nil, nil) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = httpBody
        URLSession.shared.dataTask(with: request) { data, _, _ in
            var json: [String: Any]?
            var errorType: String?
            var errorMessage: String?
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data),
               let parsed = object as? [String: Any] {
                json = parsed
                errorType = parsed["__type"] as? String
                errorMessage = parsed["message"] as? String
            }
            DispatchQueue.main.async { completion(json, errorType, errorMessage) }
        }.resume()
    }

    // Local sign-out (RESEARCH-NOTES §4): revoke the refresh
    // token best-effort so it dies server-side too, clear the
    // Keychain, and leave the local history untouched. Global
    // sign-out is deliberately NOT what this does.
    func signOut() {
        if AuthConfig.isConfigured, let current = session, !current.refreshToken.isEmpty,
           let url = URL(string: AuthConfig.revokeEndpoint) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "client_id=\(formEscape(AuthConfig.clientID))&token=\(formEscape(current.refreshToken))&token_type_hint=refresh_token"
                .data(using: .utf8)
            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        }
        session = nil
        AuthKeychain.clear()
        otpSession = nil
        otpError = nil
        otpPhase = .idle
        state = .signedOut
    }

    // Skeleton: the DELETE /account endpoint doesn't exist
    // yet, so there is nothing honest to call. AppController
    // confirms with the user first, then lands here — the
    // answer is "enabled when sync launches", never a fake
    // deletion.
    func deleteAccount() {
        onDeleteUnavailable?()
    }
}

// MARK: - Sync engine (ClipKeep Cloud)
//
// The Mac half of the deployed sync API (SYNC-ENGINE-DESIGN.md):
// push/pull against the API Gateway base below, every call
// carrying the Cognito ID token. Ordering never trusts this
// Mac's clock for sequence — the server assigns a per-user
// rev to every accepted write, and the pull watermark below
// is that rev. Within one clip, last-writer-wins runs on
// updatedAt, the server enforcing it with a conditional
// write and this engine mirroring the same rule when a pull
// lands, so the two never fight.
//
// The pure pieces (the wire mapping both directions, the
// acceptance rule, watermark advancement, batching) are free
// functions so tests.swift can pin them; SyncEngine itself
// is transport + state and is only ever driven from
// AppController, on the main queue.

struct SyncImageRef: Codable, Equatable {
    var file: String        // the cloud object key
    var sha256: String
    var width: Int?
    var height: Int?
}

struct SyncFileRef: Codable, Equatable {
    var name: String
    var size: Int
    var bytesSynced: Bool
}

struct SyncOrigin: Codable, Equatable {
    var deviceId: String
    var platform: String
}

// The on-the-wire clip (backend ClipRecord, schema 1), plus
// the two server-stamped fields a pull carries back. Clients
// never set rev/serverUpdatedAt — they stay nil on the way
// out, and the synthesized encoder omits nil keys.
struct SyncClipRecord: Codable, Equatable {
    var schema: Int
    var id: String
    var kind: String        // "text", "link", "image", "file", "color"
    var text: String?
    var linkTitle: String?
    var image: SyncImageRef?
    var ocrText: String?
    var file: SyncFileRef?
    var sourceApp: String?
    var sourceId: String?
    var createdAt: Double
    var updatedAt: Double
    var pinned: Bool
    var board: String?
    var origin: SyncOrigin
    var deleted: Bool
    var rev: Int?
    var serverUpdatedAt: Double?
}

struct SyncPullResponse: Codable {
    var items: [SyncClipRecord]
    var currentRev: Int
    var nextSinceRev: Int
    var hasMore: Bool
}

struct SyncPushRequest: Codable {
    var clips: [SyncClipRecord]
}

struct SyncPushResult: Codable {
    var id: String
    var rev: Int
    var applied: Bool
    var current: SyncClipRecord?   // the winning stored version, when applied == false
}

struct SyncPushResponse: Codable {
    var currentRev: Int
    var results: [SyncPushResult]
}

struct SyncPresignResponse: Codable {
    var exists: Bool
    var key: String
    var uploadUrl: String?
    var downloadUrl: String?
    var expiresIn: Int?
}

// The engine's per-account record, persisted as JSON in
// UserDefaults. Keyed by the Cognito sub: a different
// account never inherits a watermark or an outbox — the
// engine starts it fresh (workingAccount(for:)).
struct SyncAccountState: Codable {
    var subject: String
    var watermark: Int = 0              // last fully-applied pull rev
    var outbox: [String] = []           // clip ids awaiting push, oldest first
    var ackedTombstones: [String: Double] = [:]   // id → deletion time the server has
    var firstSyncDone: Bool = false
    var lastSyncAt: Double? = nil
}

// The link test, shared by AppController.isLinkItem and the
// wire mapping: a text clip whose whole trimmed text is one
// http/https URL. "link" is not a stored kind on the Mac —
// it is derived here, and made explicit only on the wire.
func clipIsLink(kind: String, text: String?) -> Bool {
    guard kind == "text", let raw = text else { return false }
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.contains(" "), !t.contains("\n"),
          let url = URL(string: t), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https", url.host != nil else { return false }
    return true
}

// Local clip → wire record. The image ref is precomputed by
// the caller (it needs file bytes and a presign round trip);
// fileSize likewise (the file's on-disk size, when readable).
// deleted marks the record as a tombstone push.
func syncRecord(from item: ClipItem, image: SyncImageRef?, fileSize: Int?,
                deviceID: String, deleted: Bool) -> SyncClipRecord {
    var file: SyncFileRef?
    if item.kind == "file" {
        file = SyncFileRef(
            name: item.filePath.map { ($0 as NSString).lastPathComponent } ?? item.remoteFileName ?? "File",
            size: fileSize ?? 0,
            bytesSynced: false)
    }
    return SyncClipRecord(
        schema: 1,
        id: item.id,
        kind: clipIsLink(kind: item.kind, text: item.text) ? "link" : item.kind,
        text: item.text,
        linkTitle: item.linkTitle,
        image: item.kind == "image" ? image : nil,
        ocrText: item.ocrText,
        file: file,
        sourceApp: item.sourceApp,
        sourceId: item.sourceBundleID,
        createdAt: item.createdAt,
        updatedAt: item.effectiveUpdatedAt,
        pinned: item.pinned,
        board: item.board,
        origin: SyncOrigin(deviceId: item.originDevice ?? deviceID,
                           platform: item.originPlatform ?? "mac"),
        deleted: deleted,
        rev: nil,
        serverUpdatedAt: nil)
}

// Wire record → local clip. Image bytes and file bytes are
// NOT here: a pulled image clip lands metadata-first (its
// cloud sha/key ride along for the lazy fetch), and a pulled
// file clip keeps only its name — v1 never moves file bytes.
func clipItem(from record: SyncClipRecord) -> ClipItem {
    var item = ClipItem(id: record.id,
                        kind: record.kind == "link" ? "text" : record.kind,
                        text: record.text, imageFile: nil,
                        createdAt: record.createdAt, pinned: record.pinned,
                        filePath: nil, sourceApp: record.sourceApp,
                        sourceBundleID: record.sourceId,
                        ocrText: record.ocrText, board: record.board,
                        contentHash: nil)
    item.linkTitle = record.linkTitle
    item.updatedAt = record.updatedAt
    item.originDevice = record.origin.deviceId
    item.originPlatform = record.origin.platform
    item.remoteImageSHA256 = record.image?.sha256
    item.remoteImageKey = record.image?.file
    item.remoteFileName = record.file?.name
    return item
}

// The acceptance rule for a pulled record, mirroring the
// server's push condition (updatedAt <= incoming applies):
// a strictly newer record wins; an older one loses; on an
// exact tie the origin device id decides — the
// lexicographically greater id wins — so two devices
// holding the same clip at the same instant converge on
// the same copy instead of flip-flopping.
func syncAccepts(incomingUpdatedAt: Double, incomingDevice: String,
                 localUpdatedAt: Double, localDevice: String) -> Bool {
    if incomingUpdatedAt != localUpdatedAt { return incomingUpdatedAt > localUpdatedAt }
    return incomingDevice > localDevice
}

// The watermark moves ONLY when a pull page was applied in
// full — a half-applied page must be re-fetched, not
// skipped — and it never moves backwards.
func syncAdvancedWatermark(current: Int, pageLastRev: Int, fullyApplied: Bool) -> Int {
    fullyApplied ? max(current, pageLastRev) : current
}

// Split the outbox into push batches (the API caps a push
// at 100 clips), oldest first, order preserved.
func syncBatches<T>(_ items: [T], limit: Int = 100) -> [[T]] {
    guard limit > 0, !items.isEmpty else { return [] }
    var batches: [[T]] = []
    var index = 0
    while index < items.count {
        batches.append(Array(items[index ..< min(index + limit, items.count)]))
        index += limit
    }
    return batches
}

func syncContentType(forExt ext: String) -> String {
    switch ext.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic": return "image/heic"
    case "tiff": return "image/tiff"
    default: return "image/png"
    }
}

final class SyncEngine {
    enum State: Equatable {
        case idle            // up to date (or never run)
        case syncing
        case offline         // the last attempt got no usable answer
        case signInExpired   // 401 even after one forced refresh
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?() } }
    }
    // Mirrors AuthManager's wiring: AppController refreshes
    // the Sync view + Settings Account tab on every change.
    var onStateChange: (() -> Void)?
    weak var app: AppController?

    private var running = false
    private var followUpNeeded = false
    private var debounceWork: DispatchWorkItem?
    private var imageFetchesInFlight: Set<String> = []
    // Clips whose bytes the cloud answered exists:false for —
    // a normal state (the origin device hasn't uploaded, or
    // the object is gone), not an error; don't ask again
    // this launch.
    private var imageFetchMisses: Set<String> = []

    static let apiBase = "https://ajiilxo2e6.execute-api.us-east-1.amazonaws.com"
    private static let stateKey = "ClipKeepSyncStateV1"

    // MARK: Persisted per-account state

    private func storedAccount() -> SyncAccountState {
        if let data = UserDefaults.standard.data(forKey: Self.stateKey),
           let decoded = try? JSONDecoder().decode(SyncAccountState.self, from: data) {
            return decoded
        }
        return SyncAccountState(subject: "")
    }

    private func saveStoredAccount(_ acct: SyncAccountState) {
        if let data = try? JSONEncoder().encode(acct) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    // The record a cycle works on: the stored one when it
    // belongs to this account, a fresh one otherwise.
    private func workingAccount(for subject: String) -> SyncAccountState {
        let stored = storedAccount()
        return stored.subject == subject ? stored : SyncAccountState(subject: subject)
    }

    // The last completed sync for the CURRENTLY signed-in
    // account (nil for any other account, or never).
    var displayLastSyncAt: Double? {
        guard let subject = app?.auth.session?.identity.subject else { return nil }
        let stored = storedAccount()
        return stored.subject == subject ? stored.lastSyncAt : nil
    }

    // MARK: Triggers

    // A local mutation files its clip id in the outbox —
    // unconditionally, signed in or not, sync on or not: the
    // filing is a set insert, and the drain decides later.
    // (Mutations made under a different account than the
    // stored record's are still safe: a fresh account's
    // first sync files the whole local history anyway.)
    func enqueue(_ id: String) {
        var acct = storedAccount()
        if !acct.outbox.contains(id) {
            acct.outbox.append(id)
            saveStoredAccount(acct)
        }
        scheduleDebouncedSync()
    }

    private func scheduleDebouncedSync() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // The panel opened: catch up if the last sync is stale.
    func notePanelOpened() {
        guard let last = displayLastSyncAt else { syncNow(); return }
        if Date().timeIntervalSince1970 - last > 60 { syncNow() }
    }

    // One sync cycle, when there's anything to run it with.
    // Signed out or sync off, the engine is inert — the app
    // behaves exactly as it did before sync existed.
    func syncNow() {
        guard let app, app.syncEnabled, app.auth.session != nil else { return }
        if running { followUpNeeded = true; return }
        runCycle()
    }

    // MARK: One cycle — pull, then push

    private func runCycle() {
        guard let app, let session = app.auth.session else { return }
        running = true
        state = .syncing
        let subject = session.identity.subject
        // Persist the working record up front, so an account
        // switch is durable even if this cycle dies early.
        saveStoredAccount(workingAccount(for: subject))
        pullPhase(subject: subject)
    }

    private func finishCycle(_ outcome: State, synced: Bool = false) {
        if synced, let subject = app?.auth.session?.identity.subject {
            var acct = workingAccount(for: subject)
            acct.lastSyncAt = Date().timeIntervalSince1970
            saveStoredAccount(acct)
        }
        running = false
        state = outcome
        if followUpNeeded {
            followUpNeeded = false
            if outcome == .idle || outcome == .offline { syncNow() }
        }
    }

    private func pullPhase(subject: String) {
        guard app != nil else { finishCycle(.offline); return }
        let watermark = workingAccount(for: subject).watermark
        guard let url = URL(string: "\(Self.apiBase)/sync/pull?sinceRev=\(watermark)") else {
            finishCycle(.offline)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        apiCall(request) { [weak self] data, status in
            guard let self else { return }
            if status == 401 { self.finishCycle(.signInExpired); return }
            guard status == 200, let data,
                  let page = try? JSONDecoder().decode(SyncPullResponse.self, from: data) else {
                self.finishCycle(.offline)
                return
            }
            self.applyPullPage(page, subject: subject)
            if page.hasMore {
                self.pullPhase(subject: subject)
            } else {
                self.pushPhase(subject: subject)
            }
        }
    }

    // Apply one pull page in rev order, then — and only
    // then — advance the watermark to the page's end.
    private func applyPullPage(_ page: SyncPullResponse, subject: String) {
        guard let app else { return }
        var acct = workingAccount(for: subject)
        var changed = false
        var insertedAny = false
        for record in page.items {
            if record.deleted {
                // Already the server's state: acknowledge it
                // locally so the push sweep never re-sends it.
                acct.ackedTombstones[record.id] = record.updatedAt
                if app.store.items.contains(where: { $0.id == record.id }) {
                    app.store.applyRemoteDeletion(clipItem(from: record))
                    changed = true
                } else if let stone = app.store.tombstones.first(where: { $0.id == record.id }),
                          record.updatedAt > stone.effectiveUpdatedAt {
                    app.store.applyRemoteDeletion(clipItem(from: record))
                }
                continue
            }
            if let stone = app.store.tombstones.first(where: { $0.id == record.id }) {
                // Deleted here; the incoming copy wins only
                // if it is strictly newer than the deletion.
                guard record.updatedAt > stone.effectiveUpdatedAt else {
                    if !acct.outbox.contains(record.id) { acct.outbox.append(record.id) }
                    continue
                }
                app.store.tombstones.removeAll { $0.id == record.id }
                app.store.items.append(clipItem(from: record))
                changed = true
                insertedAny = true
                continue
            }
            if let idx = app.store.items.firstIndex(where: { $0.id == record.id }) {
                let local = app.store.items[idx]
                if syncAccepts(incomingUpdatedAt: record.updatedAt, incomingDevice: record.origin.deviceId,
                               localUpdatedAt: local.effectiveUpdatedAt, localDevice: local.originDevice ?? "") {
                    var replacement = clipItem(from: record)
                    // The same image already on disk: keep the
                    // local file (and its dedupe hash) rather
                    // than refetching identical bytes.
                    if record.kind == "image", let localName = local.imageFile,
                       local.remoteImageSHA256 == record.image?.sha256 {
                        replacement.imageFile = localName
                        replacement.contentHash = local.contentHash
                    }
                    app.store.items[idx] = replacement
                    changed = true
                } else if local.effectiveUpdatedAt > record.updatedAt {
                    // Our copy is the newer one: queue it so
                    // the server converges on it.
                    if !acct.outbox.contains(record.id) { acct.outbox.append(record.id) }
                }
            } else {
                app.store.items.append(clipItem(from: record))
                changed = true
                insertedAny = true
            }
        }
        if insertedAny {
            // Feed order: pinned first, then newest — the
            // same comparator togglePin re-sorts with.
            app.store.items.sort { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.createdAt > b.createdAt
            }
        }
        acct.watermark = syncAdvancedWatermark(current: acct.watermark,
                                               pageLastRev: page.nextSinceRev,
                                               fullyApplied: true)
        saveStoredAccount(acct)
        if changed {
            app.store.save()
            app.refreshList()
        }
    }

    private func pushPhase(subject: String) {
        guard let app else { finishCycle(.offline); return }
        var acct = workingAccount(for: subject)
        // First sync for this account: everything local the
        // server has never seen joins the outbox (the pull
        // above already merged what the server DID have).
        if !acct.firstSyncDone {
            for item in app.store.items where !acct.outbox.contains(item.id) {
                acct.outbox.append(item.id)
            }
            acct.firstSyncDone = true
        }
        // Tombstone sweep: deletions no enqueue could see
        // (trims inside the store) still reach the server.
        // Acknowledged tombstones are skipped by their
        // deletion time, so a re-delete re-sends.
        for stone in app.store.tombstones where acct.ackedTombstones[stone.id] != stone.effectiveUpdatedAt {
            if !acct.outbox.contains(stone.id) { acct.outbox.append(stone.id) }
        }
        saveStoredAccount(acct)
        guard let batch = syncBatches(acct.outbox).first, !batch.isEmpty else {
            finishCycle(.idle, synced: true)
            return
        }
        preparePushBatch(batch, subject: subject) { [weak self] records in
            guard let self else { return }
            guard !records.isEmpty else {
                // Every clip in the batch was skipped (its
                // image upload failed): leave the outbox
                // untouched and stop — the next trigger
                // retries.
                self.finishCycle(.offline)
                return
            }
            self.sendPushBatch(records, subject: subject)
        }
    }

    // Build the wire records for one outbox batch. The
    // outbox holds ids; the store decides what an id
    // currently means — a live clip pushes its record, a
    // tombstoned id pushes a delete, an id that is neither
    // (purged past retention) is simply dropped.
    private func preparePushBatch(_ ids: [String], subject: String,
                                  completion: @escaping ([SyncClipRecord]) -> Void) {
        guard let app else { completion([]); return }
        var records: [SyncClipRecord] = []
        var index = 0
        func step() {
            if index >= ids.count { completion(records); return }
            let id = ids[index]
            index += 1
            if let item = app.store.items.first(where: { $0.id == id }) {
                if item.kind == "image" {
                    prepareImageRecord(item) { ref in
                        if let ref {
                            records.append(syncRecord(from: item, image: ref, fileSize: nil,
                                                      deviceID: app.store.deviceID, deleted: false))
                        }
                        step()
                    }
                } else {
                    var fileSize: Int?
                    if item.kind == "file", let path = item.filePath,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                       let size = attrs[.size] as? NSNumber {
                        fileSize = size.intValue
                    }
                    records.append(syncRecord(from: item, image: nil, fileSize: fileSize,
                                              deviceID: app.store.deviceID, deleted: false))
                    step()
                }
            } else if let stone = app.store.tombstones.first(where: { $0.id == id }) {
                records.append(syncRecord(from: stone, image: nil, fileSize: nil,
                                          deviceID: app.store.deviceID, deleted: true))
                step()
            } else {
                var acct = workingAccount(for: subject)
                acct.outbox.removeAll { $0 == id }
                saveStoredAccount(acct)
                step()
            }
        }
        step()
    }

    private func sendPushBatch(_ records: [SyncClipRecord], subject: String) {
        guard let url = URL(string: "\(Self.apiBase)/sync/push") else {
            finishCycle(.offline)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(SyncPushRequest(clips: records))
        apiCall(request) { [weak self] data, status in
            guard let self, let app = self.app else { return }
            if status == 401 { self.finishCycle(.signInExpired); return }
            guard status == 200, let data,
                  let response = try? JSONDecoder().decode(SyncPushResponse.self, from: data) else {
                self.finishCycle(.offline)
                return
            }
            var acct = self.workingAccount(for: subject)
            var adopted = false
            for result in response.results {
                acct.outbox.removeAll { $0 == result.id }
                if let stone = app.store.tombstones.first(where: { $0.id == result.id }) {
                    acct.ackedTombstones[result.id] = stone.effectiveUpdatedAt
                }
                if !result.applied, let current = result.current {
                    // The server's stored version won: adopt
                    // it wholesale, no local arbitration.
                    self.adoptServerVersion(current)
                    if current.deleted {
                        acct.ackedTombstones[result.id] = current.updatedAt
                    }
                    adopted = true
                }
            }
            self.saveStoredAccount(acct)
            if adopted {
                app.store.save()
                app.refreshList()
            }
            if !acct.outbox.isEmpty, !response.results.isEmpty {
                self.pushPhase(subject: subject)
            } else if !acct.outbox.isEmpty {
                // The server answered for none of the batch:
                // stop rather than loop on it — the outbox
                // keeps the ids and the next trigger retries.
                self.finishCycle(.offline)
            } else {
                self.finishCycle(.idle, synced: true)
            }
        }
    }

    private func adoptServerVersion(_ record: SyncClipRecord) {
        guard let app else { return }
        if record.deleted {
            app.store.applyRemoteDeletion(clipItem(from: record))
            return
        }
        let incoming = clipItem(from: record)
        if let idx = app.store.items.firstIndex(where: { $0.id == record.id }) {
            var replacement = incoming
            if record.kind == "image", let localName = app.store.items[idx].imageFile,
               app.store.items[idx].remoteImageSHA256 == record.image?.sha256 {
                replacement.imageFile = localName
                replacement.contentHash = app.store.items[idx].contentHash
            }
            app.store.items[idx] = replacement
        } else {
            app.store.tombstones.removeAll { $0.id == record.id }
            app.store.items.append(incoming)
            app.store.items.sort { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.createdAt > b.createdAt
            }
        }
    }

    // MARK: Image bytes — upload on push, lazy download on display

    // The wire ref for one image clip, uploading its bytes
    // first when the cloud doesn't have them. Completes nil
    // when the bytes can't be put in the cloud right now —
    // the clip is skipped this cycle and stays in the outbox.
    private func prepareImageRecord(_ item: ClipItem, completion: @escaping (SyncImageRef?) -> Void) {
        guard let app else { completion(nil); return }
        // Pulled clip, bytes never landed here, never edited
        // since: the cloud already holds them under this key.
        if item.imageFile == nil, let sha = item.remoteImageSHA256, let key = item.remoteImageKey {
            completion(SyncImageRef(file: key, sha256: sha, width: nil, height: nil))
            return
        }
        guard let fileURL = app.store.imageURL(for: item) else { completion(nil); return }
        DispatchQueue.global(qos: .utility).async {
            let data = try? Data(contentsOf: fileURL)
            DispatchQueue.main.async {
                guard let data else { completion(nil); return }
                let sha = sha256Hex(data)
                let ext = ((item.imageFile ?? "") as NSString).pathExtension.lowercased()
                let extOrPNG = ext.isEmpty ? "png" : ext
                var dims: (Int, Int)?
                if let name = item.imageFile, let size = app.imageDimensions(forFile: name) {
                    dims = (Int(size.width), Int(size.height))
                }
                if item.remoteImageSHA256 == sha, let key = item.remoteImageKey {
                    completion(SyncImageRef(file: key, sha256: sha, width: dims?.0, height: dims?.1))
                    return
                }
                self.presign(sha256: sha, ext: extOrPNG, action: nil) { [weak self] response in
                    guard let self, let response else { completion(nil); return }
                    if response.exists {
                        self.noteImageUploaded(itemID: item.id, sha256: sha, key: response.key)
                        completion(SyncImageRef(file: response.key, sha256: sha, width: dims?.0, height: dims?.1))
                    } else if let uploadUrl = response.uploadUrl {
                        self.uploadBytes(data, to: uploadUrl, contentType: syncContentType(forExt: extOrPNG)) { [weak self] ok in
                            guard let self else { completion(nil); return }
                            if ok {
                                self.noteImageUploaded(itemID: item.id, sha256: sha, key: response.key)
                                completion(SyncImageRef(file: response.key, sha256: sha, width: dims?.0, height: dims?.1))
                            } else {
                                completion(nil)
                            }
                        }
                    } else {
                        completion(nil)
                    }
                }
            }
        }
    }

    // Remember that a clip's bytes are in the cloud, so the
    // next push of the same clip skips the upload. Not a
    // mutation for LWW purposes — updatedAt stays put.
    private func noteImageUploaded(itemID: String, sha256: String, key: String) {
        guard let app, let idx = app.store.items.firstIndex(where: { $0.id == itemID }) else { return }
        app.store.items[idx].remoteImageSHA256 = sha256
        app.store.items[idx].remoteImageKey = key
        app.store.save()
    }

    // Lazy download: a pulled image clip's card asks for its
    // bytes the first time it renders without them. They land
    // in the images folder under their hash (identical images
    // share one file), the thumbnail cache picks them up on
    // the next rebuild, and the clip's local dedupe hash is
    // stamped so a re-copy of the same image dedupes as usual.
    func fetchImageIfNeeded(_ item: ClipItem) {
        guard let app, app.syncEnabled, app.auth.session != nil,
              item.kind == "image",
              let sha = item.remoteImageSHA256,
              !imageFetchesInFlight.contains(item.id),
              !imageFetchMisses.contains(item.id) else { return }
        if let name = item.imageFile,
           FileManager.default.fileExists(atPath: app.store.imagesDir.appendingPathComponent(name).path) {
            return
        }
        imageFetchesInFlight.insert(item.id)
        let ext = item.remoteImageKey.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        presign(sha256: sha, ext: ext.isEmpty ? "png" : ext, action: "download") { [weak self] response in
            guard let self else { return }
            guard let response, response.exists, let downloadUrl = response.downloadUrl,
                  let url = URL(string: downloadUrl) else {
                self.imageFetchesInFlight.remove(item.id)
                self.imageFetchMisses.insert(item.id)
                return
            }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.imageFetchesInFlight.remove(item.id)
                    guard let data, let app = self.app,
                          let idx = app.store.items.firstIndex(where: { $0.id == item.id }) else { return }
                    let name = "\(sha).\(ext.isEmpty ? "png" : ext)"
                    let fileURL = app.store.imagesDir.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        try? data.write(to: fileURL)
                    }
                    app.store.items[idx].imageFile = name
                    app.store.items[idx].contentHash = fnvHash(data)
                    app.store.save()
                    app.refreshList()
                }
            }.resume()
        }
    }

    // MARK: Transport

    // One API call with the current ID token. On 401,
    // exactly one forced refresh and one retry; a second
    // 401 surfaces as-is and the caller reads it as an
    // expired sign-in. statusCode 0 = no answer at all.
    // Completions run on the main queue.
    private func apiCall(_ request: URLRequest, completion: @escaping (Data?, Int) -> Void) {
        guard let app else { completion(nil, 0); return }
        app.auth.validIDToken(forceRefresh: false) { [weak self] token in
            guard let self, let token else { completion(nil, 401); return }
            self.attempt(request, token: token, isRetry: false, completion: completion)
        }
    }

    private func attempt(_ request: URLRequest, token: String, isRetry: Bool,
                         completion: @escaping (Data?, Int) -> Void) {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { completion(nil, 0); return }
                if status == 401, !isRetry {
                    self.app?.auth.validIDToken(forceRefresh: true) { [weak self] fresh in
                        guard let self, let fresh else { completion(nil, 401); return }
                        self.attempt(request, token: fresh, isRetry: true, completion: completion)
                    }
                } else {
                    completion(data, status)
                }
            }
        }.resume()
    }

    // The presign endpoint, both directions: upload (the
    // default — mint a PUT URL, or learn the object already
    // exists) and download (action: "download" — mint a GET
    // URL for the caller's own copy). Nil = the call failed.
    private func presign(sha256: String, ext: String, action: String?,
                         completion: @escaping (SyncPresignResponse?) -> Void) {
        guard let url = URL(string: "\(Self.apiBase)/uploads/presign") else {
            completion(nil)
            return
        }
        var body: [String: Any] = ["sha256": sha256]
        if !ext.isEmpty { body["ext"] = ext }
        if let action {
            body["action"] = action
        } else {
            body["contentType"] = syncContentType(forExt: ext)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        apiCall(request) { data, status in
            guard status == 200, let data,
                  let response = try? JSONDecoder().decode(SyncPresignResponse.self, from: data) else {
                completion(nil)
                return
            }
            completion(response)
        }
    }

    private func uploadBytes(_ data: Data, to urlString: String, contentType: String,
                             completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: urlString) else { completion(false); return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        URLSession.shared.uploadTask(with: request, from: data) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { completion(status == 200) }
        }.resume()
    }
}

// MARK: - App

// Borderless panel window (v2.10.0): a .borderless NSWindow
// refuses key status by default, which would leave the search
// field unable to take keyboard focus. Overriding canBecomeKey /
// canBecomeMain restores normal key behaviour for the panel.
final class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppController: NSObject, NSApplicationDelegate, NSSearchFieldDelegate, NSWindowDelegate, URLSessionDownloadDelegate {
    static let shared = AppController()

    let store = ClipStore()
    var statusItem: NSStatusItem!
    var timeRefreshTimer: Timer?
    var panel: BorderlessWindow!
    var searchField: NSSearchField!
    var pillTabs: PillTabsView!
    var boardPopup: NSPopUpButton!
    var appPopup: NSPopUpButton!
    var recencyPopup: NSPopUpButton!
    var sortPopup: NSPopUpButton!
    var sortShell: ToolbarShell!
    var tintView: NSView!
    var overflowButton: HoverButton!
    var toolbarShells: [ToolbarShell] = []
    var currentTheme: PanelTheme = panelThemes[0]
    var stackBar: NSStackView!
    var stackLabel: NSTextField!
    var listStack: NSStackView!
    var scrollView: NSScrollView!
    var scrollFade: PassthroughView!
    // Designed empty state (v2.16.0): a centred stack — logo,
    // headline, subtext, hint rows — replacing the single grey
    // emptyLabel line. refreshList fills it in per mode and
    // restyles the hint chips for the current theme.
    var emptyStateView: NSView!
    var emptyHeadline: NSTextField!
    var emptySubtext: NSTextField!
    var emptyHints: NSStackView!
    var emptyChips: [(view: NSView, label: NSTextField)] = []
    var exclusionsWindow: NSWindow?
    var exclusionsStack: NSStackView?
    var settingsWindow: NSWindow?
    var settingsPauseCheckbox: NSButton?
    var settingsLimitPopup: NSPopUpButton?
    var settingsRetentionPopup: NSPopUpButton?
    var settingsStorageLabel: NSTextField?
    var settingsPurgeButton: NSButton?
    var settingsThemePopup: NSPopUpButton?
    var settingsIconRadios: [NSButton] = []
    var settingsRTCheckbox: NSButton?
    var settingsClickCheckbox: NSButton?

    // Card click behaviour: by default a single click
    // selects and a double-click pastes — copy plus a ⌘V
    // into the app underneath (v2.16.3, Femi's request:
    // double-click should land the clip, not leave him to
    // paste it separately). This Settings toggle makes a
    // single click paste instead, for anyone who wants the
    // panel gone in one click. Default off.
    var pasteOnSingleClick: Bool {
        UserDefaults.standard.bool(forKey: "ClipKeepPasteOnSingleClick")
    }
    var settingsUpdateStatus: NSTextField?
    var settingsExclusionsStack: NSStackView?

    // Account + sync (v2.18.0): one AuthManager serves the
    // panel's Sync view and the Settings Account tab alike.
    // The sync toggle persists as ClipKeepSyncEnabled
    // (default off). The SyncEngine beside it runs the
    // actual push/pull; it stays inert until the user is
    // signed in with the toggle on.
    let auth = AuthManager()
    let syncEngine = SyncEngine()
    var syncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "ClipKeepSyncEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "ClipKeepSyncEnabled") }
    }
    var avatarButton: HoverButton!
    var avatarDisc: PassthroughView!
    var avatarGlyph: PassthroughImageView!
    var avatarInitial: PassthroughLabel!
    var avatarDot: PassthroughView!
    var syncView: NSView!
    var syncSignedInView: NSView!
    var syncSignedOutView: NSView!
    var syncCardViews: [NSView] = []
    var syncOpen = false
    var heroRingView: NSView!
    var heroGlyphView: NSImageView!
    var heroStatusLabel: NSTextField!
    var heroDetailLabel: NSTextField!
    var heroToggle: NSSwitch!
    var heroSyncNowButton: NSButton!
    var syncIdentityLabel: NSTextField!
    var syncEmailLabel: NSTextField!
    var syncEmailField: NSTextField!
    var syncEmailButton: NSButton!
    var syncEmailErrorLabel: NSTextField!
    var syncOTPBlock: NSStackView!
    var syncOTPLabel: NSTextField!
    var syncOTPField: NSTextField!
    var syncOTPConfirmButton: NSButton!
    var syncOTPResendButton: NSButton!
    var syncOTPErrorLabel: NSTextField!
    var syncWaitingRow: NSStackView!
    var syncDeviceDot: NSView!
    var syncEscChip: NSView!
    var syncEscLabel: NSTextField!
    var settingsAccountSignedOutView: NSStackView?
    var settingsAccountSignedInView: NSStackView?
    var settingsAccountAvatarLabel: NSTextField?
    var settingsAccountNameLabel: NSTextField?
    var settingsAccountEmailLabel: NSTextField?
    var settingsSyncCheckbox: NSButton?
    var settingsSyncStatusLabel: NSTextField?
    var settingsEmailField: NSTextField?
    var settingsEmailButton: NSButton?
    var settingsEmailErrorLabel: NSTextField?
    var settingsOTPBlock: NSStackView?
    var settingsOTPLabel: NSTextField?
    var settingsOTPField: NSTextField?
    var settingsOTPConfirmButton: NSButton?
    var settingsOTPResendButton: NSButton?
    var settingsOTPErrorLabel: NSTextField?
    // The auth state the last onStateChange refresh saw —
    // the land-on-Sync rule (v2.19.3) fires only on a real
    // transition INTO signed-in, never on a refresh.
    var previousAuthState: AuthManager.State = .signedOut

    // Panel-open bookkeeping (v2.18.1): the first open after
    // a launch still needs togglePanel's second rebuild (the
    // v2.15.6 first-frame fix); later opens skip it. The
    // search debounce is the pending per-keystroke rebuild,
    // if any (delay findings F1/F2).
    var hasShownPanelOnce = false
    var searchDebounce: DispatchWorkItem?

    var timer: Timer?
    var lastChangeCount = 0
    var selfWriteChangeCount = -1
    // Pause is persisted (v2.15.5): it used to live in memory
    // only, so quitting — or the updater's swap-and-relaunch —
    // silently resumed capture. The menu-bar icon already shows
    // the state at a glance (dim + ⏸ via refreshStatusItem,
    // which runs at launch), so a remembered pause stays visible.
    var capturePaused: Bool {
        get { UserDefaults.standard.bool(forKey: "ClipKeepCapturePaused") }
        set { UserDefaults.standard.set(newValue, forKey: "ClipKeepCapturePaused") }
    }
    var hotKeyRef: EventHotKeyRef?
    var stackHotKeyRef: EventHotKeyRef?
    var stackIDs: [String] = []   // Paste Stack queue, first = next out
    var keyMonitor: Any?

    // Pill-tab order matches typeFilters. "link" is not a
    // stored kind — link clips are text clips whose text is a URL;
    // the Text tab excludes them so the two stay separate.
    let typeFilters = ["all", "text", "link", "image", "file", "color"]

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Purge the retired panel-frame keys (v2.16.0): frame
        // persistence ended in v2.9.1, but existing installs
        // still carry V3–V6 saved frames in their preferences.
        // Nothing reads them — delete on sight.
        for key in ["ClipKeepPanelFrameV3", "ClipKeepPanelFrameV4",
                    "ClipKeepPanelFrameV5", "ClipKeepPanelFrameV6"] {
            UserDefaults.standard.removeObject(forKey: key)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshStatusItem()

        buildPanel()
        // Account wiring (v2.18.0): one AuthManager, two
        // surfaces (panel Sync view + Settings Account tab).
        previousAuthState = auth.state
        auth.onStateChange = { [weak self] in
            guard let self else { return }
            let wasSignedIn: Bool
            if case .signedIn = previousAuthState { wasSignedIn = true } else { wasSignedIn = false }
            let isSignedIn: Bool
            if case .signedIn = auth.state { isSignedIn = true } else { isSignedIn = false }
            previousAuthState = auth.state
            refreshSyncView()
            refreshSettingsAccount()
            // Land on Sync (v2.19.3): a fresh interactive
            // sign-in while the panel is up opens the Sync
            // view, so the person sees the account they
            // just signed into instead of being dropped
            // back on the clips. A launch-restored session
            // never transitions (the state was already
            // signed-in when this was wired) and a token
            // refresh stays signed-in throughout, so
            // neither yanks the view.
            if !wasSignedIn, isSignedIn, panel != nil, panel.isVisible {
                setSyncView(open: true)
            }
            // A completed sign-in kicks the engine (it
            // no-ops unless sync is on).
            if !wasSignedIn, isSignedIn { syncEngine.syncNow() }
        }
        auth.onNotConfigured = { [weak self] in self?.showAccountsNotLiveAlert() }
        auth.onDeleteUnavailable = { [weak self] in self?.showDeleteUnavailableAlert() }
        syncEngine.app = self
        syncEngine.onStateChange = { [weak self] in
            self?.refreshSyncView()
            self?.refreshSettingsAccount()
        }
        refreshSyncView()
        auth.refreshIfNeeded()
        checkForUpdate()
        registerHotKeys()
        installKeyMonitor()

        // Track the app in front before ClipKeep activates
        // (v2.16.5): pasteBack hands focus back to it
        // explicitly before sending ⌘V, instead of trusting
        // that closing the panel reactivates it in time.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastExternalApp = app
        }

        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollClipboard()
            self?.checkClipboardForOTPCode()
        }
        // Fresh timestamps (v2.11.0): the cards' relative times
        // ("39 minutes ago") otherwise only change when the list
        // rebuilds for another reason. Once a minute, if the
        // panel is open and key, rebuild with the scroll position
        // preserved. The timer runs in the default run-loop mode,
        // so it cannot fire while a menu is tracking or a modal
        // is up; selection survives via selectedItemID.
        timeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.panel != nil, self.panel.isVisible, self.panel.isKeyWindow,
                  self.scrollView != nil else { return }
            let origin = self.scrollView.contentView.bounds.origin
            self.refreshList()
            self.scrollView.contentView.scroll(to: origin)
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }

        // Open the panel on launch (v2.14.0, Femi's Nov 18
        // Loom): clicking ClipKeep in the Apps grid launched it
        // into the menu bar only — from the desktop it looked
        // like nothing had happened. Launching the app now
        // shows the panel (and, on a fresh launch, the intro),
        // which is what clicking an app icon promises.
        openPanel()
    }

    // Clicking the app's icon (Apps grid, Finder, Dock) while
    // it is already running lands here: an accessory app has
    // no windows to restore, so without this the click did
    // nothing at all — the other half of Femi's Loom.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return true
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
            let newItem = ClipItem(id: UUID().uuidString, kind: "file", text: nil, imageFile: nil,
                                   createdAt: now, pinned: false, filePath: first.path,
                                   sourceApp: sourceName, sourceBundleID: sourceBundle,
                                   ocrText: nil, board: nil, contentHash: nil)
            store.insert(newItem)
            noteSyncMutation(newItem.id)
            refreshList()
            noteCapture(newItem)
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
                let newItem = ClipItem(id: id, kind: "image", text: nil, imageFile: name,
                                       createdAt: now, pinned: false, filePath: nil,
                                       sourceApp: sourceName, sourceBundleID: sourceBundle,
                                       ocrText: nil, board: nil, contentHash: hash)
                store.insert(newItem)
                noteSyncMutation(newItem.id)
                refreshList()
                noteCapture(newItem)
                recognizeText(in: png) { [weak self] text in
                    guard let self, let text,
                          let idx = self.store.items.firstIndex(where: { $0.id == id }) else { return }
                    self.store.items[idx].ocrText = text
                    // OCR arrival is a mutation like any
                    // other: stamp it, so sync's
                    // last-writer-wins ordering sees it.
                    self.store.touch(id: id)
                    self.store.save()
                    self.noteSyncMutation(id)
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
            let newItem = ClipItem(id: UUID().uuidString, kind: "color", text: hex, imageFile: nil,
                                   createdAt: now, pinned: false, filePath: nil,
                                   sourceApp: sourceName, sourceBundleID: sourceBundle,
                                   ocrText: nil, board: nil, contentHash: nil)
            store.insert(newItem)
            noteSyncMutation(newItem.id)
            refreshList()
            noteCapture(newItem)
            return
        }

        // Plain text — except a colour literal, which files as a
        // colour (the real .color payload above still wins when an
        // app provides one).
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let color = colorFromLiteral(text) {
                let hex = hexString(from: color)
                if store.items.first?.kind == "color" && store.items.first?.text == hex { return }
                let newItem = ClipItem(id: UUID().uuidString, kind: "color", text: hex, imageFile: nil,
                                       createdAt: now, pinned: false, filePath: nil,
                                       sourceApp: sourceName, sourceBundleID: sourceBundle,
                                       ocrText: nil, board: nil, contentHash: nil)
                store.insert(newItem)
                noteSyncMutation(newItem.id)
                refreshList()
                noteCapture(newItem)
                return
            }
            if store.items.first?.kind == "text" && store.items.first?.text == text { return }
            let newItem = ClipItem(id: UUID().uuidString, kind: "text", text: text,
                                   imageFile: nil, createdAt: now, pinned: false, filePath: nil,
                                   sourceApp: sourceName, sourceBundleID: sourceBundle,
                                   ocrText: nil, board: nil, contentHash: nil)
            store.insert(newItem)
            noteSyncMutation(newItem.id)
            refreshList()
            enrichLinkIfNeeded(newItem)
            noteCapture(newItem)
        }
    }

    // Every local mutation files its clip id with the sync
    // engine's outbox. The filing is unconditional (the
    // engine drains it only when signed in with sync on);
    // deletes file the id too — at drain time the store's
    // tombstone for it is what gets pushed.
    func noteSyncMutation(_ id: String) {
        syncEngine.enqueue(id)
    }

    // Style D on the capture path (v2.14.0): a clip captured
    // from another app flashes the menu bar "✓ Copied", and
    // its card as well when the panel is open. Until now the
    // flashes only fired for copies/pastes started inside
    // ClipKeep, so the v2.5.2 confirmation was invisible for
    // ordinary copies — which is why it could never be
    // confirmed on Femi's Mac. Self-writes never reach here
    // (the poller's changeCount guard returns first), and
    // deduped repeats return before inserting.
    func noteCapture(_ item: ClipItem) {
        flashMenuBar("✓ Copied")
        if panel.isVisible { flashCard(item) }
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
    // A pending close-the-panel-after-copy, so a second copy
    // (or any other card click) within the beat cancels it —
    // copying several clips in a row keeps the panel up until
    // the last one.
    var copyDismissWorkItem: DispatchWorkItem?

    func copyBack(_ item: ClipItem, dismissPanel: Bool = false) {
        writeToPasteboard(item)
        flashCard(item)
        flashMenuBar("✓ Copied")
        if dismissPanel { scheduleCopyDismiss() }
    }

    // Close the panel shortly after a "take this clip" copy
    // (v2.14.1, Femi's request — a copy is an exit, like a
    // paste). The beat (0.45s) lets the card's "✓ Copied"
    // chip register before the panel goes; pasteBack uses
    // the same trick, shorter, because a ⌘V has to land.
    // Only the take-it copy passes dismissPanel: true (the
    // right-click Copy; double-click pastes since v2.16.3).
    // Variant copies
    // (Copy Text, RGB/HSL, Markdown) and Preview copies are
    // grabs, not exits, and leave the panel up.
    func scheduleCopyDismiss() {
        copyDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
        }
        copyDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func cancelCopyDismiss() {
        copyDismissWorkItem?.cancel()
        copyDismissWorkItem = nil
    }

    // Copy plain text only (an image clip's OCR text); the panel
    // stays open, like copyBack.
    func copyText(_ text: String, item: ClipItem? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        selfWriteChangeCount = pb.changeCount
        if let item { flashCard(item) }
        flashMenuBar("✓ Copied")
    }

    // MARK: Copy/paste confirmation (styles C + D, Femi's pick Nov 17)
    //
    // C — the card itself flashes: accent outline + a "✓ Copied"
    // chip, so the feedback lands where the eyes already are.
    // D — the menu-bar item flashes "✓ Copied" / "✓ Pasted" in
    // green: the universal fallback for actions with no card on
    // screen (Preview copies, Paste Stack). The old bottom pill
    // was retired in favour of these two.

    func cardView(for item: ClipItem) -> NSView? {
        listStack?.arrangedSubviews.first { $0.identifier?.rawValue == item.id }
    }

    // Flashes the item's card if it is on screen; returns whether
    // it did, so paste can hold the panel for the flash. The chip
    // label matches the action ("✓ Copied" / "✓ Pasted") — until
    // v2.14.0 it was hardcoded "✓ Copied", so pastes flashed the
    // wrong word on the card.
    @discardableResult
    func flashCard(_ item: ClipItem, label: String = "✓ Copied") -> Bool {
        guard let card = cardView(for: item), let layer = card.layer else { return false }
        let oldBorder = layer.borderColor, oldWidth = layer.borderWidth
        layer.borderColor = currentTheme.accent.cgColor
        layer.borderWidth = 2.5
        let chip = NSTextField(labelWithString: label)
        chip.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        chip.textColor = .white
        chip.alignment = .center
        chip.drawsBackground = true
        chip.backgroundColor = currentTheme.accent
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 9
        chip.layer?.masksToBounds = true
        chip.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.topAnchor.constraint(equalTo: card.topAnchor, constant: 54),
            chip.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            chip.widthAnchor.constraint(equalToConstant: 76),
            chip.heightAnchor.constraint(equalToConstant: 18)
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            chip.removeFromSuperview()
            // refreshList rebuilds cards wholesale; only restore
            // the border if this card is still on screen.
            if card.superview != nil {
                layer.borderColor = oldBorder
                layer.borderWidth = oldWidth
            }
        }
        return true
    }

    // The menu-bar item is an SF Symbol template image
    // (v2.11.0), not the 📋 emoji it was until now — the emoji
    // rendered in colour at text metrics and never matched the
    // native menu-bar icons around it. Paused dims the icon and
    // adds ⏸; the copy/paste flash swaps the image for green
    // text temporarily and restores through here.
    func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        if let img = menuBarIconImage() {
            button.image = img
        } else if let img = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipKeep"),
           let configured = img.withSymbolConfiguration(
               NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)) {
            // Fallback only — the SF Symbol the logo replaced in v2.15.3.
            configured.isTemplate = true
            button.image = configured
        }
        button.imagePosition = .imageLeading
        button.title = capturePaused ? "⏸" : ""
        button.attributedTitle = NSAttributedString(string: button.title)
        button.alphaValue = capturePaused ? 0.45 : 1.0
    }

    // Menu-bar icon style (v2.15.3). Femi asked for the logo in
    // the menu bar; shown five treatments as mocks, he chose to
    // ship all five as options (••• menu → Menu Bar Icon, and
    // Settings → Appearance since v2.15.7) rather than pick one.
    // Default is the tight crop — the treatment
    // that stays legible at menu-bar size. The colour treatments
    // are rendered from the bundle's own app icon, so they can
    // never drift from the real logo; the glyph is drawn as a
    // template so it tints like a native menu-bar icon.
    // The five menu-bar icon treatments (v2.15.3), defined once
    // (v2.16.0): the ••• submenu and Settings → Appearance both
    // build from this list, so the two can never drift apart.
    static let menuBarIconStyles: [(title: String, id: String)] = [
        ("Logo", "logo"), ("Logo (tight crop)", "logoCrop"),
        ("Glyph (monochrome)", "glyph"), ("Logo (greyscale)", "grey"),
        ("Logo (greyscale, reversed)", "greyReversed")
    ]

    var menuBarIconStyle: String {
        UserDefaults.standard.string(forKey: "ClipKeepMenuBarIcon") ?? "logoCrop"
    }

    @objc func menuBarIconChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "ClipKeepMenuBarIcon")
        refreshStatusItem()
    }

    private var menuBarIconCache: [String: NSImage] = [:]
    func menuBarIconImage() -> NSImage? {
        let style = menuBarIconStyle
        if let cached = menuBarIconCache[style] { return cached }
        let size = NSSize(width: 18, height: 18)
        let image = style == "glyph" ? glyphMenuBarImage(size: size)
                                     : logoMenuBarImage(style: style, size: size)
        if let image { menuBarIconCache[style] = image }
        return image
    }

    private func logoMenuBarImage(style: String, size: NSSize) -> NSImage? {
        guard let appIcon = NSApp.applicationIconImage else { return nil }
        var source = appIcon
        var srcRect = NSRect(origin: .zero, size: appIcon.size)
        if style == "logoCrop" {
            // Centre 76% — the cards and pin fill the frame and
            // the icon's dark background mostly falls away (mock B).
            let inset = appIcon.size.width * 0.12
            srcRect = NSRect(x: inset, y: inset,
                             width: appIcon.size.width - 2 * inset,
                             height: appIcon.size.height - 2 * inset)
        } else if style == "grey" || style == "greyReversed" {
            guard let mono = greyscaleImage(appIcon, invert: style == "greyReversed") else { return nil }
            source = mono
            srcRect = NSRect(origin: .zero, size: mono.size)
        }
        let out = NSImage(size: size)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
        source.draw(in: rect, from: srcRect, operation: .copy, fraction: 1)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    private func greyscaleImage(_ img: NSImage, invert: Bool) -> NSImage? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var ci = CIImage(cgImage: cg).applyingFilter("CIPhotoEffectMono")
        if invert { ci = ci.applyingFilter("CIColorInvert") }
        guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: out, size: img.size)
    }

    private func glyphMenuBarImage(size: NSSize) -> NSImage {
        // The stacked-cards mark as a one-colour template: back
        // card offset up-right, front card below-left, the pin a
        // filled dot on the front card's top-left corner (mock C).
        let img = NSImage(size: size, flipped: true) { rect in
            let s = rect.width / 18
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let back = NSBezierPath(roundedRect: NSRect(x: 5.5 * s, y: 1.5 * s, width: 11.5 * s, height: 11.5 * s),
                                    xRadius: 2.6 * s, yRadius: 2.6 * s)
            back.lineWidth = 1.5 * s
            back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 1.5 * s, y: 5 * s, width: 11.5 * s, height: 11.5 * s),
                                     xRadius: 2.6 * s, yRadius: 2.6 * s)
            front.lineWidth = 1.5 * s
            front.stroke()
            NSBezierPath(ovalIn: NSRect(x: 0.6 * s, y: 4.1 * s, width: 3.4 * s, height: 3.4 * s)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    private var menuFlashGeneration = 0
    func flashMenuBar(_ text: String) {
        guard let button = statusItem?.button else { return }
        menuFlashGeneration += 1
        let gen = menuFlashGeneration
        button.image = nil
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.systemGreen,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        button.title = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.menuFlashGeneration == gen else { return }
            self.refreshStatusItem()
        }
    }

    // The last app in front that wasn't ClipKeep itself
    // (v2.16.5) — pasteBack reactivates it explicitly before
    // sending ⌘V. Tracked from launch via
    // NSWorkspace.didActivateApplicationNotification.
    var lastExternalApp: NSRunningApplication?
    // Process-lifetime: the Accessibility explanation is
    // shown at most once per launch, never nagged.
    var pastePermissionPromptShown = false

    func pasteBack(_ item: ClipItem, fromStack: Bool = false) {
        writeToPasteboard(item)
        // v2.16.5: a paste is only "✓ Pasted" when the ⌘V
        // keystroke will actually be sent. macOS gates that
        // keystroke on Accessibility trust; without it the
        // old code skipped the keystroke silently and still
        // flashed "✓ Pasted" — Femi's Nov 21 Loom showed the
        // result: panel closes, nothing lands, no clue why.
        // Untrusted now flashes "✓ Copied" honestly and
        // surfaces the permission fix (once per launch).
        let trusted = AXIsProcessTrusted()
        let label = trusted ? "✓ Pasted" : "✓ Copied"
        // Style C's accepted trade-off: when the card is on
        // screen it flashes briefly before the panel closes
        // and the paste lands. The flash was 0.42s until
        // v2.12.0 — Femi reported the wait as lag between
        // clicks, so it's 0.18s now: still visible, but the
        // paste lands in about a quarter second. The Paste
        // Stack pastes instantly (its refresh would wipe the
        // flash anyway) and relies on the menu-bar flash.
        let flashed = fromStack ? false : flashCard(item, label: label)
        DispatchQueue.main.asyncAfter(deadline: .now() + (flashed ? 0.18 : 0)) { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            if trusted {
                // Hand focus back explicitly (v2.16.5): the
                // keystroke used to ride on the panel closing
                // reactivating the app underneath inside a
                // 0.08s window; if it hadn't, the ⌘V landed
                // in ClipKeep itself and vanished.
                self.lastExternalApp?.activate(options: [])
                self.simulatePaste()
                self.flashMenuBar("✓ Pasted")
            } else {
                self.flashMenuBar("✓ Copied")
                self.promptForPastePermission()
            }
        }
    }

    // Shown once per launch when a paste couldn't send its
    // ⌘V because macOS hasn't granted Accessibility. The
    // clip is already on the clipboard, so nothing is lost —
    // ⌘V pastes it manually this time.
    func promptForPastePermission() {
        guard !pastePermissionPromptShown else { return }
        pastePermissionPromptShown = true
        let alert = NSAlert()
        alert.messageText = "ClipKeep copied it — but macOS won't let it paste"
        alert.informativeText = "Your clip is on the clipboard, so pressing ⌘V pastes it this time. For double-click paste to work on its own, ClipKeep needs Accessibility permission. If ClipKeep is already listed and switched on, switch it off and on again — an app update can leave a stale entry."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            // Register ClipKeep in the Accessibility list (and
            // let macOS show its own prompt), then open the
            // pane so the toggle is one click away.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // Paste plain text (an image clip's OCR text) the same way:
    // clipboard, panel away, ⌘V into the app underneath. Same
    // honesty rule as pasteBack (v2.16.5): no trust, no "✓
    // Pasted" claim — copy, explain, offer the settings.
    func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        selfWriteChangeCount = pb.changeCount
        panel.orderOut(nil)
        if AXIsProcessTrusted() {
            lastExternalApp?.activate(options: [])
            simulatePaste()
            flashMenuBar("✓ Pasted")
        } else {
            flashMenuBar("✓ Copied")
            promptForPastePermission()
        }
    }

    // If Accessibility is granted, press ⌘V in the app underneath
    // so the paste lands where the cursor is. Callers check trust
    // first (v2.16.5) and take the honest-copy path when it isn't
    // granted; this check stays as a final guard. The delay is
    // 0.12s (was 0.08) so the explicit reactivation in pasteBack
    // has a beat to land before the keystroke goes out.
    func simulatePaste() {
        if AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
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
                pasteBack(item, fromStack: true)
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
            if let title, !title.isEmpty {
                let cleaned = cleanLinkTitle(title)
                if !cleaned.isEmpty { self.store.items[idx].linkTitle = cleaned }
            }
            if let imageFile { self.store.items[idx].linkImageFile = imageFile }
            // The fetched title rides the wire: stamp the
            // change and file it with the sync outbox.
            self.store.touch(id: id)
            self.store.save()
            self.noteSyncMutation(id)
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

    // MARK: Update checker + one-click install (v2.6.0)

    // The ClipKeep repo is private, so the app cannot read its
    // releases anonymously. A tiny public gist carries the latest
    // version instead; it is bumped as part of each release.
    static let updateFeedURL = "https://gist.githubusercontent.com/femisowems/114759138a0c643983d577960363096a/raw/clipkeep-version.json"
    // The feed may also carry "sha256" — the release zip's
    // SHA-256, published with each release since v2.6.1. When
    // present, the installer verifies the download against it
    // before swapping the bundle (inspection risk #3, closed
    // Nov 17). Absent = older feed, install proceeds unverified.
    var availableUpdate: (version: String, url: String, sha256: String?)?

    // The update strip (built in buildPanel): pinned under the
    // search row — the notice's home since the v2.6.0 overhaul
    // (placement approved Nov 17; pieces 1 + 4 picked: one-click
    // install with progress, and Later = snooze to tomorrow).
    var updateStrip: NSView!
    var updateStripLabel: NSTextField!
    var updateInstallButton: NSButton!
    var updateLaterButton: NSButton!
    var updateDismissButton: NSButton!
    var updateProgress: NSProgressIndicator!
    var updateProgressLabel: NSTextField!
    var updateStripHeight: NSLayoutConstraint!
    var tabsTopConstraint: NSLayoutConstraint!
    // Panel spacing (v2.15.0): the search row's top gap and
    // the feed's bottom gap are stored constraints so
    // centerPanelContent() can balance them by measurement.
    var panelTopConstraint: NSLayoutConstraint!
    var panelBottomConstraint: NSLayoutConstraint!
    var stackBarTopConstraint: NSLayoutConstraint!
    var stackBarZeroHeight: NSLayoutConstraint!
    var feedClipView: NSView!
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var pendingInstallVersion: String?
    private var pendingInstallSHA256: String?
    private var updateSnoozedUntil: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "updateSnoozedUntil")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "updateSnoozedUntil") }
    }

    func checkForUpdate(manual: Bool = false) {
        guard let feed = URL(string: AppController.updateFeedURL) else { return }
        var request = URLRequest(url: feed)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  // "latest" is the canonical key; "version" is
                  // accepted too — a feed published with only the
                  // wrong key once broke checks silently (Nov 17).
                  let latest = (obj["latest"] as? String) ?? (obj["version"] as? String),
                  let url = obj["url"] as? String else { return }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let sha = obj["sha256"] as? String
            DispatchQueue.main.async {
                var flashedUpToDate = false
                if latest.compare(current, options: .numeric) == .orderedDescending {
                    self.availableUpdate = (latest, url, sha)
                } else {
                    self.availableUpdate = nil
                    if manual { self.flashUpToDateStrip(); flashedUpToDate = true }
                }
                // The flash owns the strip until its own delayed
                // refresh restores it (v2.14.0): refreshing here
                // hid "✓ You're up to date" in the same runloop
                // turn, before a single frame could render — the
                // flash was unreachable, which is why a manual
                // check never showed anything.
                if !flashedUpToDate { self.refreshUpdateStrip() }
                self.refreshSettingsUpdateStatus()
            }
        }.resume()
    }

    private enum StripMode { case hidden, available, progress, message }
    private func setStripMode(_ mode: StripMode) {
        let show = mode != .hidden
        updateStrip.isHidden = !show
        updateStripHeight.constant = show ? 34 : 0
        // The tab-row gap is 8 in both states (v2.15.0): with
        // the strip hidden, search → tabs reads 12 (the strip's
        // own top gap) + 8 = 20; shown, the strip is content
        // sitting between them.
        tabsTopConstraint.constant = 8
        updateInstallButton.isHidden = mode != .available
        updateLaterButton.isHidden = mode != .available
        updateDismissButton.isHidden = mode != .available
        updateProgress.isHidden = mode != .progress
        updateProgressLabel.isHidden = mode != .progress
        // The strip is part of the centred stack (v2.15.0):
        // showing or hiding it re-balances the panel.
        centerPanelContent()
    }

    func refreshUpdateStrip() {
        guard updateStrip != nil else { return }
        updateStrip.layer?.backgroundColor = currentTheme.accent.withAlphaComponent(0.15).cgColor
        updateStripLabel.textColor = currentTheme.accent
        if downloadTask != nil { return } // the install flow owns the strip
        let dismissed = UserDefaults.standard.string(forKey: "dismissedUpdateVersion")
        if let upd = availableUpdate, dismissed != upd.version, Date() >= updateSnoozedUntil {
            updateStripLabel.stringValue = "ClipKeep \(upd.version) is available"
            setStripMode(.available)
        } else {
            setStripMode(.hidden)
        }
    }

    // A manual check that finds nothing still answers: the strip
    // flashes "up to date" instead of the old silent no-op.
    func flashUpToDateStrip() {
        guard updateStrip != nil else { return }
        updateStrip.layer?.backgroundColor = currentTheme.accent.withAlphaComponent(0.15).cgColor
        updateStripLabel.textColor = currentTheme.accent
        updateStripLabel.stringValue = "✓ You're up to date"
        setStripMode(.message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.refreshUpdateStrip()
        }
    }

    @objc func updateInstallClicked() {
        guard downloadTask == nil,
              let upd = availableUpdate, let url = URL(string: upd.url) else { return }
        pendingInstallVersion = upd.version
        pendingInstallSHA256 = upd.sha256
        updateStripLabel.stringValue = "Downloading \(upd.version)…"
        updateProgress.isIndeterminate = false
        updateProgress.doubleValue = 0
        updateProgressLabel.stringValue = ""
        setStripMode(.progress)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadSession = session
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    @objc func updateLaterClicked() {
        updateSnoozedUntil = Date().addingTimeInterval(24 * 3600)
        refreshUpdateStrip()
    }

    @objc func updateDismissClicked() {
        if let upd = availableUpdate {
            UserDefaults.standard.set(upd.version, forKey: "dismissedUpdateVersion")
        }
        refreshUpdateStrip()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        updateProgress.doubleValue = pct * 100
        updateProgressLabel.stringValue = "\(Int(pct * 100))%"
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let version = pendingInstallVersion ?? "update"
        updateStripLabel.stringValue = "Installing \(version)…"
        updateProgress.isIndeterminate = true
        updateProgressLabel.stringValue = ""
        do {
            try installDownloadedUpdate(zipAt: location, version: version, expectedSHA256: pendingInstallSHA256)
        } catch {
            installFailed(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { installFailed(error.localizedDescription) }
        downloadTask = nil
        downloadSession = nil
    }

    private func installFailed(_ message: String) {
        downloadTask = nil
        updateProgress.isIndeterminate = false
        updateStripLabel.stringValue = "Update failed: \(message)"
        setStripMode(.message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.downloadTask == nil else { return }
            if let upd = self.availableUpdate {
                self.updateStripLabel.stringValue = "ClipKeep \(upd.version) is available"
                self.setStripMode(.available)
            } else {
                self.refreshUpdateStrip()
            }
        }
    }

    // SHA-256 of a file via the system shasum tool — the app
    // already shells out to ditto for the unzip, so this adds no
    // new linked dependency. Lowercase hex, or nil on failure.
    private func sha256(ofFile url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return nil }
        return out.split(separator: " ").first.map(String.init)?.lowercased()
    }

    // Replace the running app with the downloaded one: unzip to
    // a staging folder, then a detached script waits for this
    // process to exit, swaps the bundles (keeping a backup until
    // the new one is in place), and relaunches. When the feed
    // published a sha256 for this release, the download is
    // verified against it first and a mismatch (or a failed
    // verification) aborts the install before anything is
    // unzipped or swapped.
    private func installDownloadedUpdate(zipAt zipURL: URL, version: String, expectedSHA256: String?) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("clipkeep-update-\(version)")
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        // The download task's temp file vanishes when this
        // delegate returns, so move it into staging first.
        let stagedZip = stage.appendingPathComponent("update.zip")
        try fm.copyItem(at: zipURL, to: stagedZip)
        if let expected = expectedSHA256, !expected.isEmpty {
            guard let actual = sha256(ofFile: stagedZip), actual == expected.lowercased() else {
                throw NSError(domain: "ClipKeepUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: "checksum mismatch — the download was discarded"])
            }
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", stagedZip.path, stage.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw NSError(domain: "ClipKeepUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "couldn't unzip the download"])
        }
        let newApp = stage.appendingPathComponent("ClipKeep.app")
        guard fm.fileExists(atPath: newApp.path) else {
            throw NSError(domain: "ClipKeepUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "the download didn't contain the app"])
        }
        let current = Bundle.main.bundlePath
        let backup = current + ".bak"
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(backup)"
        mv "\(current)" "\(backup)"
        if mv "\(newApp.path)" "\(current)"; then
          rm -rf "\(backup)"
          open "\(current)"
        else
          mv "\(backup)" "\(current)"
          open "\(newApp.path)"
        fi
        """
        let scriptURL = stage.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/bash")
        run.arguments = [scriptURL.path]
        try run.run()
        NSApp.terminate(nil)
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
            window.level = .floating   // above the panel (v2.13.0) — see buildSettingsWindow
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
        copyText(ocr, item: item)
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
        store.touch(id: id)
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
        noteSyncMutation(id)
        refreshList()
        if let updated = store.items.first(where: { $0.id == id }) { enrichLinkIfNeeded(updated) }
        previewWindow?.orderOut(nil)
    }

    // MARK: Card context menu

    // MARK: Quick actions (roadmap #1, v2.8.0)
    //
    // Text transformations, reached from the card's right-click
    // Transform submenu. Each pastes the transformed text via
    // pasteText (panel closes, menu bar flashes as usual); Copy
    // as Markdown Link copies instead and stays, like Copy. The
    // submenu only offers transforms that apply: Pretty JSON
    // appears only when the text parses as JSON and printing it
    // changes it; Extract Links only when the text has a URL.
    // (The pure transforms themselves — extractURLs, prettyJSON,
    // trimmedText — are free functions in the Text helpers
    // section, so tests.swift can cover them.)

    @objc func menuTransformPlain(_ sender: NSMenuItem) { if let i = item(for: sender), let t = i.text { pasteText(t) } }
    @objc func menuTransformUpper(_ sender: NSMenuItem) { if let i = item(for: sender), let t = i.text { pasteText(t.uppercased()) } }
    @objc func menuTransformLower(_ sender: NSMenuItem) { if let i = item(for: sender), let t = i.text { pasteText(t.lowercased()) } }
    @objc func menuTransformTitle(_ sender: NSMenuItem) { if let i = item(for: sender), let t = i.text { pasteText(t.capitalized) } }
    @objc func menuTransformTrim(_ sender: NSMenuItem) { if let i = item(for: sender), let t = i.text { pasteText(trimmedText(t)) } }
    @objc func menuTransformJSON(_ sender: NSMenuItem) { if let i = item(for: sender), let t = i.text, let p = prettyJSON(t) { pasteText(p) } }
    @objc func menuTransformLinks(_ sender: NSMenuItem) { if let i = item(for: sender), let t = i.text { pasteText(extractURLs(t).joined(separator: "\n")) } }
    @objc func menuCopyMarkdown(_ sender: NSMenuItem) {
        if let i = item(for: sender), let t = i.text {
            let url = t.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if let lt = i.linkTitle, !lt.isEmpty { title = cleanLinkTitle(lt) } else { title = url }
            copyText("[\(title)](\(url))", item: i)
        }
    }

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
        if item.kind == "color" {
            add("Copy as RGB", #selector(menuCopyRGB(_:)))
            add("Copy as HSL", #selector(menuCopyHSL(_:)))
        }
        if item.kind == "text", let text = item.text, !text.isEmpty {
            let transformItem = NSMenuItem(title: "Transform", action: nil, keyEquivalent: "")
            let tsub = NSMenu()
            func tadd(_ title: String, _ action: Selector) {
                let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
                mi.target = self
                mi.identifier = NSUserInterfaceItemIdentifier(item.id)
                tsub.addItem(mi)
            }
            tadd("Paste as Plain Text", #selector(menuTransformPlain(_:)))
            tadd("Paste UPPERCASE", #selector(menuTransformUpper(_:)))
            tadd("Paste lowercase", #selector(menuTransformLower(_:)))
            tadd("Paste Title Case", #selector(menuTransformTitle(_:)))
            tadd("Paste Trimmed", #selector(menuTransformTrim(_:)))
            if prettyJSON(text) != nil { tadd("Paste Pretty JSON", #selector(menuTransformJSON(_:))) }
            if !extractURLs(text).isEmpty { tadd("Paste Extracted Links", #selector(menuTransformLinks(_:))) }
            transformItem.submenu = tsub
            menu.addItem(transformItem)
            if isLinkItem(item) {
                add("Copy as Markdown Link", #selector(menuCopyMarkdown(_:)))
            }
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
    @objc func menuCopy(_ sender: NSMenuItem) { if let i = item(for: sender) { copyBack(i, dismissPanel: true) } }
    @objc func menuCopyText(_ sender: NSMenuItem) { if let i = item(for: sender), let ocr = i.ocrText { copyText(ocr, item: i) } }
    @objc func menuCopyRGB(_ sender: NSMenuItem) { if let i = item(for: sender), let hex = i.text, let c = colorFromHex(hex) { copyText(rgbString(from: c), item: i) } }
    @objc func menuCopyHSL(_ sender: NSMenuItem) { if let i = item(for: sender), let hex = i.text, let c = colorFromHex(hex) { copyText(hslString(from: c), item: i) } }
    @objc func menuPasteText(_ sender: NSMenuItem) { if let i = item(for: sender), let ocr = i.ocrText { pasteText(ocr) } }
    @objc func menuPreview(_ sender: NSMenuItem) { if let i = item(for: sender) { openPreview(for: i) } }
    @objc func menuPin(_ sender: NSMenuItem) { if let i = item(for: sender) { togglePin(id: i.id) } }
    @objc func menuStack(_ sender: NSMenuItem) {
        if let f = item(for: sender), !stackIDs.contains(f.id) { stackIDs.append(f.id) }
        refreshList()
    }
    @objc func menuDelete(_ sender: NSMenuItem) {
        if let f = item(for: sender) { store.remove(f); store.save(); noteSyncMutation(f.id) }
        refreshList()
    }

    func togglePin(id: String) {
        guard let idx = store.items.firstIndex(where: { $0.id == id }) else { return }
        store.items[idx].pinned.toggle()
        store.touch(id: id)
        store.items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.createdAt > b.createdAt
        }
        store.save()
        noteSyncMutation(id)
        refreshList()
    }

    // MARK: Panel UI

    func buildPanel() {
        panel = BorderlessWindow(contentRect: defaultPanelFrame(),
                                 styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        panel.title = "ClipKeep"
        // Fully borderless panel (v2.10.0, Femi's pick B from the
        // mock — supersedes v2.9.2's hidden chrome on a titled
        // window). No title bar at all: the ~28pt strip is
        // reclaimed (the search row's safe-area anchor collapses
        // to the top edge), and the app rounds its own corners on
        // the content layer below, since borderless windows are
        // square by default. BorderlessWindow restores key status
        // so search focus, the key monitor and click-away
        // auto-hide behave exactly as they did when titled. The
        // panel was never movable or resizable anyway (v2.9.1's
        // fixed frame), so nothing else is lost; the name lives
        // in the ••• menu header ("ClipKeep v…") and Settings.
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)   // Paste-style light look
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        // The panel's frame is FIXED (v2.9.1, Femi's direction:
        // full screen width, always, non-negotiable). It is not
        // resizable (no .resizable in the mask), not movable, and
        // its size is pinned by applyFixedPanelFrame(), which runs
        // at the end of buildPanel and again on every show. Nothing
        // is persisted: earlier builds saved a validated frame to
        // UserDefaults, but a Stage Manager clamp (~87% width)
        // could still be saved whenever the height differed from
        // the default, and the panel then restored narrow forever
        // (Femi's Nov 17 Loom). A fixed frame has nothing to save.
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

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
        // Rounded corners (v2.10.0): a borderless window is
        // square, so the effect view's layer rounds and clips
        // everything the panel draws; the window's shadow follows
        // the clipped shape. Radius 16 since v2.11.0 — 12 read
        // slightly tight at full-screen width, and current macOS
        // panels use the larger radius. The hairline edge border
        // is set in applyTheme, where the theme (and therefore
        // the right border colour) is known.
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true

        tintView = NSView()
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor(red: 0.98, green: 0.945, blue: 0.87, alpha: 0.45).cgColor
        tintView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tintView)
        NSLayoutConstraint.activate([
            tintView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: content.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        searchField = NSSearchField()
        searchField.placeholderString = "Search history, apps, text inside images…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        // Pill tabs (v2.4.0 button overhaul): SF Symbol icon +
        // title + live count per type, accent indicator sliding
        // under the selection. Replaces the segmented control.
        pillTabs = PillTabsView(types: [
            (type: "all", title: "All", symbol: "square.grid.2x2"),
            (type: "text", title: "Text", symbol: "text.alignleft"),
            (type: "link", title: "Links", symbol: "link"),
            (type: "image", title: "Images", symbol: "photo"),
            (type: "file", title: "Files", symbol: "doc"),
            (type: "color", title: "Colours", symbol: "paintpalette")
        ])
        pillTabs.onChange = { [weak self] in self?.filterChanged() }
        // Reopen on the tab used last time (remembered across
        // relaunches); All on first run.
        let savedType = UserDefaults.standard.string(forKey: "ClipKeepTypeFilter") ?? "all"
        pillTabs.select(type: typeFilters.contains(savedType) ? savedType : "all", animate: false)
        content.addSubview(pillTabs)

        // The filter dropdowns sit borderless inside matching
        // ToolbarShells — one button system (v2.4.0).
        boardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        boardPopup.isBordered = false
        boardPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        boardPopup.target = self
        boardPopup.action = #selector(filterChanged)
        let boardShell = ToolbarShell(popup: boardPopup)
        content.addSubview(boardShell)

        appPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        appPopup.isBordered = false
        appPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        appPopup.target = self
        appPopup.action = #selector(filterChanged)
        let appShell = ToolbarShell(popup: appPopup)
        content.addSubview(appShell)

        recencyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        recencyPopup.isBordered = false
        recencyPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        for (title, days) in [("All time", 0), ("Today", -1), ("Last 7 days", 7), ("Last 30 days", 30)] {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.representedObject = days
            recencyPopup.menu?.addItem(mi)
        }
        recencyPopup.target = self
        recencyPopup.action = #selector(filterChanged)
        let recencyShell = ToolbarShell(popup: recencyPopup)
        content.addSubview(recencyShell)

        // Colours-only sort choice: recency (the default) or by
        // hue. Hidden on every other tab — refreshList toggles
        // its shell.
        sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sortPopup.isBordered = false
        sortPopup.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        for (title, value) in [("Recent first", "recency"), ("Sort by hue", "hue")] {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.representedObject = value
            sortPopup.menu?.addItem(mi)
        }
        if UserDefaults.standard.string(forKey: "ClipKeepColorSort") == "hue" {
            sortPopup.selectItem(at: 1)
        }
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)
        sortShell = ToolbarShell(popup: sortPopup)
        sortShell.isHidden = true
        content.addSubview(sortShell)
        toolbarShells = [boardShell, appShell, recencyShell, sortShell]

        // Second filter row: board / source app / recency / sort,
        // each in its toolbar shell.
        let filterBar = NSStackView(views: [boardShell, appShell, recencyShell, sortShell])
        filterBar.orientation = .horizontal
        filterBar.spacing = 8
        filterBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
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

        // Right-edge scroll fade (v2.11.0): a gradient overlay on
        // the feed's right edge, shown only while more cards sit
        // off-screen that way. PassthroughView — it never takes
        // clicks meant for the cards or the scroller beneath it.
        scrollFade = PassthroughView()
        scrollFade.wantsLayer = true
        let fadeGradient = CAGradientLayer()
        fadeGradient.startPoint = NSPoint(x: 0, y: 0.5)
        fadeGradient.endPoint = NSPoint(x: 1, y: 0.5)
        scrollFade.layer = fadeGradient
        scrollFade.translatesAutoresizingMaskIntoConstraints = false
        scrollFade.isHidden = true
        content.addSubview(scrollFade)
        NSLayoutConstraint.activate([
            scrollFade.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            scrollFade.topAnchor.constraint(equalTo: scrollView.topAnchor),
            scrollFade.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            scrollFade.widthAnchor.constraint(equalToConstant: 56)
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollPositionChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        // Flipped to match the document view — see FlippedStackView.
        listStack = FlippedStackView()
        listStack.orientation = .horizontal
        listStack.alignment = .top
        listStack.spacing = Self.spaceCardGap
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = FlippedView()
        feedClipView = clipView
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
            listStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: Self.spaceFeedInset),
            listStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -Self.spaceFeedInset),
            listStack.topAnchor.constraint(equalTo: clipView.topAnchor, constant: Self.spaceFeedInset),
            // Equality, not ≤: the document view's height must be
            // driven by the stack's content height. With ≤ the
            // solver was free to collapse the document view to zero
            // height, and every row was clipped away — the panel
            // looked empty while the history on disk was full.
            listStack.bottomAnchor.constraint(equalTo: clipView.bottomAnchor, constant: -Self.spaceFeedInset),
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

        // Designed empty state (v2.16.0, design C — Femi's pick
        // from the Nov 18 mocks): the app logo, the headline
        // "Your clipboard, remembered", and three getting-
        // started hint rows with keycap chips. refreshList
        // switches the content by mode — a tab/search view with
        // no matches swaps the headline and drops the hints.
        // Replaces the single grey label that stood here before.
        let emptyIcon = NSImageView()
        emptyIcon.image = NSApp.applicationIconImage
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyIcon.widthAnchor.constraint(equalToConstant: 60).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 60).isActive = true

        emptyHeadline = NSTextField(labelWithString: "Your clipboard, remembered")
        emptyHeadline.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        emptyHeadline.textColor = .labelColor
        emptyHeadline.alignment = .center

        emptySubtext = NSTextField(labelWithString: "")
        emptySubtext.font = NSFont.systemFont(ofSize: 12.5)
        emptySubtext.textColor = .secondaryLabelColor
        emptySubtext.alignment = .center
        emptySubtext.maximumNumberOfLines = 3

        // One hint row: a fixed-width keycap chip + one line.
        func hintRow(_ chip: String, _ text: String) -> NSStackView {
            let chipLabel = NSTextField(labelWithString: chip)
            chipLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            chipLabel.alignment = .center
            chipLabel.translatesAutoresizingMaskIntoConstraints = false
            let chipView = NSView()
            chipView.wantsLayer = true
            chipView.layer?.cornerRadius = 6
            chipView.translatesAutoresizingMaskIntoConstraints = false
            chipView.widthAnchor.constraint(equalToConstant: 64).isActive = true
            chipView.heightAnchor.constraint(equalToConstant: 24).isActive = true
            chipView.addSubview(chipLabel)
            chipLabel.centerXAnchor.constraint(equalTo: chipView.centerXAnchor).isActive = true
            chipLabel.centerYAnchor.constraint(equalTo: chipView.centerYAnchor).isActive = true
            emptyChips.append((view: chipView, label: chipLabel))
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 12.5)
            label.textColor = .secondaryLabelColor
            let row = NSStackView(views: [chipView, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            return row
        }
        emptyHints = NSStackView(views: [
            hintRow("copy", "Anything you copy is kept here automatically"),
            hintRow("⌘⇧V", "Open ClipKeep from anywhere"),
            hintRow("⌘1–9", "Paste a recent clip straight back")
        ])
        emptyHints.orientation = .vertical
        emptyHints.alignment = .leading
        emptyHints.spacing = 10

        let emptyStack = NSStackView(views: [emptyIcon, emptyHeadline, emptySubtext, emptyHints])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 12
        emptyStack.setCustomSpacing(16, after: emptyIcon)
        emptyStack.setCustomSpacing(18, after: emptyHeadline)
        emptyStateView = emptyStack
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyStateView)

        // Paste-style overflow menu: everything that used to live
        // in a footer button row (pause, history limit, excluded
        // apps, clear, quit — plus the version) sits behind one
        // "•••" button beside the search field, leaving the panel
        // to the cards.
        overflowButton = HoverButton(frame: .zero)
        overflowButton.title = ""
        if let img = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More actions") {
            overflowButton.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        }
        overflowButton.imagePosition = .imageOnly
        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu(_:))
        overflowButton.normalBG = NSColor(white: 1, alpha: 0.55)
        overflowButton.hoverBG = NSColor(white: 1, alpha: 0.85)
        overflowButton.pressedBG = NSColor(white: 0, alpha: 0.10)
        overflowButton.chromeCornerRadius = 16
        overflowButton.chromeBorderColor = NSColor(white: 0, alpha: 0.10)
        overflowButton.toolTip = "More actions"
        overflowButton.setAccessibilityLabel("More actions")
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overflowButton)

        // Account avatar (v2.18.0): the Sync view's tab, at
        // the right end of the search row, before the •••
        // button. Signed in it carries the account's initial
        // on brand orange; signed out, a greyed person glyph.
        // A status dot rides its corner (green = signed in and
        // sync on, grey = signed out or sync off, amber = auth
        // error) and a blue ring marks it while the Sync view
        // is open. refreshAvatarButton owns the states.
        avatarButton = HoverButton(frame: .zero)
        avatarButton.title = ""
        avatarButton.target = self
        avatarButton.action = #selector(avatarClicked)
        avatarButton.chromeCornerRadius = 16
        avatarButton.baseTint = .white
        // Fire on mouse-down (v2.18.1): the toggle is a tab
        // switch, and waiting for mouse-up read as lag (delay
        // finding F3). HoverButton's press chrome still runs;
        // only the action's timing moves.
        _ = avatarButton.sendAction(on: .leftMouseDown)
        avatarButton.toolTip = "Account & Sync"
        avatarButton.setAccessibilityLabel("Account and sync")
        avatarButton.translatesAutoresizingMaskIntoConstraints = false
        // The face lives on its own disc (v2.19.2): the
        // button's layer painted the signed-in initial as a
        // true circle but the signed-out wash as a wider
        // rounded rect — same button, two shapes (Femi's
        // screenshots, Nov 25). The disc is a separate view
        // pinned to a fixed 32×32 centre, so both states get
        // literally the same circle; the button keeps the
        // click, the open-state ring and the hover hook, with
        // its own background clear.
        avatarButton.normalBG = .clear
        avatarButton.hoverBG = .clear
        avatarButton.pressedBG = .clear
        avatarButton.onChromeRefresh = { [weak self] in self?.paintAvatarFace() }
        content.addSubview(avatarButton)

        avatarDisc = PassthroughView()
        avatarDisc.wantsLayer = true
        avatarDisc.layer?.cornerRadius = 16
        avatarDisc.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addSubview(avatarDisc)

        avatarGlyph = PassthroughImageView()
        avatarGlyph.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: "Account")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        avatarGlyph.contentTintColor = .white
        avatarGlyph.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addSubview(avatarGlyph)

        avatarInitial = PassthroughLabel(labelWithString: "")
        avatarInitial.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        avatarInitial.textColor = .white
        avatarInitial.alignment = .center
        avatarInitial.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addSubview(avatarInitial)

        NSLayoutConstraint.activate([
            avatarDisc.centerXAnchor.constraint(equalTo: avatarButton.centerXAnchor),
            avatarDisc.centerYAnchor.constraint(equalTo: avatarButton.centerYAnchor),
            avatarDisc.widthAnchor.constraint(equalToConstant: 32),
            avatarDisc.heightAnchor.constraint(equalToConstant: 32),
            avatarGlyph.centerXAnchor.constraint(equalTo: avatarButton.centerXAnchor),
            avatarGlyph.centerYAnchor.constraint(equalTo: avatarButton.centerYAnchor),
            avatarInitial.centerXAnchor.constraint(equalTo: avatarButton.centerXAnchor),
            avatarInitial.centerYAnchor.constraint(equalTo: avatarButton.centerYAnchor)
        ])

        // The dot is a 10pt badge centred on the button's
        // corner arc (v2.18.1): at 10pt with its edge flush to
        // the button's corner, its centre sits ~5pt in — the
        // arc of the 32pt circle passes ~4.7pt in — so the
        // badge straddles the curve instead of denting it
        // (the "skewered" screenshot). Its ring colour is set
        // in refreshAvatarButton, keyed to the backdrop.
        avatarDot = PassthroughView()
        avatarDot.wantsLayer = true
        avatarDot.layer?.cornerRadius = 5
        avatarDot.layer?.borderWidth = 2
        avatarDot.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addSubview(avatarDot)
        NSLayoutConstraint.activate([
            avatarDot.trailingAnchor.constraint(equalTo: avatarButton.trailingAnchor),
            avatarDot.bottomAnchor.constraint(equalTo: avatarButton.bottomAnchor),
            avatarDot.widthAnchor.constraint(equalToConstant: 10),
            avatarDot.heightAnchor.constraint(equalToConstant: 10)
        ])

        // Update strip (v2.6.0): pinned under the search row.
        // Hidden (height 0) unless an update is available, an
        // install is running, or a transient message shows.
        updateStrip = NSView()
        updateStrip.wantsLayer = true
        updateStrip.layer?.cornerRadius = 9
        updateStrip.translatesAutoresizingMaskIntoConstraints = false
        updateStrip.isHidden = true
        content.addSubview(updateStrip)

        updateStripLabel = NSTextField(labelWithString: "")
        updateStripLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        updateStripLabel.translatesAutoresizingMaskIntoConstraints = false
        updateStrip.addSubview(updateStripLabel)

        updateInstallButton = NSButton(title: "Install", target: self, action: #selector(updateInstallClicked))
        updateInstallButton.bezelStyle = .rounded
        updateInstallButton.controlSize = .small
        updateInstallButton.translatesAutoresizingMaskIntoConstraints = false
        updateStrip.addSubview(updateInstallButton)

        updateLaterButton = NSButton(title: "Later", target: self, action: #selector(updateLaterClicked))
        updateLaterButton.bezelStyle = .inline
        updateLaterButton.isBordered = false
        updateLaterButton.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        updateLaterButton.translatesAutoresizingMaskIntoConstraints = false
        updateStrip.addSubview(updateLaterButton)

        updateDismissButton = NSButton(title: "✕", target: self, action: #selector(updateDismissClicked))
        updateDismissButton.bezelStyle = .inline
        updateDismissButton.isBordered = false
        updateDismissButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        updateDismissButton.toolTip = "Dismiss"
        updateDismissButton.setAccessibilityLabel("Dismiss")
        updateDismissButton.translatesAutoresizingMaskIntoConstraints = false
        updateStrip.addSubview(updateDismissButton)

        updateProgress = NSProgressIndicator()
        updateProgress.style = .bar
        updateProgress.isIndeterminate = false
        updateProgress.minValue = 0
        updateProgress.maxValue = 100
        updateProgress.translatesAutoresizingMaskIntoConstraints = false
        updateProgress.isHidden = true
        updateStrip.addSubview(updateProgress)

        updateProgressLabel = NSTextField(labelWithString: "")
        updateProgressLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        updateProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        updateProgressLabel.isHidden = true
        updateStrip.addSubview(updateProgressLabel)

        NSLayoutConstraint.activate([
            // Borderless since v2.10.0, so the safe area starts at
            // the panel's top edge; the search row's top gap is
            // the stored panelTopConstraint (created below), not
            // part of this array. (On the old titled
            // full-size-content window this anchor kept the field
            // out from under the title bar.)
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.spaceMargin),
            searchField.trailingAnchor.constraint(equalTo: avatarButton.leadingAnchor, constant: -8),

            avatarButton.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -8),
            avatarButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            avatarButton.widthAnchor.constraint(equalToConstant: 32),
            avatarButton.heightAnchor.constraint(equalToConstant: 32),

            overflowButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.spaceMargin),
            overflowButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            overflowButton.widthAnchor.constraint(equalToConstant: 32),
            overflowButton.heightAnchor.constraint(equalToConstant: 32),

            // The tab row and the filter row are centered as
            // groups (Femi's Nov 17 Loom: left-aligned, they sat
            // in the panel's left third with empty space to the
            // right). The leading floor keeps a narrow panel from
            // pushing them off the left edge.
            updateStrip.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            updateStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.spaceMargin),
            updateStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.spaceMargin),
            updateStripLabel.leadingAnchor.constraint(equalTo: updateStrip.leadingAnchor, constant: 12),
            updateStripLabel.centerYAnchor.constraint(equalTo: updateStrip.centerYAnchor),
            updateStripLabel.trailingAnchor.constraint(lessThanOrEqualTo: updateInstallButton.leadingAnchor, constant: -8),
            updateInstallButton.trailingAnchor.constraint(equalTo: updateLaterButton.leadingAnchor, constant: -6),
            updateInstallButton.centerYAnchor.constraint(equalTo: updateStrip.centerYAnchor),
            updateLaterButton.trailingAnchor.constraint(equalTo: updateDismissButton.leadingAnchor, constant: -4),
            updateLaterButton.centerYAnchor.constraint(equalTo: updateStrip.centerYAnchor),
            updateDismissButton.trailingAnchor.constraint(equalTo: updateStrip.trailingAnchor, constant: -8),
            updateDismissButton.centerYAnchor.constraint(equalTo: updateStrip.centerYAnchor),
            updateProgress.leadingAnchor.constraint(equalTo: updateStripLabel.trailingAnchor, constant: 10),
            updateProgress.centerYAnchor.constraint(equalTo: updateStrip.centerYAnchor),
            updateProgress.widthAnchor.constraint(equalToConstant: 130),
            updateProgressLabel.leadingAnchor.constraint(equalTo: updateProgress.trailingAnchor, constant: 8),
            updateProgressLabel.centerYAnchor.constraint(equalTo: updateStrip.centerYAnchor),
            pillTabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            pillTabs.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Self.spaceMargin),
            pillTabs.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Self.spaceMargin),

            filterBar.topAnchor.constraint(equalTo: pillTabs.bottomAnchor, constant: Self.spaceRowGap),
            filterBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            filterBar.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Self.spaceMargin),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Self.spaceMargin),

            stackBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.spaceMargin),
            stackBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Self.spaceMargin),

            scrollView.topAnchor.constraint(equalTo: stackBar.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.spaceMargin - Self.spaceFeedInset),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -(Self.spaceMargin - Self.spaceFeedInset)),
            // Floors so the content's fitting size can never collapse
            // the window: in 2.0.x the old rows' fitting width was
            // ~60pt and AppKit's constraint-based window sizing shrank
            // the panel to a strip on the first layout pass.
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -48)
        ])

        // Stored so the strip can open/close by changing two
        // constants: strip height 0/34, tab-row gap 8 (v2.15.0).
        updateStripHeight = updateStrip.heightAnchor.constraint(equalToConstant: 0)
        updateStripHeight.isActive = true
        tabsTopConstraint = pillTabs.topAnchor.constraint(equalTo: updateStrip.bottomAnchor, constant: 8)
        tabsTopConstraint.isActive = true

        // Stored for the vertical balancing (v2.15.0): the
        // search row's top gap and the feed's bottom gap start
        // at the margin and are then centred by measurement —
        // see centerPanelContent().
        panelTopConstraint = searchField.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: Self.spaceMargin)
        panelTopConstraint.isActive = true
        panelBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.spaceMargin)
        panelBottomConstraint.isActive = true

        // Stored for the Paste Stack collapse (v2.15.4): with an
        // empty stack the bar takes no height and no top gap, so
        // the feed starts 24pt below the filter row instead of
        // reserving ~44pt for a bar that isn't visible. The stack
        // starts empty, hence the collapsed initial state;
        // refreshList keeps both in sync with stackIDs.
        stackBarTopConstraint = stackBar.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 0)
        stackBarTopConstraint.isActive = true
        stackBarZeroHeight = stackBar.heightAnchor.constraint(equalToConstant: 0)
        stackBarZeroHeight.isActive = true

        // The Sync view (v2.18.0) is built last so it layers
        // above the feed it swaps with; it starts hidden.
        buildSyncView(in: content)

        // Apply the saved theme (Warm Tint on first run); this
        // also does the first refreshList with themed cards.
        let savedThemeID = UserDefaults.standard.string(forKey: "ClipKeepTheme") ?? "warm"
        applyTheme(panelThemes.first { $0.id == savedThemeID } ?? panelThemes[0], persist: false)
        applyFixedPanelFrame()
    }

    // MARK: Panel frame — fixed full-width strip (v2.9.1)

    // MARK: Panel spacing (v2.15.0 — "Roomy", Femi's pick C)

    // One home for the panel's spacing, so the feed, the
    // update strip and the empty state share one geometry and
    // a future tweak is a one-line edit. Picked from the
    // spacing mocks (Nov 18): margins 24, card gap 20, card
    // padding 16, looser rows — plus his balance rule, the gap
    // above the search row about equalling the gap below the
    // cards, which centerPanelContent() enforces by
    // measurement on top of these base values.
    static let spaceMargin: CGFloat = 24
    static let spaceCardGap: CGFloat = 20
    static let spaceCardPad: CGFloat = 16
    static let spaceRowGap: CGFloat = 16
    static let spaceFeedInset: CGFloat = 12

    // Balance the panel's vertical spacing (v2.15.0): measure
    // the gap above the search row and the gap below the
    // cards (the feed's visual bottom — the document's height
    // or the viewport's, whichever ends first), then shift
    // both stored constraints so the two gaps meet in the
    // middle. The target is clamped: with one short clip the
    // honest centre would float the search row mid-panel,
    // which reads as broken, not balanced. Called after every
    // list rebuild and strip change; converges in one pass
    // because the content span doesn't change when both
    // constraints move by the same delta.
    func centerPanelContent() {
        guard panel != nil, feedClipView != nil, searchField != nil,
              !listStack.arrangedSubviews.isEmpty,
              let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.bounds.height
        guard height > 0 else { return }
        // Frames are in the content's (y-up) coordinates: the
        // search field's top edge is its maxY; the cards end at
        // the higher of the viewport's bottom and the point
        // the document's height reaches down from its top.
        let topGap = height - searchField.frame.maxY
        let cardsBottom = max(scrollView.frame.minY,
                              scrollView.frame.maxY - feedClipView.frame.height)
        let bottomGap = cardsBottom - content.bounds.minY
        var target = (topGap + bottomGap) / 2
        target = min(max(target, 18), 56)
        let delta = target - topGap
        guard abs(delta) >= 1 else { return }
        panelTopConstraint.constant += delta
        panelBottomConstraint.constant -= delta
    }

    // The default strip height. One constant, three jobs: the
    // panel's initial size, the no-screen fallback, and the one
    // fixed frame applyFixedPanelFrame() enforces. Before this
    // constant (Nov 17 sizing audit) the literal 520 was
    // hard-coded in four places that had to be changed together.
    private let defaultPanelHeight: CGFloat = 520

    // The one and only panel frame: full physical width,
    // defaultPanelHeight tall, sitting on the bottom of the main
    // screen's visible frame (above the Dock). Width and x come
    // from the screen's frame (edge to edge); only the bottom
    // anchor uses the visible frame, so the panel clears the Dock
    // but ignores side reservations like Stage Manager's strip —
    // V5 took the width from the visible frame and opened at ~87%
    // with the whole gap on the left.
    private func defaultPanelFrame() -> NSRect {
        if let screen = NSScreen.main {
            let f = screen.frame, vf = screen.visibleFrame
            var y = vf.minY
            // An auto-hidden Dock is NOT excluded from the visible
            // frame, so a bottom-anchored panel sits flush with
            // the screen's bottom edge and the Dock slides in over
            // its bottom strip — since v2.15.3 let a card fill the
            // feed, the tallest card's footer ended up a couple of
            // points from the Dock icons (v2.15.4). When the Dock
            // lives on the bottom edge and auto-hides, lift the
            // panel by the Dock's shown height plus a small air
            // gap. A permanently visible Dock is already excluded
            // from vf, and a side Dock needs no lift, so both keep
            // the plain anchor.
            let dock = UserDefaults(suiteName: "com.apple.dock")
            if (dock?.string(forKey: "orientation") ?? "bottom") == "bottom",
               dock?.bool(forKey: "autohide") ?? false {
                let rawTile = dock?.double(forKey: "tilesize") ?? 0
                let tile: CGFloat = rawTile > 0 ? CGFloat(rawTile) : 48
                // Shown height is roughly the tile plus ~26pt of
                // background padding and edge gap; add 8pt of air.
                y = max(y, f.minY + tile + 34)
            }
            return NSRect(x: f.minX, y: y, width: f.width, height: defaultPanelHeight)
        }
        return NSRect(x: 0, y: 0, width: 1100, height: defaultPanelHeight)
    }

    // Enforce the fixed frame: pin min/max size to it and set it.
    // Runs at the end of buildPanel, on every show (togglePanel),
    // on display changes, and from Reset Panel Size. Correction
    // deliberately never happens synchronously inside
    // windowDidResize: a setFrame there triggers a layout pass
    // that can resize the window again, and that resize ->
    // setFrame -> layout loop is what made AppKit abort on
    // launch in v2.1.0.
    private func applyFixedPanelFrame() {
        let f = defaultPanelFrame()
        panel.minSize = f.size
        panel.maxSize = f.size
        if panel.frame != f { panel.setFrame(f, display: true) }
        if NSScreen.main == nil { panel.center() }
    }

    @objc private func screenParametersChanged() {
        // A different display has a different full width.
        if panel.isVisible { applyFixedPanelFrame() }
    }

    func windowDidResize(_ notification: Notification) {
        // Deliberately a no-op for the panel (see
        // applyFixedPanelFrame for why no setFrame happens here).
        // The fixed frame is re-applied in togglePanel before
        // every show, so a clamp the window server applies while
        // the panel is open cannot survive the next open.
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
        if let key = NSApp.keyWindow, (key === previewWindow || key === exclusionsWindow || key === settingsWindow) { return }
        panel.orderOut(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        // Debounced (v2.18.1): refreshList is a full feed
        // rebuild, so typing rebuilt every card per
        // keystroke (delay finding F2). A burst of edits now
        // settles into one rebuild a beat after the last
        // keystroke; the rebuild reads the field's text when
        // it runs, so no keystroke is lost.
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshList() }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc func filterChanged() {
        // Remember the type tab across relaunches. The board/app
        // popups share this action; re-writing the current tab
        // when they change is harmless.
        UserDefaults.standard.set(pillTabs?.selectedType ?? "all",
                                  forKey: "ClipKeepTypeFilter")
        refreshList()
    }

    @objc func sortChanged() {
        UserDefaults.standard.set(sortPopup.selectedItem?.representedObject as? String ?? "recency",
                                  forKey: "ClipKeepColorSort")
        refreshList()
    }

    @objc func limitChosen(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Int {
            store.historyLimit = value
        }
        refreshList()
    }

    @objc func retentionChosen(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Int {
            store.retentionDays = value
        }
        refreshList()
    }

    // MARK: Themes

    // Repaint the whole panel in a theme: appearance (the dark
    // themes flip the panel to dark aqua so labels, fields, and
    // menus follow), the vibrancy tint, the pill tabs, the
    // toolbar shells, the overflow button, and — via a list
    // refresh — every card.
    func applyTheme(_ theme: PanelTheme, persist: Bool = true) {
        currentTheme = theme
        if persist {
            UserDefaults.standard.set(theme.id, forKey: "ClipKeepTheme")
        }
        panel?.appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
        // Panel edge (v2.11.0): a hairline border on the content
        // layer, keyed to the theme — white at low alpha on dark
        // themes, black on light ones. A borderless frosted panel
        // otherwise has no defined edge of its own: against a
        // busy or low-contrast wallpaper (Femi's Nov 18
        // screenshot) the outline, the bottom edge especially,
        // all but disappears into the desktop. Native popovers
        // draw the same hairline for the same reason.
        if let layer = panel?.contentView?.layer {
            layer.borderWidth = 1
            layer.borderColor = (theme.dark
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.black.withAlphaComponent(0.12)).cgColor
        }
        // Reduce Transparency (••• menu) makes the theme tint
        // fully opaque, so the desktop stops showing through the
        // frosted panel.
        let solid = UserDefaults.standard.bool(forKey: "ClipKeepReduceTransparency")
        tintView?.layer?.backgroundColor = (solid ? theme.tint.withAlphaComponent(1)
                                                  : theme.tint).cgColor
        pillTabs?.applyTheme(theme)
        for shell in toolbarShells { shell.applyTheme(theme) }
        overflowButton?.normalBG = theme.fieldBG
        overflowButton?.hoverBG = theme.fieldHoverBG
        overflowButton?.pressedBG = theme.pressedWash
        overflowButton?.chromeBorderColor = theme.fieldBorder
        // Sync view cards + avatar (v2.18.0) follow the theme
        // like everything else in the panel.
        for card in syncCardViews {
            card.layer?.backgroundColor = theme.cardBG.cgColor
            card.layer?.borderColor = theme.cardBorder.cgColor
        }
        refreshAvatarButton()
        refreshSyncView()
        refreshUpdateStrip()
        refreshList()
    }

    @objc func themeChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let theme = panelThemes.first(where: { $0.id == id }) else { return }
        applyTheme(theme)
    }

    @objc func toggleReduceTransparency() {
        let key = "ClipKeepReduceTransparency"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        applyTheme(currentTheme, persist: false)
    }

    // MARK: Sync view (v2.18.0 — Hero Dashboard)

    // One card in the feed's language: themed surface, 14pt
    // radius, hairline border. Registered in syncCardViews
    // so applyTheme can restyle the set on a theme change.
    private func syncCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = currentTheme.cardBG.cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = currentTheme.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        syncCardViews.append(card)
        return card
    }

    private func syncCardTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func syncBodyLabel(_ text: String, size: CGFloat = 12.5,
                               weight: NSFont.Weight = .regular,
                               color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    private func syncWrappingLabel(_ text: String, size: CGFloat = 11.5, maxWidth: CGFloat = 360) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: size)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = maxWidth
        return label
    }

    // The Google sign-in button from the mocks, shared by
    // the panel card and the Settings tab. Text-only in
    // this skeleton: the provider glyph is brand artwork
    // the single-file build doesn't carry yet.
    private func socialButton(title: String, background: NSColor, foreground: NSColor,
                              bordered: Bool, action: Selector) -> NSButton {
        let button = HoverButton(frame: .zero)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: foreground
        ])
        // Hover/pressed washes (v2.18.1): HoverButton paints
        // its layer from these, so the primary sign-in
        // controls answer the pointer instead of feeling dead
        // for a beat while the sheet or alert gathers itself.
        // The washes shift the rest colour toward the
        // foreground — that darkens the white Google
        // button. Identical at rest.
        button.normalBG = background
        button.hoverBG = background.blended(withFraction: 0.08, of: foreground) ?? background
        button.pressedBG = background.blended(withFraction: 0.16, of: foreground) ?? background
        button.chromeCornerRadius = 8
        if bordered {
            button.chromeBorderColor = NSColor(white: 0, alpha: 0.14)
        }
        button.target = self
        button.action = action
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    func accountDisplayName(_ identity: AuthIdentity?) -> String {
        guard let identity else { return "Not signed in" }
        return identity.name.isEmpty ? "ClipKeep account" : identity.name
    }

    func accountInitial(for identity: AuthIdentity) -> String {
        let source = identity.name.isEmpty ? identity.email : identity.name
        return source.first.map { String($0).uppercased() } ?? "?"
    }

    func buildSyncView(in content: NSView) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        content.addSubview(container)
        syncView = container

        // Mode row: the ‹ Clips back link, the SYNC eyebrow,
        // and the esc keycap — the way back is never a guess.
        let back = NSButton(title: "‹ Clips", target: self, action: #selector(closeSyncViewClicked))
        back.bezelStyle = .inline
        back.isBordered = false
        back.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        back.contentTintColor = NSColor(red: 0, green: 0.478, blue: 1, alpha: 1)
        let eyebrow = NSTextField(labelWithString: "SYNC")
        eyebrow.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        eyebrow.textColor = .secondaryLabelColor
        // The esc keycap wears the empty state's hint-chip
        // styling (v2.18.1): same 6pt radius, 24pt height and
        // 11.5pt label; its colours are painted in
        // refreshSyncView, where the theme is at hand, the
        // way refreshList restyles the hint chips.
        let escLabel = NSTextField(labelWithString: "esc")
        escLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        escLabel.alignment = .center
        escLabel.translatesAutoresizingMaskIntoConstraints = false
        syncEscLabel = escLabel
        let escChip = NSView()
        escChip.wantsLayer = true
        escChip.layer?.cornerRadius = 6
        escChip.layer?.borderWidth = 1
        escChip.translatesAutoresizingMaskIntoConstraints = false
        escChip.addSubview(escLabel)
        syncEscChip = escChip
        NSLayoutConstraint.activate([
            escLabel.centerXAnchor.constraint(equalTo: escChip.centerXAnchor),
            escLabel.centerYAnchor.constraint(equalTo: escChip.centerYAnchor),
            escChip.widthAnchor.constraint(equalToConstant: 32),
            escChip.heightAnchor.constraint(equalToConstant: 24)
        ])
        let spacerA = NSView()
        let spacerB = NSView()
        spacerA.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerB.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let modeRow = NSStackView(views: [back, spacerA, eyebrow, spacerB, escChip])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.distribution = .fill
        modeRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modeRow)
        spacerA.widthAnchor.constraint(equalTo: spacerB.widthAnchor).isActive = true

        // Signed-in body: the hero card over three cards.
        let signedIn = NSView()
        signedIn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(signedIn)
        syncSignedInView = signedIn

        let hero = syncCard()
        signedIn.addSubview(hero)
        heroRingView = NSView()
        heroRingView.wantsLayer = true
        heroRingView.layer?.cornerRadius = 22
        heroRingView.layer?.borderWidth = 2
        heroRingView.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(heroRingView)
        heroGlyphView = NSImageView()
        heroGlyphView.translatesAutoresizingMaskIntoConstraints = false
        heroRingView.addSubview(heroGlyphView)
        heroStatusLabel = NSTextField(labelWithString: "")
        heroStatusLabel.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        heroDetailLabel = NSTextField(labelWithString: "")
        heroDetailLabel.font = NSFont.systemFont(ofSize: 12)
        heroDetailLabel.textColor = .secondaryLabelColor
        let heroText = NSStackView(views: [heroStatusLabel, heroDetailLabel])
        heroText.orientation = .vertical
        heroText.alignment = .leading
        heroText.spacing = 2
        heroText.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(heroText)
        heroToggle = NSSwitch()
        heroToggle.target = self
        heroToggle.action = #selector(syncToggleChanged(_:))
        heroToggle.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(heroToggle)
        heroSyncNowButton = NSButton(title: "Sync Now", target: self, action: #selector(syncNowClicked))
        heroSyncNowButton.bezelStyle = .rounded
        // The button is disabled until the engine exists;
        // the reason gets a tooltip (v2.18.1), not just a
        // code comment.
        heroSyncNowButton.toolTip = "Sync launches with ClipKeep Cloud"
        heroSyncNowButton.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(heroSyncNowButton)
        NSLayoutConstraint.activate([
            heroRingView.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: Self.spaceCardPad),
            heroRingView.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            heroRingView.widthAnchor.constraint(equalToConstant: 44),
            heroRingView.heightAnchor.constraint(equalToConstant: 44),
            heroGlyphView.centerXAnchor.constraint(equalTo: heroRingView.centerXAnchor),
            heroGlyphView.centerYAnchor.constraint(equalTo: heroRingView.centerYAnchor),
            heroGlyphView.widthAnchor.constraint(equalToConstant: 20),
            heroGlyphView.heightAnchor.constraint(equalToConstant: 20),
            heroText.leadingAnchor.constraint(equalTo: heroRingView.trailingAnchor, constant: 12),
            heroText.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            heroText.trailingAnchor.constraint(lessThanOrEqualTo: heroToggle.leadingAnchor, constant: -16),
            heroSyncNowButton.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -Self.spaceCardPad),
            heroSyncNowButton.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            heroToggle.trailingAnchor.constraint(equalTo: heroSyncNowButton.leadingAnchor, constant: -10),
            heroToggle.centerYAnchor.constraint(equalTo: hero.centerYAnchor)
        ])

        // Account card: identity, the Connect rows (explicit
        // linking while signed in — RESEARCH-NOTES §3), and
        // the account actions.
        let accountCard = syncCard()
        let accountStack = NSStackView()
        accountStack.orientation = .vertical
        accountStack.alignment = .leading
        accountStack.spacing = 7
        accountStack.translatesAutoresizingMaskIntoConstraints = false
        accountCard.addSubview(accountStack)
        accountStack.addArrangedSubview(syncCardTitle("ACCOUNT"))
        syncIdentityLabel = syncBodyLabel("", size: 13.5, weight: .semibold)
        accountStack.addArrangedSubview(syncIdentityLabel)
        syncEmailLabel = syncBodyLabel("", size: 11.5, color: .secondaryLabelColor)
        accountStack.addArrangedSubview(syncEmailLabel)
        let connectGoogle = NSButton(title: "Connect Google", target: self, action: #selector(signInGoogleClicked(_:)))
        connectGoogle.bezelStyle = .rounded
        connectGoogle.controlSize = .small
        accountStack.addArrangedSubview(connectGoogle)
        let signOut = NSButton(title: "Sign Out", target: self, action: #selector(signOutClicked))
        signOut.bezelStyle = .rounded
        signOut.controlSize = .small
        accountStack.addArrangedSubview(signOut)
        let deleteAccount = NSButton(title: "Delete Account…", target: self, action: #selector(deleteAccountClicked))
        deleteAccount.bezelStyle = .inline
        deleteAccount.isBordered = false
        deleteAccount.contentTintColor = .systemRed
        deleteAccount.font = NSFont.systemFont(ofSize: 12)
        accountStack.addArrangedSubview(deleteAccount)

        // Devices card: this Mac, and an honest empty line
        // for the rest until the sync engine exists.
        let devicesCard = syncCard()
        let devicesStack = NSStackView()
        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 7
        devicesStack.translatesAutoresizingMaskIntoConstraints = false
        devicesCard.addSubview(devicesStack)
        devicesStack.addArrangedSubview(syncCardTitle("DEVICES"))
        let deviceDot = NSView()
        deviceDot.wantsLayer = true
        deviceDot.layer?.cornerRadius = 4
        // Colour is state-driven in refreshSyncView
        // (v2.18.1) — it used to be painted green here and
        // stayed green with sync off or in an error state.
        deviceDot.layer?.backgroundColor = NSColor(white: 0.66, alpha: 1).cgColor
        deviceDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        deviceDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        syncDeviceDot = deviceDot
        let deviceRow = NSStackView(views: [deviceDot,
                                            syncBodyLabel("This Mac", size: 12.5, weight: .medium),
                                            syncBodyLabel("this device", size: 11, color: .secondaryLabelColor)])
        deviceRow.orientation = .horizontal
        deviceRow.alignment = .centerY
        deviceRow.spacing = 8
        devicesStack.addArrangedSubview(deviceRow)
        devicesStack.addArrangedSubview(syncWrappingLabel("Other devices appear here once sync is running."))

        // Privacy & Data card: the promise, as a card.
        let privacyCard = syncCard()
        let privacyStack = NSStackView()
        privacyStack.orientation = .vertical
        privacyStack.alignment = .leading
        privacyStack.spacing = 7
        privacyStack.translatesAutoresizingMaskIntoConstraints = false
        privacyCard.addSubview(privacyStack)
        privacyStack.addArrangedSubview(syncCardTitle("PRIVACY & DATA"))
        let lockGlyph = NSImageView()
        lockGlyph.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        lockGlyph.contentTintColor = .secondaryLabelColor
        lockGlyph.widthAnchor.constraint(equalToConstant: 13).isActive = true
        lockGlyph.heightAnchor.constraint(equalToConstant: 13).isActive = true
        let promiseRow = NSStackView(views: [lockGlyph,
                                             syncBodyLabel("Sensitive clips never sync", size: 12.5, weight: .semibold)])
        promiseRow.orientation = .horizontal
        promiseRow.alignment = .centerY
        promiseRow.spacing = 6
        privacyStack.addArrangedSubview(promiseRow)
        privacyStack.addArrangedSubview(syncWrappingLabel("Clips marked sensitive and copies from password managers never leave this device."))

        // Stacks pin all four sides (v2.18.1), the invite
        // card's pattern: top-only pinning left the content
        // flush on each card's bottom edge, and with the row
        // top-aligned the three cards ended at three heights.
        for (card, stack) in [(accountCard, accountStack), (devicesCard, devicesStack), (privacyCard, privacyStack)] {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.spaceCardPad),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.spaceCardPad),
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.spaceCardPad),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.spaceCardPad)
            ])
        }

        let cardsRow = NSStackView(views: [accountCard, devicesCard, privacyCard])
        cardsRow.orientation = .horizontal
        cardsRow.alignment = .height
        cardsRow.distribution = .fillEqually
        cardsRow.spacing = Self.spaceCardGap
        cardsRow.translatesAutoresizingMaskIntoConstraints = false
        signedIn.addSubview(cardsRow)

        // Signed-out body: the centred invitation card from
        // the mocks.
        let signedOut = NSView()
        signedOut.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(signedOut)
        syncSignedOutView = signedOut

        let inviteCard = syncCard()
        signedOut.addSubview(inviteCard)
        let invite = NSStackView()
        invite.orientation = .vertical
        invite.alignment = .leading
        invite.spacing = 10
        invite.translatesAutoresizingMaskIntoConstraints = false
        inviteCard.addSubview(invite)
        let headline = NSTextField(labelWithString: "Your clipboard, on every device")
        headline.font = NSFont.systemFont(ofSize: 16.5, weight: .semibold)
        invite.addArrangedSubview(headline)
        invite.addArrangedSubview(syncWrappingLabel("Sign in to sync this Mac's history with ClipKeep on Android, iOS and Web. Sensitive clips never sync.", size: 12, maxWidth: 416))
        let googleButton = socialButton(title: "Sign in with Google", background: .white,
                                        foreground: NSColor(white: 0.2, alpha: 1),
                                        bordered: true, action: #selector(signInGoogleClicked(_:)))
        invite.addArrangedSubview(googleButton)
        let lineA = NSView()
        lineA.wantsLayer = true
        lineA.layer?.backgroundColor = NSColor(white: 0, alpha: 0.12).cgColor
        lineA.heightAnchor.constraint(equalToConstant: 1).isActive = true
        lineA.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let lineB = NSView()
        lineB.wantsLayer = true
        lineB.layer?.backgroundColor = NSColor(white: 0, alpha: 0.12).cgColor
        lineB.heightAnchor.constraint(equalToConstant: 1).isActive = true
        lineB.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let orLabel = NSTextField(labelWithString: "or")
        orLabel.font = NSFont.systemFont(ofSize: 11)
        orLabel.textColor = .secondaryLabelColor
        let divider = NSStackView(views: [lineA, orLabel, lineB])
        divider.orientation = .horizontal
        divider.alignment = .centerY
        divider.distribution = .fill
        divider.spacing = 10
        invite.addArrangedSubview(divider)
        let emailField = NSTextField()
        emailField.placeholderString = "Email"
        emailField.font = NSFont.systemFont(ofSize: 12.5)
        emailField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        syncEmailField = emailField
        // Return in the field is the button (v2.18.1): the
        // field's action fires on end editing and lands on
        // the same handler, which reads the field's value —
        // since v2.19.3, as the address the native code
        // flow sends to.
        emailField.target = self
        emailField.action = #selector(signInEmailClicked(_:))
        let emailButton = NSButton(title: "Email me a code", target: self, action: #selector(signInEmailClicked(_:)))
        emailButton.bezelStyle = .rounded
        syncEmailButton = emailButton
        let emailRow = NSStackView(views: [emailField, emailButton])
        emailRow.orientation = .horizontal
        emailRow.alignment = .centerY
        emailRow.spacing = 9
        invite.addArrangedSubview(emailRow)
        // Send-side errors (v2.19.3): a missing address, a
        // refused send — shown under the email row while
        // no code round trip is live.
        let emailError = NSTextField(wrappingLabelWithString: "")
        emailError.font = NSFont.systemFont(ofSize: 11.5)
        emailError.textColor = .systemRed
        emailError.preferredMaxLayoutWidth = 416
        emailError.isHidden = true
        syncEmailErrorLabel = emailError
        invite.addArrangedSubview(emailError)
        // Code entry (v2.19.3): appears once a code is on
        // its way, driven by refreshSyncView from
        // AuthManager's OTP phase. Built once here — the
        // refresh only toggles and relabels, so a typed
        // code survives the state changes around it.
        let otpLabel = NSTextField(wrappingLabelWithString: "")
        otpLabel.font = NSFont.systemFont(ofSize: 12)
        otpLabel.preferredMaxLayoutWidth = 416
        syncOTPLabel = otpLabel
        let otpField = NSTextField()
        otpField.placeholderString = "6-digit code"
        otpField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        otpField.alignment = .center
        otpField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        otpField.target = self
        otpField.action = #selector(syncOTPConfirmClicked(_:))
        syncOTPField = otpField
        let otpConfirm = NSButton(title: "Sign in", target: self, action: #selector(syncOTPConfirmClicked(_:)))
        otpConfirm.bezelStyle = .rounded
        syncOTPConfirmButton = otpConfirm
        let otpCodeRow = NSStackView(views: [otpField, otpConfirm])
        otpCodeRow.orientation = .horizontal
        otpCodeRow.alignment = .centerY
        otpCodeRow.spacing = 9
        let otpResend = NSButton(title: "Resend code", target: self, action: #selector(otpResendClicked))
        otpResend.bezelStyle = .inline
        otpResend.isBordered = false
        otpResend.font = NSFont.systemFont(ofSize: 11.5)
        otpResend.contentTintColor = .secondaryLabelColor
        syncOTPResendButton = otpResend
        let otpDifferent = NSButton(title: "Use a different email", target: self, action: #selector(otpCancelClicked))
        otpDifferent.bezelStyle = .inline
        otpDifferent.isBordered = false
        otpDifferent.font = NSFont.systemFont(ofSize: 11.5)
        otpDifferent.contentTintColor = .secondaryLabelColor
        let otpQuietRow = NSStackView(views: [otpResend, otpDifferent])
        otpQuietRow.orientation = .horizontal
        otpQuietRow.alignment = .centerY
        otpQuietRow.spacing = 14
        let otpError = NSTextField(wrappingLabelWithString: "")
        otpError.font = NSFont.systemFont(ofSize: 11.5)
        otpError.textColor = .systemRed
        otpError.preferredMaxLayoutWidth = 416
        otpError.isHidden = true
        syncOTPErrorLabel = otpError
        let otpBlock = NSStackView()
        otpBlock.orientation = .vertical
        otpBlock.alignment = .leading
        otpBlock.spacing = 8
        otpBlock.addArrangedSubview(otpLabel)
        otpBlock.addArrangedSubview(otpCodeRow)
        otpBlock.addArrangedSubview(otpQuietRow)
        otpBlock.addArrangedSubview(otpError)
        otpBlock.isHidden = true
        syncOTPBlock = otpBlock
        invite.addArrangedSubview(otpBlock)
        // Waiting row (v2.19.3): the web (Google) flow
        // leaves the app in a browser sheet — while it's
        // out, the card says where it went and offers the
        // way back.
        let waitingLabel = syncWrappingLabel("Finish signing in in the browser window that opened — macOS may ask to open it first; that's expected.", size: 11.5, maxWidth: 330)
        let waitingCancel = NSButton(title: "Cancel", target: self, action: #selector(cancelWebSignInClicked))
        waitingCancel.bezelStyle = .rounded
        waitingCancel.controlSize = .small
        let waitingRow = NSStackView(views: [waitingLabel, waitingCancel])
        waitingRow.orientation = .horizontal
        waitingRow.alignment = .centerY
        waitingRow.spacing = 9
        waitingRow.isHidden = true
        syncWaitingRow = waitingRow
        invite.addArrangedSubview(waitingRow)
        let lockSmall = NSImageView()
        lockSmall.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        lockSmall.contentTintColor = .secondaryLabelColor
        lockSmall.widthAnchor.constraint(equalToConstant: 11).isActive = true
        lockSmall.heightAnchor.constraint(equalToConstant: 11).isActive = true
        let reassuranceRow = NSStackView(views: [lockSmall,
                                                 syncBodyLabel("ClipKeep stays fully local if you never sign in", size: 11.5, color: .secondaryLabelColor)])
        reassuranceRow.orientation = .horizontal
        reassuranceRow.alignment = .centerY
        reassuranceRow.spacing = 6
        invite.addArrangedSubview(reassuranceRow)
        for view in [googleButton, divider, emailRow, emailError, otpBlock, waitingRow] as [NSView] {
            view.widthAnchor.constraint(equalTo: invite.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.spaceMargin),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.spaceMargin),
            container.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.spaceMargin),

            modeRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            modeRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            modeRow.topAnchor.constraint(equalTo: container.topAnchor),

            signedIn.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            signedIn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            signedIn.topAnchor.constraint(equalTo: modeRow.bottomAnchor, constant: 12),
            signedIn.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            signedOut.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            signedOut.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            signedOut.topAnchor.constraint(equalTo: modeRow.bottomAnchor, constant: 12),
            signedOut.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            hero.leadingAnchor.constraint(equalTo: signedIn.leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: signedIn.trailingAnchor),
            hero.topAnchor.constraint(equalTo: signedIn.topAnchor),
            hero.heightAnchor.constraint(equalToConstant: 92),

            cardsRow.leadingAnchor.constraint(equalTo: signedIn.leadingAnchor),
            cardsRow.trailingAnchor.constraint(equalTo: signedIn.trailingAnchor),
            cardsRow.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: Self.spaceCardGap),
            cardsRow.bottomAnchor.constraint(equalTo: signedIn.bottomAnchor),

            invite.leadingAnchor.constraint(equalTo: inviteCard.leadingAnchor, constant: 22),
            invite.trailingAnchor.constraint(equalTo: inviteCard.trailingAnchor, constant: -22),
            invite.topAnchor.constraint(equalTo: inviteCard.topAnchor, constant: 20),
            invite.bottomAnchor.constraint(equalTo: inviteCard.bottomAnchor, constant: -20),
            inviteCard.centerXAnchor.constraint(equalTo: signedOut.centerXAnchor),
            inviteCard.centerYAnchor.constraint(equalTo: signedOut.centerYAnchor),
            inviteCard.widthAnchor.constraint(equalToConstant: 460)
        ])

        // Warm render (v2.18.1): lay the view out now and let
        // its layer rasterize, so the first avatar click
        // doesn't pay the first composite of this whole
        // surface on the panel's full-width frost (delay
        // finding F3).
        container.wantsLayer = true
        container.layer?.shouldRasterize = true
        container.layer?.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
        container.layoutSubtreeIfNeeded()
    }

    func refreshSyncView() {
        refreshAvatarButton()
        guard syncView != nil else { return }
        let identity = auth.session?.identity
        syncSignedInView.isHidden = identity == nil
        syncSignedOutView.isHidden = identity != nil

        // Hero states: auth errors first, then — signed in
        // with sync on — the engine's own state, with the
        // last-synced time in the detail line.
        let status: String
        let glyph: String
        let tint: NSColor
        var detail = "Sync launches with ClipKeep Cloud"
        var syncNowEnabled = false
        if case .error(let message) = auth.state {
            status = "Error"
            detail = message
            glyph = "exclamationmark.triangle.fill"
            tint = .systemOrange
        } else if identity != nil && syncEnabled {
            switch syncEngine.state {
            case .syncing:
                status = "Syncing…"
                detail = "Talking to ClipKeep Cloud"
                glyph = "arrow.triangle.2.circlepath"
                tint = .systemBlue
            case .offline:
                status = "Offline"
                detail = lastSyncDetail(prefix: "Will retry when you're back online")
                glyph = "wifi.slash"
                tint = .systemOrange
            case .signInExpired:
                status = "Sign-in expired"
                detail = "Sign in again to resume sync"
                glyph = "exclamationmark.triangle.fill"
                tint = .systemOrange
            case .idle:
                status = "Up to date"
                detail = lastSyncDetail(prefix: nil)
                glyph = "checkmark"
                tint = .systemGreen
            }
            syncNowEnabled = syncEngine.state != .syncing
        } else {
            status = "Sync off"
            glyph = "pause.fill"
            tint = .systemGray
        }
        heroStatusLabel.stringValue = status
        heroDetailLabel.stringValue = detail
        heroGlyphView.image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)
        heroGlyphView.contentTintColor = tint
        heroRingView.layer?.borderColor = tint.cgColor
        heroToggle.state = syncEnabled ? .on : .off
        heroSyncNowButton.isEnabled = syncNowEnabled

        // The Devices card dot mirrors the avatar dot's
        // state (v2.18.1) — painted once at build, it read
        // "happily syncing" even with sync off or in error.
        if case .error = auth.state {
            syncDeviceDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
        } else if identity != nil && syncEnabled {
            syncDeviceDot?.layer?.backgroundColor = NSColor.systemGreen.cgColor
        } else {
            syncDeviceDot?.layer?.backgroundColor = NSColor(white: 0.66, alpha: 1).cgColor
        }

        // The esc keycap follows the theme (v2.18.1) with
        // the same values refreshList paints on the empty
        // state's hint chips.
        syncEscChip?.layer?.backgroundColor = currentTheme.dark
            ? NSColor(white: 1, alpha: 0.10).cgColor
            : NSColor(white: 0, alpha: 0.06).cgColor
        syncEscChip?.layer?.borderColor = currentTheme.dark
            ? NSColor(white: 1, alpha: 0.14).cgColor
            : NSColor(white: 0, alpha: 0.10).cgColor
        syncEscLabel?.textColor = currentTheme.dark
            ? NSColor(white: 1, alpha: 0.85)
            : NSColor(white: 0, alpha: 0.75)

        syncIdentityLabel.stringValue = accountDisplayName(identity)
        syncEmailLabel.stringValue = identity?.email ?? ""

        // Native email code (v2.19.3): the send button's
        // state, the code block, both error lines and the
        // web flow's waiting row all read off AuthManager.
        // The block's label is set on the awaiting-code
        // transition and left alone while confirming (the
        // confirming phase carries no destination).
        let phase = auth.otpPhase
        syncEmailButton.title = phase == .sending ? "Sending…" : "Email me a code"
        syncEmailButton.isEnabled = phase != .sending && phase != .confirming
        switch phase {
        case .awaitingCode(_, let destination):
            syncOTPLabel.stringValue = "Enter the 6-digit code sent to \(destination)"
            syncOTPBlock.isHidden = false
        case .confirming:
            syncOTPBlock.isHidden = false
        case .idle, .sending:
            syncOTPBlock.isHidden = true
        }
        syncOTPConfirmButton.title = phase == .confirming ? "Signing in…" : "Sign in"
        syncOTPConfirmButton.isEnabled = phase != .confirming
        var otpAwaiting = false
        if case .awaitingCode = phase { otpAwaiting = true }
        syncOTPResendButton.isEnabled = otpAwaiting
        let otpErrorText = auth.otpError ?? ""
        syncOTPErrorLabel.stringValue = otpErrorText
        syncOTPErrorLabel.isHidden = otpErrorText.isEmpty || syncOTPBlock.isHidden
        syncEmailErrorLabel.stringValue = phase == .idle ? otpErrorText : ""
        syncEmailErrorLabel.isHidden = !(phase == .idle && !otpErrorText.isEmpty)
        syncWaitingRow.isHidden = auth.state != .signingIn
    }

    // The avatar's face (v2.19.2): one disc, both states —
    // see the construction note. Painted here and again from
    // the button's chrome hook whenever hover/press changes,
    // so the disc answers the pointer exactly as the button's
    // own painted chrome used to.
    func paintAvatarFace() {
        guard avatarDisc != nil, avatarButton != nil else { return }
        let hovering = avatarButton.isHoveringNow
        let pressing = avatarButton.isPressingNow
        if let identity = auth.session?.identity {
            let bg = pressing ? NSColor(red: 0.780, green: 0.275, blue: 0.140, alpha: 1)
                : hovering ? NSColor(red: 0.855, green: 0.310, blue: 0.160, alpha: 1)
                : NSColor(red: 0.894, green: 0.341, blue: 0.180, alpha: 1)   // #e4572e
            avatarDisc.layer?.backgroundColor = bg.cgColor
            avatarInitial.stringValue = accountInitial(for: identity)
            avatarInitial.isHidden = false
            avatarGlyph.isHidden = true
        } else {
            // Signed-out wash (v2.18.1): warm, theme-keyed —
            // flat grey read as a disabled control.
            let wash = currentTheme.dark
                ? NSColor(red: 0.42, green: 0.38, blue: 0.34, alpha: 1)
                : NSColor(red: 0.71, green: 0.65, blue: 0.58, alpha: 1)
            let bg = pressing ? (wash.blended(withFraction: 0.18, of: .black) ?? wash)
                : hovering ? (wash.blended(withFraction: 0.10, of: .black) ?? wash)
                : wash
            avatarDisc.layer?.backgroundColor = bg.cgColor
            avatarInitial.isHidden = true
            avatarGlyph.isHidden = false
        }
    }

    func refreshAvatarButton() {
        guard avatarButton != nil else { return }
        paintAvatarFace()
        avatarButton.chromeBorderColor = syncOpen ? NSColor(red: 0, green: 0.478, blue: 1, alpha: 1) : nil
        avatarButton.chromeBorderWidth = syncOpen ? 2 : 1
        avatarButton.refreshChrome()
        // Status badge (v2.18.1): ringed with the panel's own
        // backdrop — the theme tint over the frost, solid
        // under Reduce Transparency, mirroring applyTheme —
        // not cardBG, which painted a pale crescent against
        // the search row (the "skewered" screenshot). Signed
        // out, the badge goes hollow: backdrop fill, grey
        // ring — a deliberate "no sync" read, not a faint dot
        // lost on the button's fill.
        let solid = UserDefaults.standard.bool(forKey: "ClipKeepReduceTransparency")
        let backdrop = solid ? currentTheme.tint.withAlphaComponent(1) : currentTheme.tint
        if case .error = auth.state {
            avatarDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            avatarDot.layer?.borderColor = backdrop.cgColor
        } else if auth.session != nil && syncEnabled {
            avatarDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            avatarDot.layer?.borderColor = backdrop.cgColor
        } else {
            avatarDot.layer?.backgroundColor = backdrop.cgColor
            avatarDot.layer?.borderColor = (currentTheme.dark
                ? NSColor(white: 0.85, alpha: 1)
                : NSColor(white: 0.45, alpha: 1)).cgColor
        }
    }

    func setSyncView(open: Bool) {
        syncOpen = open
        applySyncBodyVisibility()
        refreshSyncView()
        if open { auth.refreshIfNeeded() }
    }

    // The body swap: the Sync view and the feed chrome are
    // never visible at once. refreshList re-asserts this
    // after a rebuild (it manages the stack bar, sort shell
    // and empty state visibility itself), so a copy landing
    // while the Sync view is open can't resurrect the feed
    // underneath it.
    func applySyncBodyVisibility() {
        guard syncView != nil else { return }
        syncView.isHidden = !syncOpen
        pillTabs.isHidden = syncOpen
        for shell in toolbarShells { shell.isHidden = syncOpen }
        stackBar.isHidden = syncOpen || stackIDs.isEmpty
        scrollView.isHidden = syncOpen
        if syncOpen {
            scrollFade.isHidden = true
            emptyStateView.isHidden = true
            updateStrip.isHidden = true
        } else {
            sortShell.isHidden = (pillTabs?.selectedType ?? "all") != "color"
            emptyStateView.isHidden = !visibleItems().isEmpty
            updateScrollFade()
            refreshUpdateStrip()
        }
    }

    @objc func avatarClicked() {
        setSyncView(open: !syncOpen)
    }

    @objc func closeSyncViewClicked() {
        setSyncView(open: false)
    }

    @objc func syncToggleChanged(_ sender: NSSwitch) {
        auth.anchorWindow = sender.window
        syncEnabledChanged(sender.state == .on)
        sender.state = syncEnabled ? .on : .off
    }

    // The last-synced line for the Sync view + Settings,
    // from the engine's per-account record.
    func lastSyncDetail(prefix: String?) -> String {
        guard let last = syncEngine.displayLastSyncAt else {
            return prefix ?? "Not synced yet on this Mac"
        }
        let when = relativeTimeString(last)
        return prefix.map { "\($0) · Last synced \(when)" } ?? "Last synced \(when)"
    }

    @objc func syncNowClicked() {
        syncEngine.syncNow()
    }

    // Turning sync on while signed out prompts sign-in: the
    // toggle stays off and the sign-in path takes over (the
    // "aren't live yet" alert while accounts are off; the
    // hosted UI once configured).
    func syncEnabledChanged(_ on: Bool) {
        if on, auth.session == nil {
            // Signed out: the toggle just turns back off and
            // the sign-in card (already on screen in both
            // surfaces) does the asking. It used to launch the
            // hosted email sign-in here — the blank-window
            // flow the Nov 25 Loom showed — so v2.19.3 makes
            // the toggle launch nothing.
            syncEnabled = false
            refreshSyncView()
            refreshSettingsAccount()
            return
        }
        syncEnabled = on
        if on { syncEngine.syncNow() }
        refreshSyncView()
        refreshSettingsAccount()
    }

    @objc func signInGoogleClicked(_ sender: NSButton) {
        auth.anchorWindow = sender.window
        // The address typed on the invoking surface rides
        // along as a login hint (v2.19.3, mirroring the
        // email path's v2.18.1 treatment), so the hosted
        // UI pre-fills it instead of asking again. The
        // sender's window says which surface asked: the
        // Settings window or the panel.
        let field = (sender.window != nil && sender.window == settingsWindow)
            ? settingsEmailField : syncEmailField
        auth.signIn(provider: .google, loginHint: emailHint(from: field))
    }

    // The email path is native now (v2.19.3): the code is
    // requested and answered inside the app, no hosted UI.
    // The sender is the surface's "Email me a code" button
    // or its email field itself: Return in the field fires
    // the same action. (The Connect rows point at the
    // sign-in handlers directly since v2.18.1 — the
    // connect-prefixed duplicates were byte-identical.)
    @objc func signInEmailClicked(_ sender: NSControl) {
        auth.anchorWindow = sender.window
        auth.startEmailOTP(email: syncEmailField?.stringValue ?? "")
    }

    @objc func settingsEmailClicked(_ sender: NSControl) {
        auth.anchorWindow = sender.window
        auth.startEmailOTP(email: settingsEmailField?.stringValue ?? "")
    }

    @objc func syncOTPConfirmClicked(_ sender: NSControl) {
        auth.confirmEmailOTP(code: syncOTPField?.stringValue ?? "")
    }

    @objc func settingsOTPConfirmClicked(_ sender: NSControl) {
        auth.confirmEmailOTP(code: settingsOTPField?.stringValue ?? "")
    }

    // Resend starts a fresh challenge for the address the
    // current one was sent to — the phase carries it, so
    // both surfaces share the handler.
    @objc func otpResendClicked() {
        guard case .awaitingCode(let email, _) = auth.otpPhase else { return }
        auth.startEmailOTP(email: email)
    }

    // The panel's "Use a different email" and the Settings
    // tab's "Cancel" are the same way out.
    @objc func otpCancelClicked() {
        auth.cancelEmailOTP()
        syncOTPField?.stringValue = ""
        settingsOTPField?.stringValue = ""
    }

    // Clipboard code detection (v2.19.4, Femi's pick:
    // auto-fill AND auto-sign-in). While a sign-in code is
    // awaited, a freshly copied code fills both code fields
    // and submits itself — ClipKeep watches the clipboard
    // anyway; this puts that to work. The baseline is the
    // pasteboard's changeCount when the wait began, so a code
    // copied BEFORE the request can never fire it, and each
    // clipboard change is auto-tried at most once (a failed
    // attempt waits for a fresh copy, not a retry loop).
    private var otpClipboardBaseline: Int?
    private var otpClipboardTriedCount = 0

    func checkClipboardForOTPCode() {
        switch auth.otpPhase {
        case .awaitingCode:
            break
        case .confirming:
            return // an attempt is in flight; keep the baseline
        case .idle, .sending:
            otpClipboardBaseline = nil
            return
        }
        let pb = NSPasteboard.general
        guard let baseline = otpClipboardBaseline else {
            otpClipboardBaseline = pb.changeCount
            otpClipboardTriedCount = pb.changeCount
            return
        }
        let count = pb.changeCount
        guard count > baseline, count != otpClipboardTriedCount,
              count != selfWriteChangeCount else { return }
        // The capture path's privacy markers hold here too:
        // a concealed or transient copy is never read as a code.
        let types = pb.types ?? []
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        if types.contains(concealed) || types.contains(transient) { return }
        guard let code = otpCodeFromClipboard(pb.string(forType: .string)) else { return }
        otpClipboardTriedCount = count
        syncOTPField?.stringValue = code
        settingsOTPField?.stringValue = code
        auth.confirmEmailOTP(code: code)
    }

    @objc func cancelWebSignInClicked() {
        auth.cancelWebSignIn()
    }

    private func emailHint(from field: NSTextField?) -> String? {
        let trimmed = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    @objc func signOutClicked() {
        auth.signOut()
    }

    @objc func deleteAccountClicked() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete your ClipKeep account?"
        alert.informativeText = "This permanently deletes your account and everything synced to ClipKeep Cloud. Your local history on this Mac is not touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Account")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        auth.deleteAccount()
    }

    func showAccountsNotLiveAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Accounts aren't live yet"
        alert.informativeText = "Sign-in turns on when ClipKeep Cloud launches. ClipKeep stays fully local until then."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showDeleteUnavailableAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Account deletion isn't available yet"
        alert.informativeText = "Account deletion will be enabled when sync launches."
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        let pinnedItem = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
        pinnedItem.representedObject = "__pinned"
        boardPopup.menu?.addItem(pinnedItem)
        var names = store.boards
        for item in store.items {
            if let b = item.board, !names.contains(b) { names.append(b) }
        }
        for name in names {
            let menuItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")
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
    // Sort key for the Colours tab's hue ordering: chromatic
    // colours first, ordered by hue; greys (and near-greys) last,
    // lightest first.
    func hueSortKey(_ item: ClipItem) -> (grey: Bool, hue: Double, light: Double) {
        guard let hex = item.text, let c = colorFromHex(hex)?.usingColorSpace(.sRGB) else {
            return (true, 0, 0)
        }
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        if maxV == minV { return (true, 0, l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        if s < 0.08 { return (true, 0, l) }
        var h: Double
        if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxV == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (false, h * 60, l)
    }

    // How many clips a type tab holds across the whole history
    // (the pill badges; also the empty-state "in this tab" count).
    func countForType(_ type: String) -> Int {
        switch type {
        case "link": return store.items.filter { isLinkItem($0) }.count
        case "text": return store.items.filter { $0.kind == "text" && !isLinkItem($0) }.count
        case "all": return store.items.count
        default: return store.items.filter { $0.kind == type }.count
        }
    }

    func visibleItems() -> [ClipItem] {
        let q = (searchField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = pillTabs?.selectedType ?? "all"
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
        if type == "color",
           UserDefaults.standard.string(forKey: "ClipKeepColorSort") == "hue" {
            result = result.sorted { a, b in
                let ka = hueSortKey(a), kb = hueSortKey(b)
                if ka.grey != kb.grey { return !ka.grey && kb.grey }
                if ka.hue != kb.hue { return ka.hue < kb.hue }
                return ka.light > kb.light
            }
        }
        if board == nil {
            let pinned = result.filter { $0.pinned }
            let rest = result.filter { !$0.pinned }
            result = pinned + rest
        }
        return result
    }

    @objc private func scrollPositionChanged() { updateScrollFade() }

    // The fade's colour and visibility (v2.11.0). The gradient
    // runs from clear to the theme tint at near-full strength —
    // the closest match to the panel's frosted background a flat
    // overlay can make, and the standard solid-background fade
    // reads fine over it. Visible only while the feed overflows
    // to the right and isn't scrolled to the end. Called from
    // refreshList and on every scroll; applyTheme reaches it
    // through refreshList, so the colour follows the theme.
    func updateScrollFade() {
        guard scrollView != nil, scrollFade != nil,
              let doc = scrollView.documentView else { return }
        if let gradient = scrollFade.layer as? CAGradientLayer {
            let edge = currentTheme.tint.withAlphaComponent(0.95)
            gradient.colors = [edge.withAlphaComponent(0).cgColor, edge.cgColor]
        }
        let clip = scrollView.contentView
        let maxOffset = doc.frame.width - clip.bounds.width
        let overflowing = maxOffset > 1
        let atEnd = clip.bounds.origin.x >= maxOffset - 1
        scrollFade.isHidden = !overflowing || atEnd
    }

    func refreshList() {
        guard listStack != nil else { return }
        rebuildBoardPopup()
        rebuildAppPopup()
        // Drop stack entries whose clips are gone.
        stackIDs = stackIDs.filter { id in store.items.contains { $0.id == id } }
        stackBar.isHidden = stackIDs.isEmpty
        if stackBarTopConstraint != nil {
            // v2.15.4: an empty stack also collapses the bar's
            // height and top gap (see buildPanel).
            stackBarTopConstraint.constant = stackIDs.isEmpty ? 0 : Self.spaceRowGap
            stackBarZeroHeight.isActive = stackIDs.isEmpty
        }
        if !stackIDs.isEmpty {
            stackLabel.stringValue = "Paste Stack: \(stackIDs.count) queued — ⌃⌥⌘V pastes the next one"
        }
        // The hue-sort popup only exists on the Colours tab.
        if sortShell != nil {
            sortShell.isHidden = (pillTabs?.selectedType ?? "all") != "color"
        }
        // Live counts on the pill badges.
        if pillTabs != nil {
            var counts: [String: Int] = [:]
            for t in typeFilters { counts[t] = countForType(t) }
            pillTabs.setCounts(counts)
        }

        for view in listStack.arrangedSubviews { listStack.removeArrangedSubview(view); view.removeFromSuperview() }

        // The update notice no longer lives in the feed — it is
        // the strip under the search row (v2.6.0).

        let items = visibleItems()
        emptyStateView.isHidden = !items.isEmpty
        if items.isEmpty {
            // Say WHY the list is empty (v2.16.0: the designed
            // empty state — design C — fills the views; before,
            // a single grey label carried all three messages,
            // and the plain "copy something…" one also appeared
            // when filters were hiding a full history, which
            // read as lost data). Three modes: no history at all
            // gets the headline + getting-started hints; a tab
            // that has never held a clip says so in its own
            // terms; a search/filter with no matches says that.
            // The hint chips are restyled here, with the list,
            // so they always match the current theme.
            for chip in emptyChips {
                chip.view.layer?.backgroundColor = currentTheme.dark
                    ? NSColor(white: 1, alpha: 0.10).cgColor
                    : NSColor(white: 0, alpha: 0.06).cgColor
                chip.view.layer?.borderWidth = 1
                chip.view.layer?.borderColor = currentTheme.dark
                    ? NSColor(white: 1, alpha: 0.14).cgColor
                    : NSColor(white: 0, alpha: 0.10).cgColor
                chip.label.textColor = currentTheme.dark
                    ? NSColor(white: 1, alpha: 0.85)
                    : NSColor(white: 0, alpha: 0.75)
            }
            if store.items.isEmpty {
                emptyHeadline.stringValue = "Your clipboard, remembered"
                emptySubtext.isHidden = true
                emptyHints.isHidden = false
            } else {
                emptyHints.isHidden = true
                emptySubtext.isHidden = false
                // If the current tab has never held a clip, say so
                // in the tab's own terms instead of blaming filters.
                let type = pillTabs?.selectedType ?? "all"
                let inTab = countForType(type)
                let tabHints = ["text": "No text clips yet — copy some text and it will show up here.",
                                "link": "No links yet — copy a URL and it will show up here.",
                                "image": "No images yet — copy an image and it will show up here.",
                                "file": "No files yet — copy a file in Finder and it will show up here.",
                                "color": "No colours yet — copy a colour, or a #hex / rgb() string, and it will show up here."]
                if inTab == 0, let hint = tabHints[type] {
                    emptyHeadline.stringValue = "Nothing here yet"
                    emptySubtext.stringValue = hint + "\n\(store.items.count) clip\(store.items.count == 1 ? "" : "s") in history — the other tabs still show them."
                } else {
                    emptyHeadline.stringValue = "Nothing matches"
                    emptySubtext.stringValue = "\(store.items.count) clip\(store.items.count == 1 ? "" : "s") in history — clear the search or widen the filters to see them."
                }
            }
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
        // Keyboard navigation (roadmap #2): keep the selection
        // on a visible clip — if the selected clip was filtered
        // out or deleted, fall back to the first visible one.
        if selectedItemID == nil || !items.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = items.first?.id
        }
        applySelectionBorders()
        // The document view's width settles a beat after the
        // rebuild — check the fade now and once more next runloop.
        updateScrollFade()
        centerPanelContent()
        DispatchQueue.main.async { [weak self] in
            self?.updateScrollFade()
            self?.centerPanelContent()
        }
        // The Sync view owns the body while it's open
        // (v2.18.0): the visibility writes above (stack bar,
        // sort shell, empty state) must not resurrect the
        // feed underneath it.
        if syncOpen { applySyncBodyVisibility() }
    }

    // Deterministic height for a wrapping card label (v2.15.5).
    // AppKit's fitting height for these labels is not stable: on
    // some rebuilds it prices the text at a sliver width and the
    // card balloons to its line maximum — Femi's Nov 18 Loom shows
    // two identical 6-character clips swapping heights on every
    // filter toggle, re-rolled per rebuild. Measuring the string
    // directly at the label's real width (268) with a layout
    // manager takes the guesswork out: same inputs, same height,
    // every single rebuild.
    func cardLabelHeight(for text: String, font: NSFont, maxLines: Int) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: 268, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var lines = 0
        var glyphIndex = 0
        while glyphIndex < layout.numberOfGlyphs {
            var lineRange = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            glyphIndex = NSMaxRange(lineRange)
            lines += 1
        }
        let clamped = min(maxLines, max(1, lines))
        return ceil(CGFloat(clamped) * layout.defaultLineHeight(for: font)) + 1
    }

    func addRow(_ item: ClipItem, index: Int) {
        let row = rowView(for: item, index: index)
        listStack.addArrangedSubview(row)
        // Fixed-width cards in the horizontal feed. Height is the
        // card's own natural height — the old heightAnchor pin to
        // the stack stretched cards to full panel height and left
        // them mostly blank inside (the other mood in the demo).
        row.widthAnchor.constraint(equalToConstant: 300).isActive = true
        // …but natural height gets a hard cap (v2.11.0): in Femi's
        // Nov 18 screenshot, two cards ballooned to ~1.5× the
        // tallest honest card — empty in the middle, footers sunk
        // to the bottom — while their neighbours stayed compact.
        // Honest heights top out around 285pt (image cards), so
        // the cap sits just above that; the wrapping labels also
        // carry preferredMaxLayoutWidth now (see rowView), which
        // keeps their fitting heights honest in the first place.
        // v2.15.3: the fixed 312 cap became the feed's own height.
        // Femi: mid-length clips were cut off on the card and the
        // capped card + feed insets could exceed the viewport, so
        // the panel scrolled vertically. The cap is now the clip
        // view's height minus the feed insets — a card may use
        // every point the panel has, the document can never be
        // taller than the viewport (no vertical scroll, ever),
        // and the anti-balloon guard still holds: no card can
        // exceed what is actually visible.
        row.heightAnchor.constraint(lessThanOrEqualTo: scrollView.contentView.heightAnchor,
                                    constant: -2 * Self.spaceFeedInset).isActive = true
        // Card borders are owned by applySelectionBorders —
        // one outline, for the selection only (v2.13.0).
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
        clipIsLink(kind: item.kind, text: item.text)
    }

    func bandColor(for item: ClipItem) -> NSColor {
        if item.kind == "color", let hex = item.text, let c = colorFromHex(hex) { return c }
        // Links get their own teal — they used to share Text's
        // green, so the two card types read as one (Nov 17).
        if isLinkItem(item) { return NSColor(red: 0.0, green: 0.6, blue: 0.65, alpha: 1) }
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

    // MARK: Card thumbnails (v2.12.0 lag fix)
    //
    // Card surfaces used to decode the full-size image file on
    // every rebuild — NSImage(contentsOf:) in rowView, and again
    // in footerText just to read the dimensions. With an
    // image-heavy history, every panel open and every click paid
    // several full screenshot decodes. Now each file is decoded
    // once, downsampled to card size (552px ≈ 276pt at 2x), and
    // cached; dimensions come from the image source's properties
    // without decoding pixels at all. Image files are write-once
    // with UUID names, so a name-keyed cache can't go stale.
    // Full originals are still used where fidelity matters:
    // pasteboard writes and the Preview window.
    var thumbnailCache: [String: NSImage] = [:]
    var imageDimsCache: [String: NSSize] = [:]

    func cardThumbnail(forFile name: String) -> NSImage? {
        if let cached = thumbnailCache[name] { return cached }
        let url = store.imagesDir.appendingPathComponent(name)
        var result: NSImage?
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                imageDimsCache[name] = NSSize(width: w, height: h)
            }
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 552
            ] as CFDictionary) {
                result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        if result == nil { result = NSImage(contentsOf: url) }
        if let result {
            if thumbnailCache.count > 300 { thumbnailCache.removeAll() }
            thumbnailCache[name] = result
        }
        return result
    }

    func imageDimensions(forFile name: String) -> NSSize? {
        if let cached = imageDimsCache[name] { return cached }
        _ = cardThumbnail(forFile: name)
        return imageDimsCache[name]
    }

    func footerText(for item: ClipItem) -> String {
        if isLinkItem(item), let raw = item.text,
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let host = url.host {
            return host
        }
        switch item.kind {
        case "image":
            if let name = item.imageFile, let dims = imageDimensions(forFile: name) {
                return "PNG · \(Int(dims.width)) × \(Int(dims.height))"
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

    // Card hover lift (v2.11.0, from Femi's polish picks): the
    // card's shadow deepens and spreads while the cursor is over
    // it — the feed's only "this is clickable" signal before the
    // click itself. Shadow only: the selection border and the
    // copy/paste flash both work through the border and are
    // untouched by this.
    func setCardHover(_ card: NSView, hovering: Bool) {
        guard let layer = card.layer else { return }
        let toOpacity: Float = hovering ? 0.18 : 0.08
        let toRadius: CGFloat = hovering ? 12 : 6
        let opacityAnim = CABasicAnimation(keyPath: "shadowOpacity")
        opacityAnim.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        opacityAnim.toValue = toOpacity
        opacityAnim.duration = 0.15
        layer.add(opacityAnim, forKey: "shadowOpacity")
        let radiusAnim = CABasicAnimation(keyPath: "shadowRadius")
        radiusAnim.fromValue = layer.presentation()?.shadowRadius ?? layer.shadowRadius
        radiusAnim.toValue = toRadius
        radiusAnim.duration = 0.15
        layer.add(radiusAnim, forKey: "shadowRadius")
        layer.shadowOpacity = toOpacity
        layer.shadowRadius = toRadius
        // Hover wash (Nov 18, Femi's hover Loom): the shadow
        // lift alone did not read on the frosted panel — at
        // 0:38 in his recording a hovered card looked
        // untouched. Blend the theme's hover wash into the
        // card's own background as well (black 6% on Warm,
        // white 10% on the dark themes — the wash colour's
        // alpha is the blend fraction), animated on the same
        // 0.15s beat, so hover registers at a glance in every
        // theme. The copy/paste flash uses the border + a
        // chip, so the two never fight.
        if let wash = currentTheme.hoverWash.usingColorSpace(.sRGB),
           let base = currentTheme.cardBG.usingColorSpace(.sRGB) {
            let washColour = NSColor(red: wash.redComponent, green: wash.greenComponent,
                                     blue: wash.blueComponent, alpha: 1)
            let target = base.blended(withFraction: hovering ? wash.alphaComponent : 0,
                                           of: washColour) ?? base
            let bgAnim = CABasicAnimation(keyPath: "backgroundColor")
            bgAnim.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            bgAnim.toValue = target.cgColor
            bgAnim.duration = 0.15
            layer.add(bgAnim, forKey: "backgroundColor")
            layer.backgroundColor = target.cgColor
        }
    }

    // Card footer actions are icon buttons (v2.4.0 button
    // overhaul): pin, stack, delete as SF Symbols with hover
    // washes. Delete is the danger variant — it washes red on
    // hover so the destructive action reads as one; a pinned
    // clip's pin stays accent-filled.
    func cardIconButton(symbol: String, action: Selector, id: String, tip: String,
                        danger: Bool = false, active: Bool = false) -> HoverButton {
        let b = HoverButton(frame: .zero)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            b.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        }
        b.imagePosition = .imageOnly
        b.target = self
        b.action = action
        // Legibility (v2.11.0): the footer glyphs were the
        // faintest thing on the card at secondaryLabelColor.
        // The tint is the THEME's own static colour, never a
        // derived system colour: labelColor.withAlphaComponent
        // (the v2.11.0 code) resolves the dynamic colour in
        // the APP's appearance at build time — on a dark-mode
        // Mac it bakes white, which then draws white-on-white
        // on Warm Tint's cards and the footer icons vanish
        // (Femi's Loom, Nov 18). The pinned state keeps the
        // accent, delete keeps its red hover.
        b.baseTint = active ? currentTheme.accent : currentTheme.iconTint
        b.hoverBG = currentTheme.hoverWash
        b.pressedBG = currentTheme.pressedWash
        if danger {
            b.hoverTint = .systemRed
            b.hoverBG = NSColor.systemRed.withAlphaComponent(0.12)
        }
        b.toolTip = tip
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    func rowView(for item: ClipItem, index: Int) -> NSView {
        let band = bandColor(for: item)
        let onBand = onBandTextColor(for: band)

        let card = NSView()
        card.identifier = NSUserInterfaceItemIdentifier(item.id)
        card.wantsLayer = true
        card.layer?.backgroundColor = currentTheme.cardBG.cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = currentTheme.cardBorder.cgColor
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
            typeText.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Self.spaceCardPad),
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
                badge.leadingAnchor.constraint(equalTo: lastInHeader, constant: 8),
                badge.centerYAnchor.constraint(equalTo: typeText.centerYAnchor)
            ])
            lastInHeader = badge.trailingAnchor
        }
        if item.pinned {
            // SF Symbol, not the 📌 emoji (v2.11.0 icon pass) —
            // same reasoning as the menu-bar item: the emoji sat
            // at a different weight and baseline than everything
            // around it.
            let pinMark = NSImageView()
            if let img = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned") {
                pinMark.image = img.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            }
            pinMark.contentTintColor = onBand
            pinMark.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(pinMark)
            NSLayoutConstraint.activate([
                pinMark.leadingAnchor.constraint(equalTo: lastInHeader, constant: 8),
                pinMark.centerYAnchor.constraint(equalTo: typeText.centerYAnchor),
                pinMark.widthAnchor.constraint(equalToConstant: 12),
                pinMark.heightAnchor.constraint(equalToConstant: 12)
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
                badgeBox.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Self.spaceCardPad),
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
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)

        func fullWidth(_ v: NSView) {
            v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        switch item.kind {
        case "image":
            let iv = NSImageView()
            if let name = item.imageFile, let img = cardThumbnail(forFile: name) {
                iv.image = img
            }
            // A pulled image clip whose bytes aren't local
            // yet renders as the empty tile above; rendering
            // it is what asks the engine to fetch them.
            if item.imageFile == nil {
                syncEngine.fetchImageIfNeeded(item)
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
                chip.layer?.backgroundColor = currentTheme.trackBG.cgColor
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
                    iv.image = cardThumbnail(forFile: name)
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
                    // Decoded at display time as well as fetch
                    // time (v2.13.0): clips captured before
                    // v2.11.0 still carry the raw entity in
                    // their stored title (&#8211; on Femi's
                    // Nov 18 panel screenshot).
                    let t = NSTextField(wrappingLabelWithString: cleanLinkTitle(title))
                    t.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
                    t.textColor = .labelColor
                    t.maximumNumberOfLines = 2
                    t.lineBreakMode = .byWordWrapping
                    // Wrapping labels inside the horizontal feed
                    // need their layout width up front (268 = card
                    // 300 − 32 insets, the card padding since
                    // v2.15.0): without it, the fitting
                    // pass can price the label at a sliver width
                    // and its "height" balloons — the cavern cards
                    // in Femi's Nov 18 screenshot.
                    t.preferredMaxLayoutWidth = 268
                    // Same treatment as the text label (v2.15.5):
                    // exact height from the string, ≤38 cap as a
                    // guard (the title wraps to at most 2 lines).
                    t.heightAnchor.constraint(lessThanOrEqualToConstant: 38).isActive = true
                    t.heightAnchor.constraint(equalToConstant: cardLabelHeight(for: cleanLinkTitle(title), font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), maxLines: 2)).isActive = true
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
                label.lineBreakMode = .byWordWrapping
                label.preferredMaxLayoutWidth = 268   // see the link-title note above
                // Height is set exactly, from the string itself
                // (v2.15.5, see cardLabelHeight): the label
                // wraps at 5 lines, and AppKit's fitting
                // height for it proved unstable — the "cavern
                // cards" (identical 6-character clips rendering
                // at different heights, Nov 18). The ≤88 cap stays
                // as a guard; the exact height does the real work.
                // The line-break mode must stay .byWordWrapping
                // (v2.16.1): with .byTruncatingTail the cell
                // truncated each hard line instead of wrapping,
                // so the display never matched the measured
                // height — Femi's Nov 19 screenshot showed
                // 248/194/96-character clips as one truncated
                // line each inside 5/4/2-line-tall cards.
                label.heightAnchor.constraint(lessThanOrEqualToConstant: 88).isActive = true
                label.heightAnchor.constraint(equalToConstant: cardLabelHeight(for: item.preview, font: NSFont.systemFont(ofSize: 13), maxLines: 5)).isActive = true
                body.addArrangedSubview(label)
                fullWidth(label)
            }
        }

        // Footer: actions left and right, Paste-style metadata centred.
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(footer)

        let pin = cardIconButton(symbol: item.pinned ? "pin.fill" : "pin", action: #selector(pinClicked(_:)), id: item.id, tip: item.pinned ? "Unpin" : "Pin", active: item.pinned)
        footer.addSubview(pin)

        let boardButton = NSPopUpButton(frame: .zero, pullsDown: true)
        boardButton.isBordered = false
        boardButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        boardButton.contentTintColor = .secondaryLabelColor
        boardButton.toolTip = "Move to a pinboard"
        boardButton.identifier = NSUserInterfaceItemIdentifier(item.id)
        boardButton.translatesAutoresizingMaskIntoConstraints = false
        let headerItem = NSMenuItem(title: item.board ?? "Board", action: nil, keyEquivalent: "")
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

        let stack = cardIconButton(symbol: "square.stack.3d.up", action: #selector(stackClicked(_:)), id: item.id, tip: "Add to the Paste Stack")
        footer.addSubview(stack)
        let del = cardIconButton(symbol: "trash", action: #selector(deleteClicked(_:)), id: item.id, tip: "Delete this clip", danger: true)
        footer.addSubview(del)

        let meta = NSTextField(labelWithString: footerText(for: item))
        meta.font = NSFont.systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.alignment = .center
        meta.lineBreakMode = .byTruncatingTail
        // The metadata yields first when the footer is tight —
        // until v2.11.0 the board popup was the one squeezed,
        // down to "Bo…" (Femi's Nov 18 screenshot).
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(meta)

        // Invisible click target over header + body. Click
        // model (v2.16.3, Femi's calls): a single click
        // selects the card; a double-click PASTES the clip
        // into the app underneath (v2.13.0 pasted too;
        // v2.14.0 switched double-click to copy-only at his
        // word then, and on Nov 21, 2026 he asked for the
        // paste back — copying and then pasting separately
        // was friction). Copy-only lives on the right-click
        // menu's Copy, which still closes the panel once
        // the flash lands (v2.14.1). Pasting also lives on
        // Enter, ⌘1–9 and the card's paste button. The
        // Settings toggle makes a single click paste
        // instead; the wiring reads it live, no rebuild
        // needed.
        let click = ClickView()
        click.identifier = NSUserInterfaceItemIdentifier(item.id)
        click.onClick = { [weak self] clickCount in
            guard let self else { return }
            self.cancelCopyDismiss()
            if self.pasteOnSingleClick {
                self.pasteBack(item)
            } else if clickCount >= 2 {
                self.pasteBack(item)
            } else {
                self.selectedItemID = item.id
                self.applySelectionBorders()
            }
        }
        click.onHover = { [weak self] hovering in self?.setCardHover(card, hovering: hovering) }
        click.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(click)

        // Preview / edit button in the header — added after the click
        // overlay so the overlay does not swallow its clicks.
        let previewBtn = NSButton()
        if let img = NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview") {
            previewBtn.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        }
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
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Self.spaceCardPad),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.spaceCardPad),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.spaceCardPad),

            footer.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.heightAnchor.constraint(equalToConstant: 32),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),

            click.topAnchor.constraint(equalTo: card.topAnchor),
            click.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            click.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            click.bottomAnchor.constraint(equalTo: footer.topAnchor),

            previewBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            previewBtn.trailingAnchor.constraint(equalTo: appBadgeLeading ?? header.trailingAnchor, constant: appBadgeLeading == nil ? -Self.spaceCardPad : -6),
            previewBtn.widthAnchor.constraint(equalToConstant: 26),
            previewBtn.heightAnchor.constraint(equalToConstant: 26),

            pin.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Self.spaceCardPad),
            pin.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 28),
            pin.heightAnchor.constraint(equalToConstant: 28),
            boardButton.leadingAnchor.constraint(equalTo: pin.trailingAnchor, constant: 8),
            boardButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            del.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Self.spaceCardPad),
            del.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            del.widthAnchor.constraint(equalToConstant: 28),
            del.heightAnchor.constraint(equalToConstant: 28),
            stack.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 28),
            stack.heightAnchor.constraint(equalToConstant: 28),
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
        store.touch(id: found.id)
        store.save()
        noteSyncMutation(found.id)
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
            store.touch(id: found.id)
            store.save()
            noteSyncMutation(found.id)
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
        noteSyncMutation(found.id)
        refreshList()
    }

    @objc func clearHistory() {
        // Confirmation (v2.15.5): this deletes every unpinned
        // clip and its image files, irreversibly, and it sits one
        // click away in Settings and the ••• menu — one stray
        // click used to wipe the history with no way back.
        let alert = NSAlert()
        alert.messageText = "Clear history?"
        alert.informativeText = "All unpinned clips will be deleted, including their image files. Pinned and boarded clips are kept. This can't be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        if panel.isVisible { panel.makeKeyAndOrderFront(nil) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearHistory()
        // The clear tombstoned everything it removed: file
        // them all with the outbox so the deletions sync.
        for stone in store.tombstones { noteSyncMutation(stone.id) }
        refreshList()
    }

    @objc func togglePause() {
        capturePaused.toggle()
        refreshStatusItem()
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
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for theme in panelThemes {
            let mi = NSMenuItem(title: theme.name, action: #selector(themeChosen(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = theme.id
            mi.state = currentTheme.id == theme.id ? .on : .off
            themeMenu.addItem(mi)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)
        let iconItem = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
        let iconMenu = NSMenu()
        for (title, id) in Self.menuBarIconStyles {
            let mi = NSMenuItem(title: title, action: #selector(menuBarIconChosen(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
            mi.state = menuBarIconStyle == id ? .on : .off
            iconMenu.addItem(mi)
        }
        iconItem.submenu = iconMenu
        menu.addItem(iconItem)
        let rtItem = NSMenuItem(title: "Reduce Transparency", action: #selector(toggleReduceTransparency), keyEquivalent: "")
        rtItem.target = self
        rtItem.state = UserDefaults.standard.bool(forKey: "ClipKeepReduceTransparency") ? .on : .off
        menu.addItem(rtItem)
        add("Excluded Apps…", #selector(showExclusions))
        add("Reset Panel Size", #selector(resetPanelSize))
        add("Clear History", #selector(clearHistory))
        menu.addItem(.separator())
        add("Quit ClipKeep", #selector(quitApp))
        NSMenu.popUpContextMenu(menu, with: event, for: sender)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    @objc func resetPanelSize() {
        // The frame is fixed since v2.9.1, so this simply
        // re-applies it. (It also used to clear the retired
        // saved-frame key; v2.16.0 removed that plumbing — the
        // stale V3–V6 keys are purged at launch instead.)
        applyFixedPanelFrame()
    }

    // MARK: Excluded apps

    @objc func showExclusions() {
        if exclusionsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Excluded apps — copies from these are never recorded"
            window.isReleasedWhenClosed = false
            window.level = .floating   // above the panel (v2.13.0) — see buildSettingsWindow
            // Same collapse guard as the Settings window (Nov
            // 18): fixed-size window + a scroll view with no
            // minimum size anywhere in its sizing chain.
            window.contentMinSize = NSSize(width: 400, height: 320)
            window.contentMaxSize = NSSize(width: 400, height: 320)
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
            // FlippedView, not a plain NSView (v2.12.0): in a
            // non-flipped document view the top-pinned stack
            // renders from the bottom — the list opened scrolled
            // to the wrong end with rows clipped, the same bug
            // class as the panel feed's v2.2.1 strip bug. The
            // bottom constraint is an equality so the document
            // is exactly as tall as its content.
            let clipView = FlippedView()
            clipView.addSubview(stack)
            scroll.documentView = clipView
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: clipView.bottomAnchor, constant: -8),
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
                // Floors, matching the Settings tab (Nov 18).
                scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
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

    // One excluded-app row, shared by the standalone window
    // and the Settings tab so the two lists can never drift
    // apart: the app's own icon (Nov 18 — the rows were bare
    // name + Remove, the only list in the app with no icons),
    // its name, and Remove.
    func exclusionRow(for bundleID: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let iconView = NSImageView()
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16)
            ])
            row.addArrangedSubview(iconView)
        }
        let label = NSTextField(labelWithString: appName(forBundleID: bundleID))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeExcludedApp(_:)))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.identifier = NSUserInterfaceItemIdentifier(bundleID)
        row.addArrangedSubview(label)
        row.addArrangedSubview(remove)
        return row
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
            stack.addArrangedSubview(exclusionRow(for: bundleID))
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
        refreshSettingsExclusionsList()
    }

    @objc func removeExcludedApp(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        store.excludedApps = store.excludedApps.filter { $0 != bundleID }
        refreshExclusionsList()
        refreshSettingsExclusionsList()
    }

    // MARK: Settings

    // One Settings window (roadmap #14, v2.7.0) gathering what
    // used to live only in the ••• menu: General (pause, history
    // limit, panel size, clear history), Appearance (theme,
    // menu bar icon, Reduce Transparency), Updates (version,
    // check now, status),
    // and Excluded Apps (the same list the standalone window
    // edits — both views write the one store list). Every control
    // calls the existing actions/keys, so the menus and Settings
    // can never disagree. Modelled on StayAwake's tabbed
    // Settings, which Femi approved Nov 15. Fixed size, not
    // persisted — same trade-off as the other auxiliary windows.
    @objc func showSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        syncSettingsControls()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Settings live-sync (v2.16.0): the controls used to refresh
    // only when the window was (re)opened, so changing pause,
    // theme, the menu-bar icon or Reduce Transparency from a
    // menu while Settings sat open left it showing stale values
    // until it was closed and reopened. Re-sync whenever the
    // window becomes key — clicking back into it is exactly
    // when a stale value would be read. (The Settings window
    // shares this delegate with the panel; the panel's own
    // delegate methods guard on the window's identity, and so
    // does this one.)
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow else { return }
        syncSettingsControls()
    }

    private func settingsStack(in view: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            // Equality, not ≤ (Nov 18): with an inequality the
            // stack's width is ambiguous at measure time, and
            // the Updates tab's wrapping note label came out
            // one line tall with its text clipped mid-sentence
            // (Femi's Loom) despite empty space below it.
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
        return stack
    }

    private func buildSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ClipKeep Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Above the panel (v2.13.0, Femi's screenshot): the
        // panel floats (.floating), so a normal-level window
        // opens UNDER it wherever they overlap — Settings,
        // Preview and Excluded Apps all float at the panel's
        // level, and ordering front then puts them on top.
        window.level = .floating
        // Pin the content size (Nov 18, Femi's Loom): the
        // window is fixed-size, so AppKit takes its size from
        // the selected tab's fitting size — and the Excluded
        // Apps tab's fitting size collapses (its scroll view's
        // content width is defined circularly, with no minimum
        // anywhere). Selecting that tab shrank the whole
        // window to a narrow black strip with every control
        // clipped. Min = max = the intended size, so no tab
        // can resize the window.
        window.contentMinSize = NSSize(width: 520, height: 380)
        window.contentMaxSize = NSSize(width: 520, height: 380)
        let tabs = NSTabView()
        window.contentView = tabs

        // General
        let general = NSView()
        let g = settingsStack(in: general)
        let pause = NSButton(checkboxWithTitle: "Pause capture (stop recording new copies)", target: self, action: #selector(settingsPauseToggled(_:)))
        settingsPauseCheckbox = pause
        g.addArrangedSubview(pause)
        let clickPref = NSButton(checkboxWithTitle: "Paste on single click (off = double-click pastes)", target: self, action: #selector(settingsClickToggled(_:)))
        settingsClickCheckbox = clickPref
        g.addArrangedSubview(clickPref)
        let limitRow = NSStackView()
        limitRow.orientation = .horizontal
        limitRow.spacing = 8
        limitRow.addArrangedSubview(NSTextField(labelWithString: "History limit:"))
        let limitPopup = NSPopUpButton()
        limitPopup.addItems(withTitles: ["200 clips", "500 clips", "1000 clips", "No limit"])
        for (i, value) in [200, 500, 1000, 0].enumerated() {
            limitPopup.item(at: i)?.representedObject = value
        }
        limitPopup.target = self
        limitPopup.action = #selector(settingsLimitChanged(_:))
        settingsLimitPopup = limitPopup
        limitRow.addArrangedSubview(limitPopup)
        g.addArrangedSubview(limitRow)
        // Keep-for period (v2.19.0): the time-based companion
        // to the history limit, same row shape and wiring.
        let retentionRow = NSStackView()
        retentionRow.orientation = .horizontal
        retentionRow.spacing = 8
        retentionRow.addArrangedSubview(NSTextField(labelWithString: "Keep clips for:"))
        let retentionPopup = NSPopUpButton()
        retentionPopup.addItems(withTitles: ["Forever", "7 days", "30 days", "90 days", "180 days", "1 year"])
        for (i, value) in [0, 7, 30, 90, 180, 365].enumerated() {
            retentionPopup.item(at: i)?.representedObject = value
        }
        retentionPopup.target = self
        retentionPopup.action = #selector(settingsRetentionChanged(_:))
        settingsRetentionPopup = retentionPopup
        retentionRow.addArrangedSubview(retentionPopup)
        g.addArrangedSubview(retentionRow)
        // Storage readout + one-off purge (v2.19.0): how much
        // history there is and what it costs on disk, kept
        // current by syncSettingsControls, and a button that
        // runs the retention sweep on demand.
        let storageLabel = NSTextField(labelWithString: "")
        storageLabel.font = NSFont.systemFont(ofSize: 12)
        storageLabel.textColor = .secondaryLabelColor
        settingsStorageLabel = storageLabel
        g.addArrangedSubview(storageLabel)
        let purge = NSButton(title: "Purge Older Clips", target: self, action: #selector(purgeOlderClips))
        purge.bezelStyle = .rounded
        settingsPurgeButton = purge
        g.addArrangedSubview(purge)
        let reset = NSButton(title: "Reset Panel Size", target: self, action: #selector(resetPanelSize))
        reset.bezelStyle = .rounded
        g.addArrangedSubview(reset)
        let clear = NSButton(title: "Clear History", target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        g.addArrangedSubview(clear)
        let gItem = NSTabViewItem()
        gItem.label = "General"
        gItem.view = general
        tabs.addTabViewItem(gItem)

        // Appearance
        let appearance = NSView()
        let a = settingsStack(in: appearance)
        a.addArrangedSubview(NSTextField(labelWithString: "Panel theme:"))
        let themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: panelThemes.map { $0.name })
        for (i, theme) in panelThemes.enumerated() {
            themePopup.item(at: i)?.representedObject = theme.id
        }
        themePopup.target = self
        themePopup.action = #selector(settingsThemeChanged(_:))
        settingsThemePopup = themePopup
        a.addArrangedSubview(themePopup)
        a.addArrangedSubview(NSTextField(labelWithString: "Menu bar icon:"))
        // Radio buttons instead of a popup (v2.16.2, at Femi's
        // request — with a dropdown the other treatments stayed
        // hidden; as radios all five stay visible, so the current
        // choice reads at a glance). The same five treatments as
        // ••• → Menu Bar Icon, from the one shared list (unified
        // in v2.16.0; the Settings control itself arrived in
        // v2.15.7 as a popup).
        let iconRadioStack = NSStackView()
        iconRadioStack.orientation = .vertical
        iconRadioStack.alignment = .leading
        iconRadioStack.spacing = 6
        settingsIconRadios = []
        for style in Self.menuBarIconStyles {
            let rb = NSButton(radioButtonWithTitle: style.title, target: self, action: #selector(settingsIconRadioChanged(_:)))
            rb.identifier = NSUserInterfaceItemIdentifier(style.id)
            settingsIconRadios.append(rb)
            iconRadioStack.addArrangedSubview(rb)
        }
        a.addArrangedSubview(iconRadioStack)
        let rt = NSButton(checkboxWithTitle: "Reduce Transparency (solid panel background)", target: self, action: #selector(settingsRTToggled(_:)))
        settingsRTCheckbox = rt
        a.addArrangedSubview(rt)
        let aItem = NSTabViewItem()
        aItem.label = "Appearance"
        aItem.view = appearance
        tabs.addTabViewItem(aItem)

        // Updates
        let updates = NSView()
        let u = settingsStack(in: updates)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "ClipKeep v\(version)")
        versionLabel.font = NSFont.boldSystemFont(ofSize: 13)
        u.addArrangedSubview(versionLabel)
        let status = NSTextField(wrappingLabelWithString: "")
        status.preferredMaxLayoutWidth = 440
        settingsUpdateStatus = status
        u.addArrangedSubview(status)
        let check = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdateClicked))
        check.bezelStyle = .rounded
        u.addArrangedSubview(check)
        let note = NSTextField(wrappingLabelWithString: "Updates are checked against a small public version feed. Since v2.6.1, downloads are verified against the feed's SHA-256 checksum before installing.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 440
        u.addArrangedSubview(note)
        let uItem = NSTabViewItem()
        uItem.label = "Updates"
        uItem.view = updates
        tabs.addTabViewItem(uItem)

        // Excluded Apps — same list layout as the standalone window.
        let excluded = NSView()
        let eStack = NSStackView()
        eStack.orientation = .vertical
        eStack.alignment = .leading
        eStack.spacing = 6
        eStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Flipped document view + sizing equality — same fix as
        // the standalone window above (v2.12.0); this tab copied
        // the broken construction, so the list rendered from the
        // bottom here too.
        let clipView = FlippedView()
        clipView.addSubview(eStack)
        scroll.documentView = clipView
        NSLayoutConstraint.activate([
            eStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 8),
            eStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -8),
            eStack.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 8),
            eStack.bottomAnchor.constraint(equalTo: clipView.bottomAnchor, constant: -8),
            clipView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        excluded.addSubview(scroll)
        let addButton = NSButton(title: "Add app…", target: self, action: #selector(addExcludedApp))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        excluded.addSubview(addButton)
        let eNote = NSTextField(labelWithString: "Copies from these apps are never recorded.")
        eNote.font = NSFont.systemFont(ofSize: 11)
        eNote.textColor = .secondaryLabelColor
        eNote.translatesAutoresizingMaskIntoConstraints = false
        excluded.addSubview(eNote)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: excluded.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: excluded.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: excluded.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),
            // Floors so this tab's fitting size can never
            // collapse (see the window pin in buildSettingsWindow).
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            addButton.leadingAnchor.constraint(equalTo: excluded.leadingAnchor, constant: 10),
            addButton.bottomAnchor.constraint(equalTo: excluded.bottomAnchor, constant: -10),
            eNote.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 10),
            eNote.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            eNote.trailingAnchor.constraint(lessThanOrEqualTo: excluded.trailingAnchor, constant: -10)
        ])
        settingsExclusionsStack = eStack
        let eItem = NSTabViewItem()
        eItem.label = "Excluded Apps"
        eItem.view = excluded
        tabs.addTabViewItem(eItem)

        // Account (v2.18.0) — the Form design: the same
        // sign-in controls and identity rows the panel's Sync
        // view carries, wired to the one AuthManager.
        // Signed-out and signed-in are two stacked containers;
        // refreshSettingsAccount swaps them.
        let account = NSView()
        let acct = settingsStack(in: account)

        let acctOut = NSStackView()
        acctOut.orientation = .vertical
        acctOut.alignment = .leading
        acctOut.spacing = 10
        let acctHeadline = NSTextField(labelWithString: "ClipKeep Account")
        acctHeadline.font = NSFont.boldSystemFont(ofSize: 13)
        acctOut.addArrangedSubview(acctHeadline)
        let acctExplainer = NSTextField(wrappingLabelWithString: "Sign in to sync your clipboard history across this Mac, Android, iOS and Web. Sensitive clips never sync — and signed out, ClipKeep stays fully local.")
        acctExplainer.font = NSFont.systemFont(ofSize: 12)
        acctExplainer.textColor = .secondaryLabelColor
        acctExplainer.preferredMaxLayoutWidth = 440
        acctOut.addArrangedSubview(acctExplainer)
        let acctGoogle = socialButton(title: "Sign in with Google", background: .white,
                                      foreground: NSColor(white: 0.2, alpha: 1),
                                      bordered: true, action: #selector(signInGoogleClicked(_:)))
        acctOut.addArrangedSubview(acctGoogle)
        let acctEmailField = NSTextField()
        acctEmailField.placeholderString = "Email"
        acctEmailField.font = NSFont.systemFont(ofSize: 12.5)
        acctEmailField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        settingsEmailField = acctEmailField
        // Return in the field is the button (v2.18.1), same
        // as the panel's field.
        acctEmailField.target = self
        acctEmailField.action = #selector(settingsEmailClicked(_:))
        let acctEmailButton = NSButton(title: "Email me a code", target: self, action: #selector(settingsEmailClicked(_:)))
        acctEmailButton.bezelStyle = .rounded
        settingsEmailButton = acctEmailButton
        let acctEmailRow = NSStackView(views: [acctEmailField, acctEmailButton])
        acctEmailRow.orientation = .horizontal
        acctEmailRow.alignment = .centerY
        acctEmailRow.spacing = 8
        acctOut.addArrangedSubview(acctEmailRow)
        // Native email code (v2.19.3): the panel card's
        // flow in compact form — a send error line, then
        // the code block while a round trip is live.
        let acctEmailError = NSTextField(wrappingLabelWithString: "")
        acctEmailError.font = NSFont.systemFont(ofSize: 11.5)
        acctEmailError.textColor = .systemRed
        acctEmailError.preferredMaxLayoutWidth = 440
        acctEmailError.isHidden = true
        settingsEmailErrorLabel = acctEmailError
        acctOut.addArrangedSubview(acctEmailError)
        let acctOTPLabel = NSTextField(wrappingLabelWithString: "")
        acctOTPLabel.font = NSFont.systemFont(ofSize: 12)
        acctOTPLabel.preferredMaxLayoutWidth = 440
        settingsOTPLabel = acctOTPLabel
        let acctOTPField = NSTextField()
        acctOTPField.placeholderString = "6-digit code"
        acctOTPField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        acctOTPField.alignment = .center
        acctOTPField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        acctOTPField.target = self
        acctOTPField.action = #selector(settingsOTPConfirmClicked(_:))
        settingsOTPField = acctOTPField
        let acctOTPConfirm = NSButton(title: "Sign in", target: self, action: #selector(settingsOTPConfirmClicked(_:)))
        acctOTPConfirm.bezelStyle = .rounded
        settingsOTPConfirmButton = acctOTPConfirm
        let acctOTPCodeRow = NSStackView(views: [acctOTPField, acctOTPConfirm])
        acctOTPCodeRow.orientation = .horizontal
        acctOTPCodeRow.alignment = .centerY
        acctOTPCodeRow.spacing = 8
        let acctOTPResend = NSButton(title: "Resend", target: self, action: #selector(otpResendClicked))
        acctOTPResend.bezelStyle = .rounded
        acctOTPResend.controlSize = .small
        settingsOTPResendButton = acctOTPResend
        let acctOTPCancel = NSButton(title: "Cancel", target: self, action: #selector(otpCancelClicked))
        acctOTPCancel.bezelStyle = .rounded
        acctOTPCancel.controlSize = .small
        let acctOTPQuietRow = NSStackView(views: [acctOTPResend, acctOTPCancel])
        acctOTPQuietRow.orientation = .horizontal
        acctOTPQuietRow.alignment = .centerY
        acctOTPQuietRow.spacing = 8
        let acctOTPError = NSTextField(wrappingLabelWithString: "")
        acctOTPError.font = NSFont.systemFont(ofSize: 11.5)
        acctOTPError.textColor = .systemRed
        acctOTPError.preferredMaxLayoutWidth = 440
        acctOTPError.isHidden = true
        settingsOTPErrorLabel = acctOTPError
        let acctOTPBlock = NSStackView()
        acctOTPBlock.orientation = .vertical
        acctOTPBlock.alignment = .leading
        acctOTPBlock.spacing = 8
        acctOTPBlock.addArrangedSubview(acctOTPLabel)
        acctOTPBlock.addArrangedSubview(acctOTPCodeRow)
        acctOTPBlock.addArrangedSubview(acctOTPQuietRow)
        acctOTPBlock.addArrangedSubview(acctOTPError)
        acctOTPBlock.isHidden = true
        settingsOTPBlock = acctOTPBlock
        acctOut.addArrangedSubview(acctOTPBlock)
        let acctReassurance = NSTextField(labelWithString: "ClipKeep stays fully local if you never sign in.")
        acctReassurance.font = NSFont.systemFont(ofSize: 11)
        acctReassurance.textColor = .secondaryLabelColor
        acctOut.addArrangedSubview(acctReassurance)
        acct.addArrangedSubview(acctOut)
        settingsAccountSignedOutView = acctOut

        let acctIn = NSStackView()
        acctIn.orientation = .vertical
        acctIn.alignment = .leading
        acctIn.spacing = 10
        let acctAvatar = NSView()
        acctAvatar.wantsLayer = true
        acctAvatar.layer?.cornerRadius = 18
        acctAvatar.layer?.backgroundColor = NSColor(red: 0.894, green: 0.341, blue: 0.180, alpha: 1).cgColor
        acctAvatar.widthAnchor.constraint(equalToConstant: 36).isActive = true
        acctAvatar.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let acctAvatarLabel = NSTextField(labelWithString: "")
        acctAvatarLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        acctAvatarLabel.textColor = .white
        acctAvatarLabel.alignment = .center
        acctAvatarLabel.translatesAutoresizingMaskIntoConstraints = false
        acctAvatar.addSubview(acctAvatarLabel)
        NSLayoutConstraint.activate([
            acctAvatarLabel.centerXAnchor.constraint(equalTo: acctAvatar.centerXAnchor),
            acctAvatarLabel.centerYAnchor.constraint(equalTo: acctAvatar.centerYAnchor)
        ])
        settingsAccountAvatarLabel = acctAvatarLabel
        let acctName = NSTextField(labelWithString: "")
        acctName.font = NSFont.boldSystemFont(ofSize: 13)
        settingsAccountNameLabel = acctName
        let acctEmail = NSTextField(labelWithString: "")
        acctEmail.font = NSFont.systemFont(ofSize: 11.5)
        acctEmail.textColor = .secondaryLabelColor
        settingsAccountEmailLabel = acctEmail
        let acctIdentityText = NSStackView(views: [acctName, acctEmail])
        acctIdentityText.orientation = .vertical
        acctIdentityText.alignment = .leading
        acctIdentityText.spacing = 1
        let acctHeader = NSStackView(views: [acctAvatar, acctIdentityText])
        acctHeader.orientation = .horizontal
        acctHeader.alignment = .centerY
        acctHeader.spacing = 10
        acctIn.addArrangedSubview(acctHeader)
        let acctSync = NSButton(checkboxWithTitle: "Sync history across devices", target: self, action: #selector(settingsSyncToggled(_:)))
        settingsSyncCheckbox = acctSync
        acctIn.addArrangedSubview(acctSync)
        let acctStatusLabel = NSTextField(labelWithString: "")
        settingsSyncStatusLabel = acctStatusLabel
        let acctStatusRow = NSStackView(views: [NSTextField(labelWithString: "Sync status:"), acctStatusLabel])
        acctStatusRow.orientation = .horizontal
        acctStatusRow.spacing = 8
        acctIn.addArrangedSubview(acctStatusRow)
        acctIn.addArrangedSubview(NSTextField(labelWithString: "Devices: This Mac (this device)"))
        let acctConnectGoogle = NSButton(title: "Connect Google", target: self, action: #selector(signInGoogleClicked(_:)))
        acctConnectGoogle.bezelStyle = .rounded
        let acctConnectRow = NSStackView(views: [acctConnectGoogle])
        acctConnectRow.orientation = .horizontal
        acctConnectRow.spacing = 8
        acctIn.addArrangedSubview(acctConnectRow)
        let acctSignOut = NSButton(title: "Sign Out", target: self, action: #selector(signOutClicked))
        acctSignOut.bezelStyle = .rounded
        acctIn.addArrangedSubview(acctSignOut)
        let acctDelete = NSButton(title: "Delete Account…", target: self, action: #selector(deleteAccountClicked))
        // Delete wears the panel's treatment (v2.18.1):
        // borderless red text on its own row, not a rounded
        // button inviting a stray click beside Sign Out.
        acctDelete.bezelStyle = .inline
        acctDelete.isBordered = false
        acctDelete.contentTintColor = .systemRed
        acctDelete.font = NSFont.systemFont(ofSize: 12)
        acctIn.addArrangedSubview(acctDelete)
        acctIn.setCustomSpacing(16, after: acctSignOut)
        acct.addArrangedSubview(acctIn)
        settingsAccountSignedInView = acctIn

        // The social button spans the tab's content width.
        acctGoogle.widthAnchor.constraint(equalTo: acctOut.widthAnchor).isActive = true

        let acctItem = NSTabViewItem()
        acctItem.label = "Account"
        acctItem.view = account
        tabs.addTabViewItem(acctItem)

        settingsWindow = window
    }

    func syncSettingsControls() {
        settingsPauseCheckbox?.state = capturePaused ? .on : .off
        settingsClickCheckbox?.state = pasteOnSingleClick ? .on : .off
        if let popup = settingsLimitPopup {
            for i in 0..<popup.numberOfItems where (popup.item(at: i)?.representedObject as? Int) == store.historyLimit {
                popup.selectItem(at: i)
            }
        }
        if let popup = settingsRetentionPopup {
            for i in 0..<popup.numberOfItems where (popup.item(at: i)?.representedObject as? Int) == store.retentionDays {
                popup.selectItem(at: i)
            }
        }
        if let label = settingsStorageLabel {
            label.stringValue = storageSummaryText()
        }
        refreshPurgeButton()
        if let popup = settingsThemePopup {
            for i in 0..<popup.numberOfItems where (popup.item(at: i)?.representedObject as? String) == currentTheme.id {
                popup.selectItem(at: i)
            }
        }
        for rb in settingsIconRadios {
            rb.state = rb.identifier?.rawValue == menuBarIconStyle ? .on : .off
        }
        settingsRTCheckbox?.state = UserDefaults.standard.bool(forKey: "ClipKeepReduceTransparency") ? .on : .off
        refreshSettingsUpdateStatus()
        refreshSettingsExclusionsList()
        refreshSettingsAccount()
    }

    // The Account tab mirrors the one AuthManager (v2.18.0):
    // signed-out shows the sign-in controls, signed-in the
    // identity, the sync toggle (the same ClipKeepSyncEnabled
    // key the panel's hero switch writes), status, devices,
    // the Connect rows and the account actions.
    func refreshSettingsAccount() {
        guard let out = settingsAccountSignedOutView, let inn = settingsAccountSignedInView else { return }
        let identity = auth.session?.identity
        out.isHidden = identity != nil
        inn.isHidden = identity == nil
        if let identity {
            settingsAccountAvatarLabel?.stringValue = accountInitial(for: identity)
            settingsAccountNameLabel?.stringValue = accountDisplayName(identity)
            settingsAccountEmailLabel?.stringValue = identity.email
        }
        settingsSyncCheckbox?.state = syncEnabled ? .on : .off
        settingsSyncStatusLabel?.stringValue = syncStatusText()

        // Native email code (v2.19.3), mirroring the panel
        // card's refresh: same phase, same copy, compact
        // rows. The label is set on the awaiting-code
        // transition only — confirming carries no
        // destination to re-read it from.
        let phase = auth.otpPhase
        settingsEmailButton?.title = phase == .sending ? "Sending…" : "Email me a code"
        settingsEmailButton?.isEnabled = phase != .sending && phase != .confirming
        switch phase {
        case .awaitingCode(_, let destination):
            settingsOTPLabel?.stringValue = "Enter the 6-digit code sent to \(destination)"
            settingsOTPBlock?.isHidden = false
        case .confirming:
            settingsOTPBlock?.isHidden = false
        case .idle, .sending:
            settingsOTPBlock?.isHidden = true
        }
        settingsOTPConfirmButton?.title = phase == .confirming ? "Signing in…" : "Sign in"
        settingsOTPConfirmButton?.isEnabled = phase != .confirming
        var otpAwaiting = false
        if case .awaitingCode = phase { otpAwaiting = true }
        settingsOTPResendButton?.isEnabled = otpAwaiting
        let otpErrorText = auth.otpError ?? ""
        settingsOTPErrorLabel?.stringValue = otpErrorText
        settingsOTPErrorLabel?.isHidden = otpErrorText.isEmpty || (settingsOTPBlock?.isHidden ?? true)
        settingsEmailErrorLabel?.stringValue = phase == .idle ? otpErrorText : ""
        settingsEmailErrorLabel?.isHidden = !(phase == .idle && !otpErrorText.isEmpty)
    }

    func syncStatusText() -> String {
        if case .error(let message) = auth.state { return "Error — \(message)" }
        guard auth.session != nil else { return "Not signed in" }
        guard syncEnabled else { return "Signed in — sync off" }
        switch syncEngine.state {
        case .syncing: return "Syncing…"
        case .offline: return "Offline — will retry"
        case .signInExpired: return "Sign-in expired — sign in again to resume sync"
        case .idle:
            if let last = syncEngine.displayLastSyncAt {
                return "Up to date — last synced \(relativeTimeString(last))"
            }
            return "Signed in — not synced yet"
        }
    }

    @objc func settingsSyncToggled(_ sender: NSButton) {
        auth.anchorWindow = sender.window
        syncEnabledChanged(sender.state == .on)
        sender.state = syncEnabled ? .on : .off
    }

    func refreshSettingsUpdateStatus() {
        guard let label = settingsUpdateStatus else { return }
        if let upd = availableUpdate {
            label.stringValue = "ClipKeep \(upd.version) is available — open the panel and use Install in the update strip."
        } else if Date() < updateSnoozedUntil {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            label.stringValue = "Update notices are snoozed until \(f.string(from: updateSnoozedUntil))."
        } else {
            label.stringValue = "No update is waiting. ClipKeep checks at launch; you can check again any time."
        }
    }

    func refreshSettingsExclusionsList() {
        guard let stack = settingsExclusionsStack else { return }
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        if store.excludedApps.isEmpty {
            let label = NSTextField(labelWithString: "No apps excluded yet.")
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
        }
        for bundleID in store.excludedApps {
            stack.addArrangedSubview(exclusionRow(for: bundleID))
        }
    }

    @objc func settingsPauseToggled(_ sender: NSButton) {
        if (sender.state == .on) != capturePaused { togglePause() }
        sender.state = capturePaused ? .on : .off
    }

    @objc func settingsLimitChanged(_ sender: NSPopUpButton) {
        if let mi = sender.selectedItem { limitChosen(mi) }
    }

    @objc func settingsRetentionChanged(_ sender: NSPopUpButton) {
        if let mi = sender.selectedItem { retentionChosen(mi) }
        // Picking a period trims immediately, so the storage
        // line and the purge button follow in the same beat.
        settingsStorageLabel?.stringValue = storageSummaryText()
        refreshPurgeButton()
    }

    // The purge only has meaning against a period: at
    // Forever it disables and its tooltip says why (v2.19.0).
    func refreshPurgeButton() {
        guard let purge = settingsPurgeButton else { return }
        purge.isEnabled = store.retentionDays > 0
        purge.toolTip = store.retentionDays > 0
            ? "Delete unpinned, unboarded clips older than the keep-for period, now"
            : "Choose a keep-for period above to purge clips by age"
    }

    // The Settings storage line (v2.19.0): clip count plus
    // the history store's on-disk size.
    func storageSummaryText() -> String {
        let count = store.items.count
        let size = ByteCountFormatter.string(fromByteCount: store.diskUsageBytes, countStyle: .file)
        return "History: \(count) clip\(count == 1 ? "" : "s") · \(size) on disk"
    }

    @objc func purgeOlderClips() {
        let days = store.retentionDays
        let removed = store.purgePastRetention()
        if removed > 0 {
            for stone in store.tombstones { noteSyncMutation(stone.id) }
        }
        refreshList()
        syncSettingsControls()
        // The readout reports the outcome, so the click never
        // feels dead (the v2.18.1 lesson); the next Settings
        // sync restores the plain summary.
        if let label = settingsStorageLabel {
            label.stringValue = removed > 0
                ? "Purged \(removed) clip\(removed == 1 ? "" : "s") older than \(days) days — \(storageSummaryText())"
                : "Nothing older than \(days) days to purge — \(storageSummaryText())"
        }
    }

    @objc func settingsThemeChanged(_ sender: NSPopUpButton) {
        if let mi = sender.selectedItem { themeChosen(mi) }
    }

    @objc func settingsIconRadioChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        for rb in settingsIconRadios { rb.state = rb == sender ? .on : .off }
        UserDefaults.standard.set(id, forKey: "ClipKeepMenuBarIcon")
        refreshStatusItem()
    }

    @objc func settingsRTToggled(_ sender: NSButton) {
        let key = "ClipKeepReduceTransparency"
        if (sender.state == .on) != UserDefaults.standard.bool(forKey: key) { toggleReduceTransparency() }
        sender.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
    }

    @objc func settingsClickToggled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "ClipKeepPasteOnSingleClick")
    }

    // Flush any debounced history save before the process goes
    // (v2.12.0) — quitting inside the 0.25s window, including
    // the updater's swap-and-relaunch, must lose nothing.
    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
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
        add("Settings…", #selector(showSettings))
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
        checkForUpdate(manual: true)
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            // Reopening always lands on the feed (v2.18.0):
            // the Sync view is a mode, not a place the panel
            // remembers being in.
            if syncOpen { setSyncView(open: false) }
            refreshList()
            applyFixedPanelFrame()
            panel.makeKeyAndOrderFront(nil)
            // Stage Manager can clamp the frame as the panel
            // appears in its stage; if it did, re-apply the fixed
            // frame once, asynchronously (never synchronously from
            // inside windowDidResize — see applyFixedPanelFrame).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel.isVisible else { return }
                if self.panel.frame != self.defaultPanelFrame() {
                    self.applyFixedPanelFrame()
                }
                // First-show rebuild (v2.15.6): the refreshList
                // above runs before the window is on screen, so on
                // the FIRST open after a launch the rows are built
                // and measured against frames that don't exist yet
                // — Femi's Nov 18 screenshot showed the result:
                // unselected cards with the header band pushed
                // ~62pt down and the row stretched, while every
                // later rebuild (filter toggles) rendered fine.
                // Rebuilding once the panel is actually displayed
                // reproduces that known-good state.
                // v2.18.1: only the first open needs it — the
                // frames it measures against exist from then on,
                // and on later opens the identical second rebuild
                // was pure delay (finding F1). If first-open
                // cards ever render mis-measured again, this gate
                // is the first suspect.
                if !self.hasShownPanelOnce {
                    self.hasShownPanelOnce = true
                    self.refreshList()
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            // v2.16.4: the panel opens with the FEED holding
            // focus, not the search field — Femi reported the
            // search field grabbing focus on open fought the
            // double-click paste (v2.16.3). Nothing is lost:
            // typing still jumps to search via the key
            // monitor, and ⌘F focuses the field explicitly.
            panel.makeFirstResponder(scrollView)
            playIntroIfNeeded()
            // Opening the panel is a sync trigger when the
            // last cycle is stale (the engine decides).
            syncEngine.notePanelOpened()
        }
    }

    // MARK: Launch intro (v2.13.0, Femi's pick A)
    //
    // A branded beat on the FIRST panel open after a launch —
    // and only there. Quitting and relaunching gets the intro;
    // ordinary reopens stay instant, because a menu-bar app's
    // panel is opened dozens of times a day and an intro on
    // every open would be a tax, not a flourish. The overlay
    // carries the app icon, the name and the version over the
    // panel's own frost, holds briefly while the cards stagger
    // in beneath it, then crossfades away. Any click or
    // keypress skips it. Reduce Transparency drops the stagger
    // and shortens the hold. Process-lifetime state only —
    // nothing is persisted.
    var introPlayedThisLaunch = false
    var introOverlay: NSView?
    var introWorkItems: [DispatchWorkItem] = []

    func playIntroIfNeeded() {
        guard !introPlayedThisLaunch else { return }
        introPlayedThisLaunch = true
        guard let host = panel.contentView else { return }
        let reduce = UserDefaults.standard.bool(forKey: "ClipKeepReduceTransparency")

        let overlay = NSVisualEffectView()
        overlay.material = .hudWindow
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // The theme tint over the frost, matching the panel the
        // intro reveals (tintView carries the current theme's).
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = tintView.layer?.backgroundColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(tint)

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(icon)
        let name = NSTextField(labelWithString: "ClipKeep")
        name.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
        name.textColor = .labelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(name)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let ver = NSTextField(labelWithString: version.isEmpty ? "" : "v\(version)")
        ver.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        ver.textColor = .secondaryLabelColor
        ver.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(ver)

        // A full-size click layer on top: any click skips.
        let skip = ClickView()
        skip.onClick = { [weak self] _ in self?.dismissIntro() }
        skip.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(skip)

        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            tint.topAnchor.constraint(equalTo: overlay.topAnchor),
            tint.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 92),
            icon.heightAnchor.constraint(equalToConstant: 92),
            icon.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -34),
            name.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            ver.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            ver.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            skip.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            skip.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            skip.topAnchor.constraint(equalTo: overlay.topAnchor),
            skip.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
        ])
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        introOverlay = overlay

        // The cards stagger in beneath the overlay as it lifts.
        if !reduce {
            for (i, card) in (listStack?.arrangedSubviews ?? []).enumerated() {
                card.alphaValue = 0
                let work = DispatchWorkItem { [weak card] in
                    guard let card else { return }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.3
                        card.animator().alphaValue = 1
                    }
                }
                introWorkItems.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 + Double(min(i, 10)) * 0.05, execute: work)
            }
        }
        let dismiss = DispatchWorkItem { [weak self] in self?.dismissIntro() }
        introWorkItems.append(dismiss)
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0.7 : 1.15), execute: dismiss)
    }

    func dismissIntro() {
        guard let overlay = introOverlay else { return }
        introOverlay = nil
        for work in introWorkItems { work.cancel() }
        introWorkItems.removeAll()
        // Any card still mid-stagger lands fully visible.
        for card in listStack?.arrangedSubviews ?? [] { card.alphaValue = 1 }
        if UserDefaults.standard.bool(forKey: "ClipKeepReduceTransparency") {
            overlay.removeFromSuperview()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                overlay.animator().alphaValue = 0
            }, completionHandler: { overlay.removeFromSuperview() })
        }
    }

    // MARK: Keyboard navigation (roadmap #2, v2.9.0)
    //
    // A selection rides the horizontal feed, drawn as the theme
    // accent outline — the only outline in the feed (v2.13.0:
    // the first card's separate "current clip" outline was
    // retired; selection wins). Keys are
    // handled in the local monitor below, alongside the existing
    // Esc / ⌘F / ⌘1–9 handling: ↑/↓ always move the selection
    // (they mean nothing in a one-line search field), ←/→ and ⌫
    // join them only while the search is empty so text editing
    // keeps its keys, Enter pastes, Space previews, and typing
    // a printable character with the search unfocused jumps
    // focus to the search field.
    var selectedItemID: String?

    func selectedItem() -> ClipItem? {
        guard let id = selectedItemID else { return nil }
        return visibleItems().first { $0.id == id }
    }

    func applySelectionBorders() {
        guard let stack = listStack else { return }
        // One outline only (v2.13.0, Femi's call from his
        // Nov 18 keyboard-nav Loom): the outline always means
        // the selection. Until now the first card also kept a
        // permanent blue "current clip" outline, so two
        // near-identical outlines sat in the feed meaning
        // different things. The current clip is identified by
        // its position and its ⌘1 badge instead.
        for card in stack.arrangedSubviews {
            guard let layer = card.layer else { continue }
            if card.identifier?.rawValue == selectedItemID {
                layer.borderColor = currentTheme.accent.cgColor
                layer.borderWidth = 2.5
            } else {
                layer.borderColor = currentTheme.cardBorder.cgColor
                layer.borderWidth = 1
            }
        }
    }

    func moveSelection(by delta: Int) {
        let items = visibleItems()
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedItemID } ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        selectedItemID = items[next].id
        applySelectionBorders()
        if let card = cardView(for: items[next]) {
            card.scrollToVisible(card.bounds)
        }
    }

    func deleteSelected() {
        guard let item = selectedItem() else { return }
        store.remove(item)
        store.save()
        refreshList()
    }

    // ⌘1–⌘9 quick-paste while the panel is open: pastes the nth
    // visible clip, matching the number badges on the rows.
    func installKeyMonitor() {
        let digitCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return event }
            // While the launch intro is up, any key skips it
            // (v2.13.0) — and is consumed, so the keypress that
            // dismisses the intro doesn't also act on the feed.
            if self.introOverlay != nil {
                self.dismissIntro()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Esc in the Sync view returns to the feed first
            // (v2.18.0) — before the clear-search/close chain
            // below. While the Sync view is open the feed is
            // otherwise inert: every other key passes through
            // untouched (the invitation card's email field
            // needs its keystrokes, and the hidden feed must
            // not navigate, paste or delete behind the view).
            if self.syncOpen {
                if event.keyCode == 53, mods.isEmpty {
                    self.setSyncView(open: false)
                    return nil
                }
                return event
            }
            // Esc: clear a non-empty search first; only an Esc
            // with an already-empty search closes the panel.
            if event.keyCode == 53, mods.isEmpty {
                if !(self.searchField?.stringValue ?? "").isEmpty {
                    self.searchField.stringValue = ""
                    self.refreshList()
                } else {
                    self.panel.orderOut(nil)
                }
                return nil
            }
            // ⌘F jumps to the search field.
            if mods.contains(.command), !mods.contains(.shift),
               !mods.contains(.control), !mods.contains(.option),
               event.keyCode == 3 {
                self.panel.makeFirstResponder(self.searchField)
                return nil
            }
            // Keyboard navigation (roadmap #2) — plain keys
            // only; anything with ⌘/⌃/⌥ falls through to the
            // quick-paste digits and the system.
            if !mods.contains(.command), !mods.contains(.control), !mods.contains(.option) {
                let searching = !(self.searchField?.stringValue ?? "").isEmpty
                switch event.keyCode {
                case 126: // ↑
                    self.moveSelection(by: -1)
                    return nil
                case 125: // ↓
                    self.moveSelection(by: 1)
                    return nil
                case 123 where !searching: // ←
                    self.moveSelection(by: -1)
                    return nil
                case 124 where !searching: // →
                    self.moveSelection(by: 1)
                    return nil
                case 36, 76: // Return / keypad Enter pastes the selection
                    if let item = self.selectedItem() { self.pasteBack(item) }
                    return nil
                case 49 where !searching: // Space previews the selection
                    if let item = self.selectedItem() { self.openPreview(for: item) }
                    return nil
                case 51 where !searching, 117 where !searching: // ⌫ / forward delete — the where is repeated per pattern: a single trailing where binds only to the last pattern (the CI warning), which left ⌫ ungated while searching
                    self.deleteSelected()
                    return nil
                default:
                    break
                }
                // Typing with the search unfocused jumps to it:
                // focus the field, append the character, refilter.
                if self.panel.firstResponder !== self.searchField?.currentEditor(),
                   let chars = event.characters, !chars.isEmpty,
                   chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    self.panel.makeFirstResponder(self.searchField)
                    self.searchField.stringValue += chars
                    self.refreshList()
                    return nil
                }
            }
            guard mods.contains(.command),
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
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
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
        let panelStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey),
                            panelHotKey, GetApplicationEventTarget(), 0, &hotKeyRef)

        let stackHotKey = EventHotKeyID(signature: OSType(0x434B5053), id: 2) // 'CKPS'
        let stackStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey | controlKey),
                            stackHotKey, GetApplicationEventTarget(), 0, &stackHotKeyRef)

        // Check the results (v2.16.0): these used to be ignored,
        // so a failed registration — another app already owning
        // ⌘⇧V system-wide is the realistic cause — left the
        // shortcut silently dead, with nothing anywhere to say
        // why. Log it, and tell the user once, after launch
        // settles. A failed handler install kills both hotkeys;
        // a failed registration kills only its own.
        if handlerStatus != noErr || panelStatus != noErr || stackStatus != noErr {
            NSLog("ClipKeep: hot key registration failed (handler \(handlerStatus), panel \(panelStatus), stack \(stackStatus))")
            var failed: [String] = []
            if handlerStatus != noErr || panelStatus != noErr { failed.append("⌘⇧V (open ClipKeep)") }
            if handlerStatus != noErr || stackStatus != noErr { failed.append("⌃⌥⌘V (paste the next stack clip)") }
            let names = failed.joined(separator: " and ")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "A ClipKeep shortcut couldn't be registered"
                alert.informativeText = "macOS refused \(names) — another app may already be using it. You can still open ClipKeep from its menu bar icon."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}

// MARK: - Main
//
// The app entry. run-tests.sh builds the test runner from a
// copy of this file with everything from this MARK line to
// the end stripped out, so the entry never reaches the test
// compile (tests.swift supplies its own @main). Keep this
// section LAST in the file.
let delegate = AppController.shared
let app = NSApplication.shared
app.delegate = delegate
app.run()
