import Foundation

/// Un titolo salvato in "La mia lista", da qualunque fonte provenga.
struct SavedItem: Codable, Hashable, Identifiable {
    enum Source: String, Codable { case tmdbMovie, tmdbTV, jellyfin, archive }

    let source: Source
    let key: String
    let title: String
    let imageURL: URL?
    var archive: ArchiveItem?
    var added: Date = Date()

    var id: String { source.rawValue + ":" + key }

    var route: Route? {
        switch source {
        case .tmdbMovie: return Int(key).map { .tmdb(.movie, $0) }
        case .tmdbTV: return Int(key).map { .tmdb(.tv, $0) }
        case .jellyfin: return .jellyfin(key)
        case .archive: return archive.map { .archive($0) }
        }
    }

    static func tmdb(_ kind: MediaKind, id: Int, title: String, poster: URL?) -> SavedItem {
        SavedItem(source: kind == .movie ? .tmdbMovie : .tmdbTV, key: String(id), title: title, imageURL: poster)
    }
}

@MainActor
final class MyList: ObservableObject {
    static let shared = MyList()

    @Published private(set) var items: [SavedItem] = []
    /// Avanzamento dei classici (secondi visti e durata).
    @Published private(set) var archiveProgress: [String: ArchiveProgress] = [:]

    struct ArchiveProgress: Codable, Hashable {
        var seconds: Double
        var duration: Double
        var item: ArchiveItem
        var updated: Date

        var fraction: Double { duration > 0 ? min(1, seconds / duration) : 0 }
    }

    private let defaults = UserDefaults.standard

    private init() {
        if let d = defaults.data(forKey: "myList"), let v = try? JSONDecoder().decode([SavedItem].self, from: d) {
            items = v
        }
        if let d = defaults.data(forKey: "archiveProgress"),
           let v = try? JSONDecoder().decode([String: ArchiveProgress].self, from: d) {
            archiveProgress = v
        }
    }

    func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    func toggle(_ item: SavedItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: i)
        } else {
            items.insert(item, at: 0)
        }
        save()
    }

    func remove(_ item: SavedItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func setProgress(_ item: ArchiveItem, seconds: Double, duration: Double) {
        guard duration.isFinite, duration > 0, seconds.isFinite else { return }
        if seconds / duration > 0.95 || seconds < 30 {
            archiveProgress[item.identifier] = nil
        } else {
            archiveProgress[item.identifier] = ArchiveProgress(seconds: seconds, duration: duration, item: item, updated: Date())
        }
        if let d = try? JSONEncoder().encode(archiveProgress) { defaults.set(d, forKey: "archiveProgress") }
    }

    var recentArchive: [ArchiveProgress] {
        archiveProgress.values.sorted { $0.updated > $1.updated }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { defaults.set(d, forKey: "myList") }
    }
}
