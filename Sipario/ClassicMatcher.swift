import Foundation

/// Abbina i classici dell'Internet Archive alla scheda TMDB, per avere locandina, sfondo,
/// titolo italiano e trama al posto dei fotogrammi casuali.
@MainActor
final class ClassicMatcher: ObservableObject {
    static let shared = ClassicMatcher()

    struct Match: Codable, Hashable {
        let tmdbId: Int
        let title: String
        let overview: String?
        let posterPath: String?
        let backdropPath: String?

        var posterURL: URL? { TMDB.image(posterPath, size: "w342") }
        var backdropURL: URL? { TMDB.image(backdropPath, size: "w1280") }
    }

    @Published private(set) var matches: [String: Match] = [:]
    /// Elementi già cercati senza risultato (per non ripetere la ricerca).
    private var misses: Set<String> = []
    private var inFlight: Set<String> = []
    private let defaults = UserDefaults.standard

    private init() {
        if let d = defaults.data(forKey: "classicMatches"),
           let v = try? JSONDecoder().decode([String: Match].self, from: d) {
            matches = v
        }
        misses = Set(defaults.stringArray(forKey: "classicMisses") ?? [])
    }

    func match(_ item: ArchiveItem) -> Match? { matches[item.identifier] }

    /// Pulisce titoli come "Nosferatu (1922) - Full Movie [HD]".
    static func cleanTitle(_ raw: String) -> String {
        var t = raw
        for pattern in ["\\(.*?\\)", "\\[.*?\\]", "(?i)\\b(full movie|public domain|colorized|restored|hd|1080p|720p)\\b"] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: "_", with: " ")
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    func resolve(_ items: [ArchiveItem]) async {
        guard AppSettings.shared.hasTMDB else { return }
        let todo = items.filter { matches[$0.identifier] == nil && !misses.contains($0.identifier) && !inFlight.contains($0.identifier) }
        guard !todo.isEmpty else { return }
        todo.forEach { inFlight.insert($0.identifier) }
        // A gruppi di 6 per non sovraccaricare TMDB.
        var index = 0
        while index < todo.count {
            let batch = Array(todo[index..<min(index + 6, todo.count)])
            index += 6
            await withTaskGroup(of: (String, Match?).self) { group in
                for item in batch {
                    group.addTask { (item.identifier, await Self.lookup(item)) }
                }
                for await (id, m) in group {
                    inFlight.remove(id)
                    if let m { matches[id] = m } else { misses.insert(id) }
                }
            }
        }
        if let d = try? JSONEncoder().encode(matches) { defaults.set(d, forKey: "classicMatches") }
        defaults.set(Array(misses), forKey: "classicMisses")
    }

    private static func lookup(_ item: ArchiveItem) async -> Match? {
        let title = cleanTitle(item.title)
        guard title.count >= 2 else { return nil }
        let year = item.year.flatMap { Int($0) }
        guard let results = try? await TMDB.findMovie(title: title, year: year.map(String.init)) else { return nil }
        let wanted = normalized(title)
        // Si accetta un risultato solo se titolo e anno sono compatibili, per evitare abbinamenti sbagliati.
        let hit = results.first { r in
            let names = [r.title, r.originalTitle].compactMap { $0 }.map(normalized)
            let titleOK = names.contains(wanted) || names.contains { $0.hasPrefix(wanted) || wanted.hasPrefix($0) }
            guard titleOK, r.posterPath != nil else { return false }
            guard let year, let ry = r.year.flatMap({ Int($0) }) else { return true }
            return abs(ry - year) <= 1
        }
        guard let r = hit else { return nil }
        // Locandina ufficiale (con titolo) se c'è.
        let official = try? await TMDB.images(.movie, id: r.id)
        return Match(tmdbId: r.id, title: r.displayTitle, overview: r.overview,
                     posterPath: official?.posterPath ?? r.posterPath,
                     backdropPath: official?.cleanBackdropPath ?? r.backdropPath)
    }
}
