import Combine
import CoreImage
import Foundation
import UIKit

@MainActor
final class Model: ObservableObject {
    @Published private(set) var albums: [Album] = []
    @Published private(set) var scans: [Scan] = []
    @Published var activeAlbum: UUID?
    @Published var message = ""
    @Published var busy = false
    @Published var recentCount = 0
    @Published var reflectionID: UUID?
    @Published var reviewReady = false
    @Published var preferences: Preferences {
        didSet {
            if !Launch.isolated { UserDefaults.standard.set(try? JSONEncoder().encode(preferences), forKey: "preferences") }
        }
    }
    let purchases = Purchases()
    private(set) var archive: Archive?
    private let queue = DispatchQueue(label: "oldphoto.images", qos: .userInitiated)
    private var saveQueue: [Scan] = []
    private var savingPhotos = false
    private var finishedPages = Set<UUID>()
    private var started = false
    private var readingInitial = true

    init() {
        let stored = Launch.isolated ? nil : UserDefaults.standard.data(forKey: "preferences")
        preferences = stored.flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
    }

    var selectedAlbum: Album? { albums.first { $0.id == activeAlbum } ?? albums.first }
    func album(_ id: UUID) -> Album? { albums.first { $0.id == id } }
    func scan(_ id: UUID) -> Scan? { scans.first { $0.id == id } }
    func photos(in album: UUID) -> [Scan] { scans.filter { $0.albumID == album } }

    func prepare() async {
        guard !started else { return }
        started = true
        do {
            let loaded = try await work {
                let archive = try Archive.open(demo: Launch.isolated)
                #if DEBUG
                if Launch.demo && !Launch.has("-demo-empty") { try Demo.seed(archive) }
                #endif
                let albums = try archive.albums()
                return (archive, albums, try archive.records())
            }
            archive = loaded.0
            albums = loaded.1
            scans = loaded.2.photos
            let stored = Launch.isolated ? nil : UserDefaults.standard.string(forKey: "active-album").flatMap { UUID(uuidString: $0) }
            activeAlbum = albums.first { $0.id == stored }?.id ?? albums.first?.id
            if loaded.2.incomplete { message = L.t("archive_incomplete") }
            else if !Launch.isolated, let capacity = try? loaded.0.root.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                capacity < 1_000_000_000 { message = L.t("low_storage") }
        } catch { message = L.t("disk_error") }
        readingInitial = false
    }

    func select(_ album: Album) {
        activeAlbum = album.id
        if !Launch.isolated { UserDefaults.standard.set(album.id.uuidString, forKey: "active-album") }
    }

    func editAlbum(_ name: String, id: UUID?) {
        guard let archive else { return }
        var updated = albums
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index].name = String(name.prefix(80))
        } else {
            updated.append(Album(name: name.isEmpty ? L.f("album_number", String(updated.count + 1)) : String(name.prefix(80))))
        }
        do {
            try archive.writeAlbums(updated)
            albums = updated
            if id == nil, let last = albums.last { select(last) }
        } catch { message = L.t("disk_error") }
    }

    @discardableResult
    func ingest(_ data: Data, single: Bool) async -> Bool {
        guard let archive, let album = selectedAlbum, !busy else { return false }
        busy = true
        defer { busy = false }
        let strength = preferences.autoRestore && purchases.hasPro ? 0.70 : 0
        do {
            let result = try await work {
                try archive.ingest(data, album: album.id, single: single, strength: strength)
            }
            scans.append(contentsOf: result.photos)
            recentCount = result.photos.count
            reflectionID = result.photos.first(where: \.reflected)?.id
            if preferences.autoSave && !Launch.isolated { enqueueSave(result.photos) }
            if result.partial { message = L.t("partial_scan") }
            else { message = L.f("scanned_count", String(result.photos.count)) }
            if !preferences.autoSave || Launch.isolated { success() }
            return true
        } catch { message = L.t("capture_issue"); return false }
    }

    @discardableResult
    func recrop(_ id: UUID, corners: Corners? = nil, rotation: Int? = nil, border: Bool? = nil,
                strength: Double? = nil) async -> UUID? {
        guard let archive, var item = scan(id), !busy, corners?.valid != false else { return nil }
        if strength != nil && !purchases.hasPro { return nil }
        item.corners = corners ?? item.corners
        item.rotation = rotation ?? item.rotation
        item.whiteBorder = border ?? item.whiteBorder
        item.strength = strength ?? item.strength
        let keepGlare = corners == nil && rotation == nil && border == nil
        if !purchases.hasPro, !keepGlare, item.strength > 0 || item.glareReduced {
            item.id = UUID()
            item.strength = 0
            item.glareReduced = false
        }
        return await replaceImage(item, archive: archive, useStoredGlare: keepGlare)
    }

    func addFrame(from id: UUID, corners: Corners) async {
        guard let archive, let item = scan(id), !busy, corners.valid else { return }
        var new = Scan(albumID: item.albumID, pageID: item.pageID, corners: corners)
        new.strength = preferences.autoRestore && purchases.hasPro ? 0.70 : 0
        _ = await replaceImage(new, archive: archive, useStoredGlare: false)
    }

    func batchRestore(_ ids: [UUID]) async {
        guard purchases.hasPro, let archive, !busy else { return }
        busy = true
        defer { busy = false }
        for id in ids {
            guard var item = scan(id) else { continue }
            item.strength = 0.70
            let draft = item
            do { replace(try await work { try archive.render(draft) }) }
            catch { message = L.t("partial_scan"); return }
        }
        message = L.t("change_saved")
    }

    private func replaceImage(_ item: Scan, archive: Archive, useStoredGlare: Bool) async -> UUID? {
        busy = true
        defer { busy = false }
        do {
            let updated = try await work { try archive.render(item, useStoredGlare: useStoredGlare) }
            replace(updated)
            message = L.t("change_saved")
            return updated.id
        } catch { message = L.t("disk_error"); return nil }
    }

    func update(_ id: UUID, metadata: (inout Scan) -> Void) {
        guard let archive, var item = scan(id), !busy else { return }
        let before = item
        metadata(&item)
        guard before != item else { return }
        if before.date != item.date || before.people != item.people || before.place != item.place || before.note != item.note {
            item.saved = false
        }
        do { try archive.commit(item); replace(item) }
        catch { message = L.t("disk_error") }
    }

    func delete(_ id: UUID) {
        guard let archive, let item = scan(id), !busy else { return }
        if saveQueue.contains(where: { $0.id == id }) { message = L.t("please_wait"); return }
        do {
            try archive.remove(item, keepPage: scans.contains { $0.id != id && $0.pageID == item.pageID })
            scans.removeAll { $0.id == id }
            if reflectionID == id { reflectionID = nil }
        } catch { message = L.t("disk_error") }
    }

    func back(_ id: UUID, data: Data) async {
        guard purchases.hasPro, let archive, let item = scan(id), !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let updated = try await work { try archive.storeBack(data, for: item) }
            replace(updated)
            message = L.t(updated.backText.isEmpty ? "no_text" : "text_detected")
        } catch { message = L.t("capture_issue") }
    }

    func reduceGlare(_ id: UUID, frames: [URL]) async {
        defer { for url in frames { try? FileManager.default.removeItem(at: url) } }
        guard purchases.hasPro, let archive, let item = scan(id), !busy, frames.count == 4 else { return }
        busy = true
        defer { busy = false; reflectionID = nil }
        do {
            let result = try await work { try Glare.reduce(in: archive, scan: item, supplemental: frames) }
            replace(result.scan)
            if preferences.autoSave && !Launch.isolated { enqueueSave([result.scan]) }
            message = L.t(result.blended ? "glare_done" : "glare_single")
        } catch { message = L.t("glare_failed") }
    }

    func enqueueSave(_ items: [Scan]) {
        guard !Launch.isolated, let archive else { return }
        for item in items where !item.saved && !saveQueue.contains(where: { $0 == item }) { saveQueue.append(item) }
        guard !savingPhotos, !saveQueue.isEmpty else { return }
        savingPhotos = true
        Task {
            defer { savingPhotos = false }
            var count = 0
            var blocked = false
            var failed = false
            while let item = saveQueue.first {
                do {
                    guard scan(item.id)?.revision == item.revision else { saveQueue.removeFirst(); continue }
                    let copy = try await work { try archive.export(item, original: false) }
                    defer { try? FileManager.default.removeItem(at: copy) }
                    try await archive.saveToPhotos(item, from: copy)
                    while busy { try await Task.sleep(for: .milliseconds(100)) }
                    if var current = scan(item.id), current == item {
                        current.saved = true
                        try archive.commit(current)
                        replace(current)
                    }
                    if finishedPages.insert(item.pageID).inserted && !item.glareReduced { success() }
                    count += 1
                } catch ScanError.photoAccess { blocked = true }
                catch { failed = true }
                saveQueue.removeFirst()
            }
            if blocked { message = L.t("photos_denied") }
            else if failed { message = L.t("photos_error") }
            else if count > 0 { message = L.f("saved_count", String(count)) }
        }
    }

    private func replace(_ item: Scan) {
        if let index = scans.firstIndex(where: { $0.id == item.id }) { scans[index] = item }
        else { scans.append(item) }
    }

    func success() {
        guard !Launch.isolated else { return }
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: "successful-uses") + 1
        defaults.set(count, forKey: "successful-uses")
        if count >= 3, !defaults.bool(forKey: "reviewed-v1") { reviewReady = true }
    }

    func dismissReview() {
        reviewReady = false
        UserDefaults.standard.set(true, forKey: "reviewed-v1")
    }

    func expiryNotice() {
        guard !Launch.isolated, !Launch.freePeriod, !purchases.hasPro, !readingInitial,
              !UserDefaults.standard.bool(forKey: "expiry-notice") else { return }
        message = L.t("trial_ended")
        UserDefaults.standard.set(true, forKey: "expiry-notice")
    }

    func work<T>(_ block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try autoreleasepool(invoking: block) }) }
        }
    }
}
